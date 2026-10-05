import { ConnectionHint } from './ConnectionHint';
import { InstalledAppRegistry, InstalledDeviceApp, InstalledSigningIdentity } from './InstalledAppRegistry';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hdcCommand, hdcDisconnect, hdcInstallProgress } from 'libhap_core.so';
import { NativeDeviceBridge } from './NativeJobRuntime';
import { ForegroundIdle } from './ForegroundIdle';

// All commands share one in-process Rust HDC host. Serialize install and
// verification so a second UI action cannot overtake an active transfer.
export class HdcDeviceBridge implements NativeDeviceBridge {
  /** 仅供界面显示最近的链路状态；不能作为安装前的在线证明。 */
  private static linked: boolean = false;

  private static queue: Promise<void> = Promise.resolve();
  private static commands: number = 0;
  private static scans: number = 0;
  private static connections: number = 0;
  private static connecting: Promise<void> = Promise.resolve();
  private static probe: Promise<string> | undefined;
  private static idleHandler: (() => void) | undefined;
  private context: common.UIAbilityContext;
  private connectFailure: string = '';
  private verifiedUdid: string = '';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private async command(operation: number, parameter: string = '',
    onStart?: () => void): Promise<string> {
    const queuedAt = Date.now();
    HdcDeviceBridge.commands++;
    const previous = HdcDeviceBridge.queue;
    let release: () => void = () => {};
    HdcDeviceBridge.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    await previous;
    const startedAt = Date.now();
    try {
      onStart?.();
      const output = await hdcCommand(this.context.filesDir, operation, parameter);
      // HDC 返回 [Fail] 时 Promise 仍会 resolve；执行过命令不等于链路可用。
      if (output.includes('[Fail]')) HdcDeviceBridge.linked = false;
      return output;
    } catch (error) {
      HdcDeviceBridge.linked = false;
      throw new Error(String(error));
    } finally {
      if (operation === 2 || operation === 3 || operation === 6 || operation === 13 || operation === 14) {
        console.info('InstalledApps command: op=' + operation + ' queueMs=' +
          (startedAt - queuedAt) + ' runMs=' + (Date.now() - startedAt));
      }
      HdcDeviceBridge.commands--;
      release();
      HdcDeviceBridge.idleHandler?.();
    }
  }

  /**
   * 释放设备的调试链路。
   *
   * 设备的无线调试基本只服务一个 HDC 宿主，我们连着不放，DevEco Studio 和 hdc
   * 命令行就连不上去了。所以用完要主动断开；下次操作 connected() 会自动重连，
   * 用户不需要重新配对。
   *
   * 返回是否真的断开过链路（false 表示本来就没连）。
   */
  static releaseDevice(): boolean {
    try {
      const dropped = hdcDisconnect() > 0;
      return dropped;
    } catch (_) {
      return false;
    } finally {
      HdcDeviceBridge.linked = false;
    }
  }

  /**
   * 本进程是否已经连过设备。
   *
   * 只反映"我们这边有没有链路"的近似状态：HDC 服务端存的是连接表，这里不去
   * 查询设备（查询本身也会占用链路，就成了为看状态而占端口）。
   */
  static deviceLinked(): boolean {
    return HdcDeviceBridge.linked;
  }

  static setIdleHandler(handler: () => void): void { HdcDeviceBridge.idleHandler = handler; }

  static busy(): boolean {
    return HdcDeviceBridge.commands > 0 || HdcDeviceBridge.scans > 0 ||
      HdcDeviceBridge.connections > 0 || HdcDeviceBridge.probe !== undefined;
  }

  static async releaseWhenIdle(allowed: () => boolean): Promise<boolean> {
    await HdcDeviceBridge.queue;
    if (HdcDeviceBridge.busy() || !allowed()) return false;
    return HdcDeviceBridge.releaseDevice();
  }

  async restoreSavedLink(allowed: () => boolean): Promise<boolean> {
    const port = await this.savedPort();
    if (!Number.isInteger(port) || port < 1024 || port > 65535) return false;
    await HdcDeviceBridge.queue;
    if (!allowed() || HdcDeviceBridge.busy()) return false;
    return this.connected();
  }

  async savedPort(): Promise<number> {
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    return Number(await store.get('port', 0));
  }

  private async rememberPort(port: number): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    await store.put('port', port);
    await store.flush();
  }

  private async liveUdid(): Promise<string> {
    this.verifiedUdid = '';
    const output = await this.command(2);
    const match = /\b[0-9a-fA-F]{40,128}\b/.exec(output);
    const udid = !output.includes('[Fail]') && match ? match[0] : '';
    HdcDeviceBridge.linked = udid.length > 0;
    this.verifiedUdid = udid;
    return udid;
  }

  /**
   * 链路是否可用。
   *
   * 无线调试端口会在进程仍存活时改变。每次真正需要安装/核对时查询 UDID，
   * 避免把一次历史成功连接当成当前连接，导致安装失败后反复弹出重连框。
   * 旧端口自动重连只试一次；完整的配对重试留给用户主动点击连接。
   */
  async connected(): Promise<boolean> {
    return (await this.connectedUdid()).length > 0;
  }

  private async connectedUdid(): Promise<string> {
    if (!HdcDeviceBridge.probe) {
      HdcDeviceBridge.probe = this.probeOrReconnect().finally(() => {
        HdcDeviceBridge.probe = undefined;
        HdcDeviceBridge.idleHandler?.();
      });
    }
    const udid = await HdcDeviceBridge.probe;
    this.verifiedUdid = udid;
    return udid;
  }

  private async probeOrReconnect(): Promise<string> {
    try {
      await HdcDeviceBridge.connecting;
      const udid = await this.liveUdid();
      if (udid.length > 0) return udid;
      const port = await this.savedPort();
      if (port > 0 && await this.connect(port, false, false)) return this.verifiedUdid;
    } catch (_) {
    }
    HdcDeviceBridge.linked = false;
    return '';
  }

  connectionFailureMessage(): string { return ConnectionHint.message(this.connectFailure); }

  async connect(port: number, persist: boolean = true,
    retryTrust: boolean = true): Promise<boolean> {
    HdcDeviceBridge.connections++;
    const previous = HdcDeviceBridge.connecting;
    let release: () => void = () => {};
    HdcDeviceBridge.connecting = new Promise<void>((resolve: () => void) => { release = resolve; });
    try {
      await previous;
      await HdcDeviceBridge.queue;
      // A manual reconnect may have succeeded while a quiet fallback was waiting.
      if (!retryTrust && HdcDeviceBridge.linked && (await this.liveUdid()).length > 0) return true;
      return await this.connectNow(port, persist, retryTrust);
    } finally {
      HdcDeviceBridge.connections--;
      release();
      HdcDeviceBridge.idleHandler?.();
    }
  }

  private async connectNow(port: number, persist: boolean, retryTrust: boolean): Promise<boolean> {
    if (!Number.isInteger(port) || port < 1024 || port > 65535) {
      throw new Error('请输入无线调试页显示的端口号');
    }
    this.connectFailure = '';
    // 端口改变时旧会话仍留在内置 HDC 服务端，先释放才能切换目标。
    HdcDeviceBridge.releaseDevice();
    const hosts = retryTrust ? ['127.0.0.1', 'localhost'] : ['127.0.0.1'];
    for (const host of hosts) {
      for (let attempt = 0; attempt < (retryTrust && host === '127.0.0.1' ? 2 : 1); attempt++) {
        try {
          const response = await this.command(1, host + ':' + port);
          if (response.includes('[Fail]') && this.connectFailure.length === 0) this.connectFailure = response;
        } catch (error) {
          if (this.connectFailure.length === 0) this.connectFailure = String(error);
        }
        // 明确拒绝连接时重试同一端口无法恢复，不再浪费授权等待时间。
        if (ConnectionHint.closed(this.connectFailure)) return false;
        try {
          if ((await this.liveUdid()).length > 0) {
            if (persist) await this.rememberPort(port);
            return true;
          }
        } catch (_) {}
        // A first connection can finish while the system trust decision is
        // still being committed. Retry that same port once without asking the
        // user to press Connect again.
        if (retryTrust && attempt === 0 && host === '127.0.0.1') {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 700));
        }
      }
    }
    HdcDeviceBridge.linked = false;
    return false;
  }

  async udid(): Promise<string> {
    const value = await this.connectedUdid();
    if (value.length === 0) throw new Error('无线调试尚未连接');
    return value;
  }

  async installedVersion(bundleName: string, persistResult: boolean = true): Promise<number> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    await InstalledAppRegistry.load(this.context);
    if (!await this.connected()) throw new Error('无线调试已断开');
    return this.readInstalledVersion(bundleName, persistResult);
  }

  /** 批量扫描已经核过链路，不为每个包重复读取 UDID 或重连。 */
  private async readInstalledVersion(bundleName: string, persistResult: boolean): Promise<number> {
    const output = await this.command(3, bundleName);
    try {
      const version = InstalledAppRegistry.observe(output, bundleName);
      if (persistResult) await InstalledAppRegistry.persist(this.context);
      return version;
    } catch (_) {
      // bm dump -n 的报错也可能是链路故障，不能直接当成「没装」。
      const names = InstalledAppRegistry.parseNames(await this.command(6));
      if (names !== undefined && !names.has(bundleName)) {
        InstalledAppRegistry.remember(bundleName, 0);
        if (persistResult) await InstalledAppRegistry.persist(this.context);
        return 0;
      }
      throw new Error('无法确认设备上的已安装版本');
    }
  }

  async installedDetails(bundleName: string): Promise<Record<string, Object>> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) throw new Error('应用包名无效');
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(3, bundleName);
    InstalledAppRegistry.observe(output, bundleName);
    const start = output.indexOf('{'), end = output.lastIndexOf('}');
    const result = JSON.parse(output.substring(start, end + 1)) as Record<string, Object>;
    if (result['name'] !== bundleName) throw new Error('设备信息与应用身份不一致');
    try {
      const label=(await this.command(14,bundleName)).trim();
      if(label.length>0 && label.length<=256 && !/[\r\n]|\[Fail\]|error:|^\$string:/i.test(label)) {result['displayName']=label;InstalledAppRegistry.rememberDisplayName(bundleName,label);}
    }catch(_){}
    await InstalledAppRegistry.persist(this.context);
    return result;
  }

  /** 查询设备上的真实签名身份，供重签覆盖安装前比对。查询失败不推断为未安装。 */
  async installedSigningIdentity(bundleName: string): Promise<InstalledSigningIdentity | undefined> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(3, bundleName);
    const identity = InstalledAppRegistry.parseSigningIdentity(output, bundleName);
    if (identity) {
      InstalledAppRegistry.remember(bundleName, identity.versionCode);
      InstalledAppRegistry.rememberLauncher(output, bundleName);
    }
    return identity;
  }

  async install(signedHapPath: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('签名包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.observedCommand(4, signedHapPath, onProgress);
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output)) {
      throw new Error(output.trim().length > 0 ? output.trim() : '设备未确认安装结果');
    }
    // The Rust HDC client can report only "AppMod finish". JobRunner queries
    // the device's installed version after this command; text is never proof.
  }

  private async observedCommand(operation: number, path: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<string> {
    let timer = -1;
    const report = (): void => {
      try {
        const row = JSON.parse(hdcInstallProgress(path)) as Record<string, Object>;
        onProgress?.(String(row['phase'] ?? 'waiting'), Number(row['sent'] ?? 0),
          Number(row['total'] ?? 0));
      } catch (_) {
        // 反馈读取失败不能中断设备安装。
      }
    };
    let output = '';
    try {
      output = await this.command(operation, path, () => {
        if (onProgress === undefined) return;
        try { hdcInstallProgress(path, true); } catch (_) {}
        report();
        timer = setInterval(report, 150);
      });
      if (onProgress !== undefined) report();
    } finally {
      if (timer !== -1) clearInterval(timer);
    }
    return output;
  }

  /** Upload and checksum every module before the user-approved uninstall. */
  async stageInstall(path: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<string> {
    if (!path.startsWith(this.context.filesDir + '/') || !fileIo.accessSync(path)) {
      throw new Error('更新包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error('无线调试已断开，尚未卸载旧版');
    return this.observedCommand(10, path, onProgress);
  }

  async installStaged(ticket: string, bundleName: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void> {
    const descriptor = JSON.parse(ticket) as Record<string, Object>;
    descriptor['bundleName'] = bundleName;
    onProgress?.('installing', 0, 0);
    const output = await this.command(11, JSON.stringify(descriptor));
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output)) {
      throw new Error(output.trim() || '设备未确认重装结果');
    }
  }

  async discardStaged(ticket: string): Promise<boolean> {
    try {
      // Cleanup never opens a connection prompt; an offline ticket remains in the journal.
      if (!await this.connected()) return false;
      const output = await this.command(12, ticket);
      return !/\[Fail\]|\berror\s*:|\bfailed\b/i.test(output);
    } catch (_) { return false; }
  }

  async uninstall(bundleName: string): Promise<void> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    // Keep background idle-disconnect from running between the uninstall and
    // its read-only confirmation. Submit the destructive command only once.
    HdcDeviceBridge.scans++;
    try {
      if (!await this.connected()) throw new Error('无线调试已断开');
      let detail = '';
      let rejected = false;
      try {
        const output = await this.command(7, bundleName);
        rejected = /\[Fail\]|\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output);
        if (!rejected && /successfully|AppMod finish/i.test(output)) return;
        detail = output.trim();
      } catch (error) { detail = String(error); }
      // A lost reply cannot tell us whether removal finished. Only a complete
      // system inventory can prove absence; an offline/truncated list cannot.
      for (let attempt = 0; attempt < 6; attempt++) {
        let found: Map<string, number> | undefined;
        try { found = InstalledAppRegistry.parseNames(await this.command(6)); } catch (_) {}
        if (found === undefined) {
          throw new Error('暂时无法确认卸载结果，请重连无线调试后刷新应用列表');
        }
        if (!found.has(bundleName)) return;
        if (rejected || attempt === 5) break;
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 500); });
      }
      throw new Error(detail || '设备上仍安装着该应用，请稍后重试');
    } finally {
      HdcDeviceBridge.scans--;
      HdcDeviceBridge.idleHandler?.();
    }
  }

  async installSelfAfterUninstall(signedHapPath: string): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('安装器更新包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const staged = await this.command(8, signedHapPath);
    if (!staged.includes('staged and verified')) {
      throw new Error('更新包传送或校验失败，尚未卸载旧版');
    }
    const launched = await this.command(9);
    if (launched.includes('[Fail]')) throw new Error('独立安装任务启动失败，尚未卸载旧版');
  }

  /**
   * 设备上是否装着这个包。
   *
   * 记录里写着「已安装」不代表设备上还在 —— 用户可能在系统设置里卸掉了。
   * 这个查询只读，不改设备状态；连接断开时抛错，调用方不能把它当成「没装」，
   * 否则断线一次就会把全部记录误删。
   */
  async isInstalled(bundleName: string): Promise<boolean> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(5, bundleName);
    if (output.includes('[Fail]')) throw new Error('无法读取设备上的安装状态');
    // bm dump 只在包存在时才输出 versionCode
    return /"versionCode"\s*:\s*\d+/.test(output);
  }

  /** 先取存在性清单，再只查询目录关心的包版本；清单本身不含 versionCode。 */
  async installedBundleVersions(bundleNames: string[] = [],
    onProgress?: (checked: number, total: number, bundleName?: string,
      version?: number) => void): Promise<Map<string, number> | undefined> {
    await ForegroundIdle.wait();
    HdcDeviceBridge.scans++;
    const startedAt = Date.now();
    let checked = 0;
    let present = 0;
    let queried = 0;
    try {
      const unique = new Set<string>(bundleNames);
      onProgress?.(checked, unique.size);
      await InstalledAppRegistry.load(this.context);
      if (!await this.connected()) throw new Error('无线调试已断开');
      const found = InstalledAppRegistry.parseNames(await this.command(6));
      if (found === undefined) {
        console.warn('InstalledApps: unrecognized device list');
        return undefined;
      }
      present = Array.from(unique).filter((name: string) => found.has(name)).length;
      for (const name of unique) {
        if (!found.has(name)) {
          InstalledAppRegistry.remember(name, 0);
          onProgress?.(++checked, unique.size, name, 0);
          continue;
        }
        let version: number = -1;
        try {
          await ForegroundIdle.wait();
          queried++;
          // 不把单包失败变成未安装；保留它在存在性清单中的位置。
          const output = await this.command(3, name);
          if (output.includes('[Fail]')) break;
          version = InstalledAppRegistry.observe(output, name);
          found.set(name, version);
        } catch (error) {
          console.warn('InstalledApps: version query failed for ' + name + ': ' + String(error));
          if (!HdcDeviceBridge.linked) break;
        }
        onProgress?.(++checked, unique.size, name, version);
      }
      await InstalledAppRegistry.persist(this.context);
      return found;
    } finally {
      console.info('InstalledApps scan: requested=' + new Set<string>(bundleNames).size +
        ' present=' + present + ' queried=' + queried + ' checked=' + checked +
        ' elapsedMs=' + (Date.now() - startedAt));
      HdcDeviceBridge.scans--;
      HdcDeviceBridge.idleHandler?.();
    }
  }

  /** 只读调试签名应用，避免遍历系统应用；名称与入口缓存到本机，离线仍可打开。 */
  async sideloadedApps(knownBundles: string[] = []): Promise<InstalledDeviceApp[]> {
    HdcDeviceBridge.scans++;
    try {
      await InstalledAppRegistry.load(this.context);
      if (!await this.connected()) throw new Error('无线调试未连接');
      const names = InstalledAppRegistry.parseSideloadedNames(await this.command(13));
      if (names === undefined) throw new Error('设备未返回完整的侧载应用清单');
      const all = InstalledAppRegistry.parseNames(await this.command(6));
      for (const name of names) {
        const previousVersion = InstalledAppRegistry.version(name);
        const previousUpdateTime = InstalledAppRegistry.installationTime(name, previousVersion);
        try {
          const output = await this.command(3, name);
          if (output.includes('[Fail]')) throw new Error('读取应用信息失败');
          const version = InstalledAppRegistry.observe(output, name);
          if (version !== previousVersion || InstalledAppRegistry.displayName(name).length === 0 ||
            InstalledAppRegistry.installationTime(name, version) !== previousUpdateTime) {
            try { InstalledAppRegistry.rememberDisplayName(name, await this.command(14, name)); } catch (_) {}
          }
        } catch (error) {
          if (!HdcDeviceBridge.linked) throw new Error(String(error));
          // 单包失败保留已有观察，不将它误判为未安装。
        }
      }
      if (all !== undefined) {
        const observed = InstalledAppRegistry.sideloadedApps().map((app: InstalledDeviceApp) => app.bundleName);
        for (const name of new Set<string>(knownBundles.concat(observed))) {
          if (!all.has(name)) InstalledAppRegistry.remember(name, 0);
        }
      }
      InstalledAppRegistry.rememberSideloadedNames(names);
      await InstalledAppRegistry.persist(this.context);
      return InstalledAppRegistry.sideloadedApps();
    } finally {
      HdcDeviceBridge.scans--;
      HdcDeviceBridge.idleHandler?.();
    }
  }

  /** Want 必须包含实际入口，外部侧载包不能只用包名启动。 */
  async openApp(bundleName: string, moduleName: string = '', abilityName: string = ''): Promise<void> {
    await InstalledAppRegistry.load(this.context);
    let target = InstalledAppRegistry.launcher(bundleName);
    if (target === undefined && abilityName.length === 0) {
      await this.installedVersion(bundleName);
      target = InstalledAppRegistry.launcher(bundleName);
    }
    const entryAbility = target?.abilityName ?? abilityName;
    const entryModule = target?.moduleName ?? moduleName;
    if (entryAbility.length === 0) throw new Error('尚未读取到应用启动入口，请连接无线调试后重试');
    await this.context.startAbility({ bundleName: bundleName,
      moduleName: entryModule, abilityName: entryAbility });
  }

  async openWirelessSettings(): Promise<void> {
    await this.context.startAbility({
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      action: 'ohos.want.action.viewData',
      uri: 'system_wireless_commissioning'
    });
  }
}
