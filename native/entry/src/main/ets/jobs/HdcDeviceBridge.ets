import { ConnectionHint } from './ConnectionHint';
import { InstalledAppRegistry, InstalledDeviceApp, InstalledSigningIdentity } from './InstalledAppRegistry';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hdcCommand, hdcDisconnect, hdcInstallProgress } from 'libhap_core.so';
import { NativeDeviceBridge } from './NativeJobRuntime';
import { ForegroundIdle } from './ForegroundIdle';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { I18n } from '../data/I18n';

export interface FixedPortSettings { enabled: boolean; port: number; resetPending?: boolean; }

// One embedded host, independent command lanes per authenticated device.
// Commands for the same device cannot overtake its active transfer.
export class HdcDeviceBridge implements NativeDeviceBridge {
  /** 仅供界面显示最近的链路状态；不能作为安装前的在线证明。 */
  private static linked: boolean = false;

  private static queue: Promise<void> = Promise.resolve();
  private static peerQueues: Map<string, Promise<void>> = new Map();
  private static commands: number = 0;
  private static scans: number = 0;
  private static connections: number = 0;
  private static connecting: Promise<void> = Promise.resolve();
  private static probe: Promise<string> | undefined;
  private static probeGuard:(()=>boolean)|undefined;
  private static idleHandler: (() => void) | undefined;
  private static fixedSettings: FixedPortSettings | undefined;
  private static activePort: number = 0;
  private static sessions:Set<string>=new Set();
  static releasePending:boolean=false;
  private context: common.UIAbilityContext;
  private connectFailure: string = '';
  private verifiedUdid: string = '';

  readonly isLocalDevice: boolean;
  private target: DeviceInstallTarget | undefined;

  constructor(context: common.UIAbilityContext, target?: DeviceInstallTarget) {
    this.context = context;
    this.target = target && target.key !== 'local' ? target : undefined;
    this.isLocalDevice = this.target === undefined;
  }

  private async command(operation: number, parameter: string = '',
    onStart?: () => void): Promise<string> {
    PrivacyConsent.assertBusinessAllowed();
    const queuedAt = Date.now();
    HdcDeviceBridge.commands++;
    const lane = this.target?.key ?? 'local';
    const previous = lane === 'local' ? HdcDeviceBridge.queue : HdcDeviceBridge.peerQueues.get(lane) ?? Promise.resolve();
    let release: () => void = () => {};
    const tail = new Promise<void>((resolve: () => void) => { release = resolve; });
    if (lane === 'local') HdcDeviceBridge.queue = tail; else HdcDeviceBridge.peerQueues.set(lane, tail);
    await previous;
    const startedAt = Date.now();
    try {
      // A queued command must not begin after consent was withdrawn.
      // Do not interrupt a command already committing an atomic uninstall/install.
      PrivacyConsent.assertBusinessAllowed();
      onStart?.();
      const output = this.target && operation !== 20 ? await hdcCommand(this.context.filesDir, 19, JSON.stringify({
        target: DeviceInstallTarget.endpoint(this.target), udid: this.target.udid, operation: operation, parameter: parameter
      })) : await hdcCommand(this.context.filesDir, operation, parameter);
      // HDC 返回 [Fail] 时 Promise 仍会 resolve；执行过命令不等于链路可用。
      if (output.includes('[Fail]') && this.isLocalDevice) HdcDeviceBridge.linked = false;
      if(this.target&&!output.includes('[Fail]')&&(operation===1||operation===2||operation===22))HdcDeviceBridge.sessions.add(this.target.key);
      if(this.isLocalDevice&&operation===23)HdcDeviceBridge.sessions.delete('local');
      return output;
    } catch (error) {
      if (this.isLocalDevice) { HdcDeviceBridge.linked = false; HdcDeviceBridge.activePort = 0; }
      if (!PrivacyConsent.isBusinessAllowed()) PrivacyConsent.assertBusinessAllowed();
      throw new Error(String(error));
    } finally {
      if (operation === 2 || operation === 3 || operation === 6 || operation === 13 || operation === 14) {
        console.info('InstalledApps command: op=' + operation + ' queueMs=' +
          (startedAt - queuedAt) + ' runMs=' + (Date.now() - startedAt));
      }
      HdcDeviceBridge.commands--;
      release();
      if (HdcDeviceBridge.peerQueues.get(lane) === tail) HdcDeviceBridge.peerQueues.delete(lane);
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
      const dropped=hdcDisconnect();
      if(dropped<0){HdcDeviceBridge.releasePending=true;return false;}
      HdcDeviceBridge.linked=false;HdcDeviceBridge.activePort=0;
      HdcDeviceBridge.sessions.clear();HdcDeviceBridge.releasePending=false;
      return dropped>0;
    }catch(_){HdcDeviceBridge.releasePending=true;return false;}
  }
  static cancelDiscovery(context:common.UIAbilityContext):void{
    HdcDeviceBridge.discoveryCommand(context,25).catch(()=>{});
  }
  static hasSessions():boolean{return HdcDeviceBridge.linked||HdcDeviceBridge.sessions.size>0;}

  /** Independent discovery lanes still notify background release when a native call finishes. */
  static async discoveryCommand(context:common.UIAbilityContext,operation:number,parameter:string=''):Promise<string>{
    // Revoking consent must still be able to stop already-running native work.
    if(operation!==25&&!(operation===21&&parameter.startsWith('stop:')))PrivacyConsent.assertBusinessAllowed();
    HdcDeviceBridge.commands++;
    try{return await hdcCommand(context.filesDir,operation,parameter);}
    finally{HdcDeviceBridge.commands--;HdcDeviceBridge.idleHandler?.();}
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
    const fixed = await this.fixedPortSettings();
    if ((!Number.isInteger(port) || port < 1024 || port > 65535) && !fixed.enabled) return false;
    await HdcDeviceBridge.queue;
    if (!allowed() || HdcDeviceBridge.busy()) return false;
    return (await this.connectedUdid(allowed)).length>0;
  }

  async savedPort(): Promise<number> {
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    return Number(await store.get('port', 0));
  }

  async fixedPortSettings(): Promise<FixedPortSettings> {
    if (HdcDeviceBridge.fixedSettings !== undefined) return HdcDeviceBridge.fixedSettings;
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    let settings: FixedPortSettings = { enabled: false, port: 0 };
    try {
      const parsed = JSON.parse(String(await store.get('fixed-config', '{}'))) as FixedPortSettings;
      if (Number.isInteger(parsed.port) && parsed.port >= 10000 && parsed.port <= 65535) {
        settings = { enabled: parsed.enabled === true, port: parsed.port, resetPending: parsed.resetPending === true };
      }
    } catch (_) {}
    HdcDeviceBridge.fixedSettings = settings;
    return settings;
  }

  async saveFixedPortSettings(settings: FixedPortSettings): Promise<void> {
    if (!Number.isInteger(settings.port) || settings.port < 10000 || settings.port > 65535) {
      throw new Error(I18n.t('端口须为 10000–65535 的五位数字'));
    }
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    await store.put('fixed-config', JSON.stringify(settings));
    await store.flush();
    HdcDeviceBridge.fixedSettings = { enabled: settings.enabled, port: settings.port, resetPending: settings.resetPending };
  }

  static connectedPort(): number { return HdcDeviceBridge.linked ? HdcDeviceBridge.activePort : 0; }

  async clearFixedPort(allowed: () => boolean): Promise<boolean> {
    if (HdcDeviceBridge.busy() || !allowed()) return false;
    HdcDeviceBridge.connections++;
    const previous = HdcDeviceBridge.connecting;
    let release: () => void = () => {};
    HdcDeviceBridge.connecting = new Promise<void>((resolve: () => void) => { release = resolve; });
    try {
      await previous;
      await HdcDeviceBridge.queue;
      if (!allowed()) return false;
      if (!(await this.liveUdid())) throw new Error(I18n.t('请先连接无线调试以停用固定端口'));
      if (!allowed()) return false;
      const oldPort = HdcDeviceBridge.activePort || await this.savedPort();
      // The official close command clears the persistent port and restarts the daemon.
      let receiptError = '';
      try {
        const response = await this.command(17);
        if (/\[Fail\]|error:/i.test(response)) throw new Error(response);
      } catch (error) { receiptError = String(error); }
      if (receiptError) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 700));
        if (oldPort <= 0 || await this.connectNow(oldPort, false, false, true) ||
          !ConnectionHint.closed(this.connectFailure)) throw new Error(receiptError);
      }
      HdcDeviceBridge.releaseDevice();
      await this.rememberPort(0);
      return true;
    } finally {
      HdcDeviceBridge.connections--;
      release();
      HdcDeviceBridge.idleHandler?.();
    }
  }

  /** Daemon restart is expected. Verify the same device on the new port before committing it. */
  async fixPort(port: number, allowed: () => boolean): Promise<boolean> {
    if (!Number.isInteger(port) || port < 10000 || port > 65535) {
      throw new Error(I18n.t('端口须为 10000–65535 的五位数字'));
    }
    if (HdcDeviceBridge.busy() || !allowed()) return false;
    HdcDeviceBridge.connections++;
    const previous = HdcDeviceBridge.connecting;
    let release: () => void = () => {};
    HdcDeviceBridge.connecting = new Promise<void>((resolve: () => void) => { release = resolve; });
    try {
      await previous;
      await HdcDeviceBridge.queue;
      if (!allowed()) return false;
      const oldPort = HdcDeviceBridge.activePort || await this.savedPort();
      const expected = await this.liveUdid();
      if (!expected) throw new Error(I18n.t('请先连接一次无线调试'));
      if (!allowed()) return false;
      let failure = '';
      try {
        const response = await this.command(15, String(port));
        if (/\[Fail\]|error:/i.test(response)) failure = response;
      } catch (error) { failure = String(error); }
      for (const delay of [350, 700, 1400]) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, delay));
        if (await this.connectNow(port, false, false, true)) {
          if (this.verifiedUdid === expected) {
            await this.rememberPort(port);
            return true;
          }
          HdcDeviceBridge.releaseDevice();
        }
      }
      // If the command was rejected, restore the working link rather than strand the installer.
      if (oldPort > 0 && oldPort !== port) {
        if (await this.connectNow(oldPort, false, false, true) && this.verifiedUdid !== expected) {
          HdcDeviceBridge.releaseDevice();
        }
      }
      throw new Error(failure || I18n.t('暂未连上新端口，稍后将自动恢复'));
    } finally {
      HdcDeviceBridge.connections--;
      release();
      HdcDeviceBridge.idleHandler?.();
    }
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
    if(udid)HdcDeviceBridge.sessions.add('local');
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
  async connected(allowed:()=>boolean=()=>true): Promise<boolean> {
    if (this.target) {
      try { return (await this.udid()).length > 0; } catch (error) {
        this.connectFailure=String(error);
        console.warn('Remote HDC probe failed: '+this.connectFailure);
        return false;
      }
    }
    return (await this.connectedUdid(allowed)).length > 0;
  }

  private async connectedUdid(allowed:()=>boolean=()=>true): Promise<string> {
    if(!allowed())return '';
    if (!HdcDeviceBridge.probe) {
      HdcDeviceBridge.probeGuard=allowed;
      HdcDeviceBridge.probe = this.probeOrReconnect(allowed).finally(() => {
        HdcDeviceBridge.probe = undefined;
        HdcDeviceBridge.idleHandler?.();
      });
    }
    const guard=HdcDeviceBridge.probeGuard;
    const udid = await HdcDeviceBridge.probe;
    // A user/installation waiting behind a cancelled automatic probe gets a fresh attempt.
    if(!udid&&allowed()&&guard&&!guard())return this.connectedUdid(allowed);
    this.verifiedUdid = udid;
    return udid;
  }

  private async probeOrReconnect(allowed:()=>boolean=()=>true): Promise<string> {
    try {
      await HdcDeviceBridge.connecting;
      if(!allowed())return '';
      try {
        const udid = await this.liveUdid();
        if (udid.length > 0) return udid;
      } catch (_) { /* A missing native session must still reach the saved-port reconnect. */ }
      if(!allowed())return '';
      const port = await this.savedPort();
      const fixed = await this.fixedPortSettings();
      if(!allowed())return '';
      if (fixed.enabled && await this.connect(fixed.port, true, false, true)) return this.verifiedUdid;
      if(!allowed())return '';
      if (port > 0 && (!fixed.enabled || fixed.port !== port) &&
        await this.connect(port, false, false, true)) return this.verifiedUdid;
      if(!allowed())return '';
      if (fixed.enabled || fixed.resetPending) {
        // The system switch replaces persist.hdc.port. Discover this phone's
        // current daemon before restoring the user's desired fixed port.
        let discovery = '';
        try {
          discovery = await this.command(18);
          console.info('FixedPort local discovery: ' + (discovery || 'no reply'));
        } catch (error) {
          console.warn('FixedPort local discovery failed: ' + String(error));
        }
        if(!allowed())return '';
        const discovered = Number(discovery);
        if (Number.isInteger(discovered) && discovered >= 1024 && discovered <= 65535 &&
          discovered !== port && discovered !== fixed.port &&
          await this.connect(discovered, true, false, true)) return this.verifiedUdid;
      }
    } catch (_) {
    }
    HdcDeviceBridge.linked = false;
    return '';
  }

  connectionFailureMessage(): string { return ConnectionHint.message(this.connectFailure); }

  async connect(port: number, persist: boolean = true,
    retryTrust: boolean = true, quick: boolean = false): Promise<boolean> {
    HdcDeviceBridge.connections++;
    const previous = HdcDeviceBridge.connecting;
    let release: () => void = () => {};
    HdcDeviceBridge.connecting = new Promise<void>((resolve: () => void) => { release = resolve; });
    try {
      await previous;
      await HdcDeviceBridge.queue;
      // A manual reconnect may have succeeded while a quiet fallback was waiting.
      if (!retryTrust && HdcDeviceBridge.linked && (await this.liveUdid()).length > 0) return true;
      return await this.connectNow(port, persist, retryTrust, quick);
    } finally {
      HdcDeviceBridge.connections--;
      release();
      HdcDeviceBridge.idleHandler?.();
    }
  }

  private async connectNow(port: number, persist: boolean, retryTrust: boolean,
    quick: boolean = false): Promise<boolean> {
    if (!Number.isInteger(port) || port < 1024 || port > 65535) {
      throw new Error(I18n.t('请输入无线调试页显示的端口号'));
    }
    this.connectFailure = '';
    // 端口改变时旧会话仍留在内置 HDC 服务端，先释放才能切换目标。
    await this.command(23);
    HdcDeviceBridge.linked=false;
    const hosts = retryTrust ? ['127.0.0.1', 'localhost'] : ['127.0.0.1'];
    for (const host of hosts) {
      for (let attempt = 0; attempt < (retryTrust && host === '127.0.0.1' ? 2 : 1); attempt++) {
        try {
          const response = await this.command(quick ? 16 : 1, host + ':' + port);
          if (response.includes('[Fail]') && this.connectFailure.length === 0) this.connectFailure = response;
        } catch (error) {
          if (this.connectFailure.length === 0) this.connectFailure = String(error);
        }
        // 明确拒绝连接时重试同一端口无法恢复，不再浪费授权等待时间。
        if (ConnectionHint.closed(this.connectFailure)) return false;
        try {
          if ((await this.liveUdid()).length > 0) {
            HdcDeviceBridge.activePort = port;
            HdcDeviceBridge.sessions.add('local');
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
    if (this.target) {
      let output:string;
      try { output=await this.command(2); }
      catch(error) {
        if(/身份.*变化|identity.*changed/i.test(String(error)))throw new Error(String(error));
        const current=Number(await this.command(20,this.target.host));
        if(!DeviceInstallTarget.validPort(current))throw new Error(String(error));
        // Changing an endpoint never changes the expected authenticated UDID.
        this.target.port=current;
        output=await this.command(2);
      }
      const match = /\b[0-9a-fA-F]{40,128}\b/.exec(output);
      if (output.includes('[Fail]') || !match) throw new Error(I18n.t('目标设备尚未连接，请在对方设备允许无线调试'));
      const value = match[0].toLowerCase();
      if (this.target.udid && value !== this.target.udid.toLowerCase()) throw new Error(I18n.t('目标设备身份已变化，已停止安装'));
      // Target keys use lower-case for stable comparison. Provisioning retains
      // the system's canonical upper-case UDID; BMS compares Profile IDs exactly.
      return value.toUpperCase();
    }
    const value = await this.connectedUdid();
    if (value.length === 0) throw new Error(I18n.t('无线调试尚未连接'));
    return value;
  }

  targetSnapshot():string{return this.target?DeviceInstallTarget.snapshot(this.target):'';}

  async installedVersion(bundleName: string, persistResult: boolean = true): Promise<number> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error(I18n.t('应用包名无效'));
    }
    if (this.target) {
      if (!await this.connected()) throw new Error(I18n.t('目标设备已断开'));
      const output = await this.command(3, bundleName);
      try {
        const record=JSON.parse(output.substring(output.indexOf('{'),output.lastIndexOf('}')+1)) as Record<string,Object>;
        const version=Number(record['versionCode']);
        if(record['name']===bundleName&&Number.isSafeInteger(version)&&version>0)return version;
      }catch(_){}
      const names = InstalledAppRegistry.parseNames(await this.command(6));
      if (names && !names.has(bundleName)) return 0;
      throw new Error(I18n.t('无法核对目标设备上的安装版本'));
    }
    await InstalledAppRegistry.load(this.context);
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
    return this.readInstalledVersion(bundleName, persistResult);
  }

  /** A version observation is usable even when privileged signing details are unavailable. */
  async installedState(bundleName:string):Promise<InstalledSigningIdentity>{
    if(!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName))throw new Error(I18n.t('应用包名无效'));
    if(!await this.connected())throw new Error(I18n.t('目标设备已断开'));
    const output=await this.command(3,bundleName);
    try{
      const row=JSON.parse(output.substring(output.indexOf('{'),output.lastIndexOf('}')+1)) as Record<string,Object>;
      const code=Number(row['versionCode']);
      if(row['name']!==bundleName||!Number.isSafeInteger(code)||code<=0)throw new Error(I18n.t('版本信息无效'));
      const state=InstalledAppRegistry.parseSigningIdentity(output,bundleName)??new InstalledSigningIdentity();
      state.versionCode=code;state.versionName=String(row['versionName']??'');
      state.updateTime=Number(row['updateTime']??0);
      if(!Number.isSafeInteger(state.updateTime)||state.updateTime<0)state.updateTime=0;
      const app=row['applicationInfo'] as Record<string,Object>|undefined;
      const source=String(app?.['installSource']??row['installSource']??'').toLowerCase();
      state.appGallery=String(app?.['appProvisionType']??'').toLowerCase()!=='debug'&&
        (String(app?.['appDistributionType']??'').toLowerCase()==='app_gallery'||
          source==='com.huawei.hmsapp.appgallery'||source==='com.huawei.appmarket');
      state.displayName=String(row['displayName']??'');
      if(!this.target)try{InstalledAppRegistry.observe(output,bundleName);await InstalledAppRegistry.persist(this.context);}catch(_){}
      return state;
    }catch(_){}
    const names=InstalledAppRegistry.parseNames(await this.command(6));
    if(names&&!names.has(bundleName))return new InstalledSigningIdentity();
    throw new Error(I18n.t('无法核对目标设备上的应用，已保留原应用'));
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
      throw new Error(I18n.t('无法确认设备上的已安装版本'));
    }
  }

  async installedDetails(bundleName: string): Promise<Record<string, Object>> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) throw new Error(I18n.t('应用包名无效'));
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
    const output = await this.command(3, bundleName);
    if(!this.target)InstalledAppRegistry.observe(output, bundleName);
    const start = output.indexOf('{'), end = output.lastIndexOf('}');
    const result = JSON.parse(output.substring(start, end + 1)) as Record<string, Object>;
    if (result['name'] !== bundleName) throw new Error(I18n.t('设备信息与应用身份不一致'));
    try {
      const label=(await this.command(14,bundleName)).trim();
      if(label.length>0 && label.length<=256 && !/[\r\n]|\[Fail\]|error:|^\$string:/i.test(label)) {result['displayName']=label;if(!this.target)InstalledAppRegistry.rememberDisplayName(bundleName,label);}
    }catch(_){}
    if(!this.target)await InstalledAppRegistry.persist(this.context);
    return result;
  }

  /** 查询设备上的真实签名身份，供重签覆盖安装前比对。查询失败不推断为未安装。 */
  async installedSigningIdentity(bundleName: string): Promise<InstalledSigningIdentity | undefined> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error(I18n.t('应用包名无效'));
    }
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
    if (this.target) return InstalledAppRegistry.parseSigningIdentity(await this.command(3, bundleName), bundleName);
    const revision = InstalledAppRegistry.observationRevision(bundleName);
    const output = await this.command(3, bundleName);
    if (InstalledAppRegistry.observationRevision(bundleName) !== revision) throw new Error(I18n.t('应用状态已变化，请重试'));
    const identity = InstalledAppRegistry.parseSigningIdentity(output, bundleName);
    if (identity) {
      InstalledAppRegistry.observe(output, bundleName);
      const observedRevision = InstalledAppRegistry.observationRevision(bundleName);
      if (InstalledAppRegistry.isAppGallery(bundleName) && InstalledAppRegistry.displayName(bundleName).length === 0) {
        try {
          const label = await this.command(14, bundleName);
          if (InstalledAppRegistry.observationRevision(bundleName) === observedRevision) {
            InstalledAppRegistry.rememberDisplayName(bundleName, label);
          }
        } catch (_) {
          // An unavailable display label cannot invalidate the verified signing identity.
        }
      }
      if (InstalledAppRegistry.observationRevision(bundleName) !== observedRevision) throw new Error(I18n.t('应用状态已变化，请重试'));
    }
    return identity;
  }

  /** No global local-app cache or saved loopback port is touched by remote pairing. */
  async connectTarget(allowed:()=>boolean=()=>true): Promise<DeviceInstallTarget> {
    if (!this.target) throw new Error(I18n.t('未选择远程设备'));
    const deadline=Date.now()+90000;
    let transientFailures=0,lastFailure=I18n.t('等待设备授权超时');
    for(let attempt=0;attempt<120;attempt++){
      if(!allowed())throw new Error('已取消连接');
      if(Date.now()>=deadline)throw new Error(ConnectionHint.message(lastFailure));
      try{
        // HDC can return [Fail] as a successful command receipt. Approval can
        // also restart the peer socket before shell/identity becomes ready.
        // Retry the entire read-only pairing step on the same endpoint.
        const output=await this.command(1,DeviceInstallTarget.endpoint(this.target));
        if(!allowed())throw new Error('已取消连接');
        if(/\[Fail\]|error:/i.test(output))throw new Error(output);
        const facts=await this.command(22);
        if(!allowed())throw new Error('已取消连接');
        let details:Record<string,Object>;
        try{details=JSON.parse(facts) as Record<string,Object>;}catch(_){
          if(/\[Fail\]|E000003|error:|unauthoriz|denied/i.test(facts))throw new Error(facts);
          throw new Error(I18n.t('设备信息尚未就绪'));
        }
        if(!details)throw new Error(I18n.t('设备信息尚未就绪'));
        const rawKind=String(details['kind']??'').trim();
        const name=String(details['name']??'').trim();
        const udid=String(details['udid']??'').trim();
        if(/\[Fail\]|E000003|error:|unauthoriz|denied/i.test(rawKind+' '+udid))throw new Error(rawKind+' '+udid);
        if(!rawKind||!udid)throw new Error(I18n.t('设备信息尚未就绪'));
        const kind=DeviceInstallTarget.kind(rawKind);
        const match=/\b[0-9a-fA-F]{40,128}\b/.exec(udid);
        if(!kind)throw new Error('此设备不是可签装的手机、平板或电脑');
        if(!match)throw new Error(I18n.t('设备信息尚未就绪'));
        const value=match[0].toLowerCase();
        if(this.target.udid&&this.target.udid.toLowerCase()!==value)throw new Error(I18n.t('设备身份已变化，请重新确认设备'));
        const result=new DeviceInstallTarget();
        result.kind=kind;result.host=this.target.host;result.port=this.target.port;
        result.udid=value;result.key=value;
        result.name=(name||this.target.name||this.target.host).substring(0,80);
        result.model=DeviceInstallTarget.displayFact(details['model']);
        result.marketName=DeviceInstallTarget.displayFact(name);
        DeviceInstallTarget.snapshot(result);
        return result;
      }catch(error){
        if(!allowed())throw new Error('已取消连接');
        const detail=String(error);
        lastFailure=detail;
        // E000003 includes "user denied" even while the system trust sheet
        // is still open. Only an explicit authentication rejection is final.
        const waiting=/E000003|device unauthorized|not authorized|await.*trust/i.test(detail);
        const refused=/authentication rejected|身份已变化|不是可签装/i.test(detail)||
          (!waiting&&/permission denied|user.*(?:denied|rejected)/i.test(detail));
        // Our TCP frame reader reports a zero-byte close as "peer shutdown".
        // That is the same recoverable socket loss as EOF, not a trust refusal.
        const transient=waiting||/timed out|timeout|unauthoriz|eof|fill whole buffer|connection (?:reset|aborted|closed|refused)|peer (?:shutdown|closed)|broken pipe|channel closed|session not found|no connected target|target.*not (?:found|connected)|device metadata not ready|设备信息尚未就绪/i.test(detail);
        if(!waiting)transientFailures++;
        if(refused||!transient||transientFailures>=6||Date.now()>=deadline||
          (/timed out|timeout/i.test(detail)&&Date.now()+15000>=deadline)){
          throw new Error(/\[Fail\]|E000003|device unauthorized/i.test(detail)?ConnectionHint.message(detail):detail);
        }
        await new Promise<void>((resolve:()=>void)=>setTimeout(resolve,700));
      }
    }
    throw new Error(I18n.t('尚未读取到设备信息，请在对方设备允许无线调试后重试'));
  }

  async install(signedHapPath: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('签名包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
    const output = await this.observedCommand(4, signedHapPath, onProgress);
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output)) {
      throw new Error(output.trim().length > 0 ? output.trim() : I18n.t('设备未确认安装结果'));
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
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开，尚未卸载旧版'));
    return this.observedCommand(10, path, onProgress);
  }

  async installStaged(ticket: string, bundleName: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void> {
    const descriptor = JSON.parse(ticket) as Record<string, Object>;
    descriptor['bundleName'] = bundleName;
    onProgress?.('installing', 0, 0);
    const output = await this.command(11, JSON.stringify(descriptor));
    if (output.includes('[Fail]') || /\berror\s*:|\bfailed\b|\bcode\s*:\s*[1-9]\d*/i.test(output)) {
      throw new Error(output.trim() || I18n.t('设备未确认重装结果'));
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
      throw new Error(I18n.t('应用包名无效'));
    }
    // Keep background idle-disconnect from running between the uninstall and
    // its read-only confirmation. Submit the destructive command only once.
    HdcDeviceBridge.scans++;
    try {
      if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
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
          throw new Error(I18n.t('暂时无法确认卸载结果，请重连无线调试后刷新应用列表'));
        }
        if (!found.has(bundleName)) return;
        if (rejected || attempt === 5) break;
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 500); });
      }
      throw new Error(detail || I18n.t('设备上仍安装着该应用，请稍后重试'));
    } finally {
      HdcDeviceBridge.scans--;
      HdcDeviceBridge.idleHandler?.();
    }
  }

  async installSelfAfterUninstall(signedHapPath: string): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('安装器更新包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
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
      throw new Error(I18n.t('应用包名无效'));
    }
    if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
    const output = await this.command(5, bundleName);
    if (output.includes('[Fail]')) throw new Error(I18n.t('无法读取设备上的安装状态'));
    // bm dump 只在包存在时才输出 versionCode
    return /"versionCode"\s*:\s*\d+/.test(output);
  }

  /** 先取存在性清单，再只查询目录关心的包版本；清单本身不含 versionCode。 */
  async installedBundleVersions(bundleNames: string[] = [],
    onProgress?: (checked: number, total: number, bundleName?: string,
      version?: number) => void, interactive?: () => boolean): Promise<Map<string, number> | undefined> {
    if(this.target)throw new Error(I18n.t('远程设备清单不能写入本机应用缓存'));
    await ForegroundIdle.wait(interactive);
    HdcDeviceBridge.scans++;
    const startedAt = Date.now();
    let checked = 0;
    let present = 0;
    let queried = 0;
    try {
      const unique = new Set<string>(bundleNames);
      onProgress?.(checked, unique.size);
      await InstalledAppRegistry.load(this.context);
      if (!await this.connected()) throw new Error(I18n.t('无线调试已断开'));
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
          // 手动刷新让出事件循环即可；自动维护仍避开滚动和窗口展开动画。
          await ForegroundIdle.wait(interactive);
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

  /** One local, authenticated HDC query returns installed bundle names and system labels. */
  async installedApplicationLabels(): Promise<string> {
    if (this.target) throw new Error(I18n.t('只能查询本机应用'));
    if (!await this.connected()) throw new Error(I18n.t('无线调试未连接'));
    const result = await this.command(26);
    const marker = '__QINGQI_APP_LABELS_END__';
    const end = result.indexOf(marker);
    if (end < 0 || result.includes('[Fail]')) throw new Error(I18n.t('无法读取完整的已安装清单，请重试'));
    return result.substring(0, end);
  }

  /** 只读调试签名应用，避免遍历系统应用；名称与入口缓存到本机，离线仍可打开。 */
  async sideloadedApps(knownBundles: string[] = []): Promise<InstalledDeviceApp[]> {
    if(this.target)throw new Error(I18n.t('远程设备清单不能写入本机应用缓存'));
    HdcDeviceBridge.scans++;
    try {
      await InstalledAppRegistry.load(this.context);
      if (!await this.connected()) throw new Error(I18n.t('无线调试未连接'));
      const names = InstalledAppRegistry.parseSideloadedNames(await this.command(13));
      if (names === undefined) throw new Error(I18n.t('设备未返回完整的侧载应用清单'));
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
    if(this.target)throw new Error(I18n.t('请在目标设备打开应用'));
    await InstalledAppRegistry.load(this.context);
    let target = InstalledAppRegistry.launcher(bundleName);
    if (target === undefined && abilityName.length === 0) {
      await this.installedVersion(bundleName);
      target = InstalledAppRegistry.launcher(bundleName);
    }
    const entryAbility = target?.abilityName ?? abilityName;
    const entryModule = target?.moduleName ?? moduleName;
    if (entryAbility.length === 0) throw new Error(I18n.t('尚未读取到应用启动入口，请连接无线调试后重试'));
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
