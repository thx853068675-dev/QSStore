import { ConnectionHint } from './ConnectionHint';
import { InstalledAppRegistry, InstalledSigningIdentity } from './InstalledAppRegistry';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hdcCommand, hdcDisconnect, hdcInstallProgress } from 'libhap_core.so';
import { NativeDeviceBridge } from './NativeJobRuntime';

// All commands share one in-process Rust HDC host. Serialize install and
// verification so a second UI action cannot overtake an active transfer.
export class HdcDeviceBridge implements NativeDeviceBridge {
  /** 仅供界面显示最近的链路状态；不能作为安装前的在线证明。 */
  private static linked: boolean = false;

  private static queue: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext;
  private connectFailure: string = '';
  private verifiedUdid: string = '';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private async command(operation: number, parameter: string = '',
    onStart?: () => void): Promise<string> {
    const previous = HdcDeviceBridge.queue;
    let release: () => void = () => {};
    HdcDeviceBridge.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    await previous;
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
      release();
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
    try {
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
      const version = InstalledAppRegistry.parseVersion(output, bundleName);
      InstalledAppRegistry.remember(bundleName, version);
      InstalledAppRegistry.rememberLauncher(output, bundleName);
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

  /** 查询设备上的真实签名身份，供重签覆盖安装前比对。查询失败不推断为未安装。 */
  async installedSigningIdentity(bundleName: string): Promise<InstalledSigningIdentity | undefined> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(3, bundleName);
    return InstalledAppRegistry.parseSigningIdentity(output, bundleName);
  }

  async install(signedHapPath: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('签名包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    let timer = -1;
    const report = (): void => {
      try {
        const row = JSON.parse(hdcInstallProgress(signedHapPath)) as Record<string, Object>;
        onProgress?.(String(row['phase'] ?? 'waiting'), Number(row['sent'] ?? 0),
          Number(row['total'] ?? 0));
      } catch (_) {
        // 反馈读取失败不能中断设备安装。
      }
    };
    let output = '';
    try {
      output = await this.command(4, signedHapPath, () => {
        if (onProgress === undefined) return;
        try { hdcInstallProgress(signedHapPath, true); } catch (_) {}
        report();
        timer = setInterval(report, 150);
      });
      if (onProgress !== undefined) report();
    } finally {
      if (timer !== -1) clearInterval(timer);
    }
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output)) {
      throw new Error(output.trim().length > 0 ? output.trim() : '设备未确认安装结果');
    }
    // The Rust HDC client can report only "AppMod finish". JobRunner queries
    // the device's installed version after this command; text is never proof.
  }

  async uninstall(bundleName: string): Promise<void> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(7, bundleName);
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output) ||
      !/successfully|AppMod finish/i.test(output)) {
      throw new Error(output.trim().length > 0 ? output.trim() : '设备未确认卸载结果');
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
  async installedBundleVersions(bundleNames: string[] = []): Promise<Map<string, number> | undefined> {
    await InstalledAppRegistry.load(this.context);
    if (!await this.connected()) throw new Error('无线调试已断开');
    const found = InstalledAppRegistry.parseNames(await this.command(6));
    if (found === undefined) {
      console.warn('InstalledApps: unrecognized device list');
      return undefined;
    }
    const unique = new Set<string>(bundleNames);
    for (const name of unique) {
      if (!found.has(name)) {
        InstalledAppRegistry.remember(name, 0);
        continue;
      }
      try {
        // 不把单包失败变成未安装；保留它在存在性清单中的位置。
        found.set(name, await this.readInstalledVersion(name, false));
      } catch (error) {
        console.warn('InstalledApps: version query failed for ' + name + ': ' + String(error));
      }
    }
    await InstalledAppRegistry.persist(this.context);
    return found;
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
