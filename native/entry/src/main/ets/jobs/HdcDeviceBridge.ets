import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hdcCommand, hdcDisconnect } from 'libhap_core.so';
import { NativeDeviceBridge } from './NativeJobRuntime';

// All commands share one in-process Rust HDC host. Serialize install and
// verification so a second UI action cannot overtake an active transfer.
export class HdcDeviceBridge implements NativeDeviceBridge {
  /** 本进程是否建立过设备链路。断开或进程结束即复位。 */
  private static linked: boolean = false;

  private static queue: Promise<void> = Promise.resolve();
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private async command(operation: number, parameter: string = ''): Promise<string> {
    const previous = HdcDeviceBridge.queue;
    let release: () => void = () => {};
    HdcDeviceBridge.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    await previous;
    try {
      const output = await hdcCommand(this.context.filesDir, operation, parameter);
      // 只要命令真的跑过，服务端就建了到设备的链路
      if (operation !== 0) HdcDeviceBridge.linked = true;
      return output;
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
      HdcDeviceBridge.linked = false;
      return dropped;
    } catch (_) {
      return false;
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

  private async savedPort(): Promise<number> {
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    return Number(await store.get('port', 0));
  }

  private async rememberPort(port: number): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'wireless-debug');
    await store.put('port', port);
    await store.flush();
  }

  private async liveUdid(): Promise<string> {
    const output = await this.command(2);
    if (output.includes('[Fail]')) return '';
    const match = /\b[0-9a-fA-F]{40,128}\b/.exec(output);
    return match ? match[0] : '';
  }

  async connected(): Promise<boolean> {
    try {
      if ((await this.liveUdid()).length > 0) return true;
      const port = await this.savedPort();
      if (port <= 0) return false;
      return await this.connect(port, false);
    } catch (_) {
      return false;
    }
  }

  async connect(port: number, persist: boolean = true): Promise<boolean> {
    if (!Number.isInteger(port) || port < 1024 || port > 65535) {
      throw new Error('请输入无线调试页显示的端口号');
    }
    for (const host of ['127.0.0.1', 'localhost']) {
      for (let attempt = 0; attempt < (host === '127.0.0.1' ? 2 : 1); attempt++) {
        await this.command(1, host + ':' + port);
        if ((await this.liveUdid()).length > 0) {
          if (persist) await this.rememberPort(port);
          return true;
        }
        // A first connection can finish while the system trust decision is
        // still being committed. Retry that same port once without asking the
        // user to press Connect again.
        if (attempt === 0 && host === '127.0.0.1') {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 700));
        }
      }
    }
    return false;
  }

  async udid(): Promise<string> {
    if (!await this.connected()) throw new Error('无线调试尚未连接');
    const value = await this.liveUdid();
    if (value.length === 0) throw new Error('无法读取设备 UDID');
    return value;
  }

  async installedVersion(bundleName: string): Promise<number> {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) {
      throw new Error('应用包名无效');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(3, bundleName);
    const firstBrace = output.indexOf('{');
    if (firstBrace < 0) return 0;
    try {
      const row = JSON.parse(output.substring(firstBrace)) as Record<string, Object>;
      return Number(row['versionCode'] ?? 0);
    } catch (_) {
      throw new Error('无法确认设备上的已安装版本');
    }
  }

  async install(signedHapPath: string): Promise<void> {
    if (!fileIo.accessSync(signedHapPath) || !signedHapPath.startsWith(this.context.filesDir + '/')) {
      throw new Error('签名包不在应用工作目录中');
    }
    if (!await this.connected()) throw new Error('无线调试已断开');
    const output = await this.command(4, signedHapPath);
    if (output.includes('[Fail]')) {
      throw new Error(output.trim().length > 0 ? output.trim() : '设备未确认安装结果');
    }
    // The Rust HDC client can report only "AppMod finish". JobRunner queries
    // the device's installed version after this command; text is never proof.
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

  async openWirelessSettings(): Promise<void> {
    await this.context.startAbility({
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      action: 'ohos.want.action.viewData',
      uri: 'system_wireless_commissioning'
    });
  }
}
