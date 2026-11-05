import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class DownloadProxySetting {
  enabled: boolean = false;
  address: string = '';
}

export class DownloadProxyPreferences {
  static compose(protocol: string, host: string, port: string): string {
    const normalized = DownloadProxyPreferences.normalize(host.trim() + ':' + port.trim());
    if (protocol === 'http') return normalized;
    if (protocol === 'socks5') return 'socks5://' + normalized.substring(7);
    throw new Error('请选择代理协议');
  }
  static normalize(value: string): string {
    const input = value.trim();
    const match = /^(?:http:\/\/)?([a-z0-9.-]+|\[[0-9a-f:]+\]):([0-9]{1,5})\/?$/i.exec(input);
    if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) {
      throw new Error('请输入 HTTP 代理地址，例如 http://127.0.0.1:7890');
    }
    return 'http://' + match[1] + ':' + String(Number(match[2]));
  }

  static async load(context: common.UIAbilityContext): Promise<DownloadProxySetting> {
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    const result = new DownloadProxySetting();
    result.enabled = (await store.get('downloadProxyEnabled', false)) === true;
    result.address = String(await store.get('downloadProxyAddress', ''));
    if (result.enabled && !/^socks5:\/\//i.test(result.address)) result.address = DownloadProxyPreferences.normalize(result.address);
    return result;
  }

  static async save(context: common.UIAbilityContext, enabled: boolean, address: string): Promise<void> {
    const normalized = enabled && !/^socks5:\/\//i.test(address) ? DownloadProxyPreferences.normalize(address) : address.trim();
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    const previousAddress = await store.get('downloadProxyAddress', '');
    const previousEnabled = await store.get('downloadProxyEnabled', false);
    try {
      await store.put('downloadProxyAddress', normalized);
      await store.put('downloadProxyEnabled', enabled);
      await store.flush();
    } catch (error) {
      try {
        await store.put('downloadProxyAddress', previousAddress);
        await store.put('downloadProxyEnabled', previousEnabled);
        await store.flush();
      } catch (_) {}
      throw error as Error;
    }
  }
}
