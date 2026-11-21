import { util } from '@kit.ArkTS';
import { asset } from '@kit.AssetStoreKit';
import { I18n } from './I18n';

export class DownloadProxyCredentials {
  username: string = '';
  password: string = '';

  static encode(protocol: string, username: string, password: string): Uint8Array | undefined {
    if (!username && !password) return undefined;
    if (!username || !password || /[\x00-\x1f\x7f]/.test(username + password) ||
      (protocol === 'http' && username.includes(':'))) {
      throw new Error(I18n.t('请输入有效的代理用户名和密码'));
    }
    const encoder = new util.TextEncoder();
    const secret = encoder.encodeInto(username + '\n' + password);
    if (secret.length > 1024 || (protocol === 'socks5' &&
      (encoder.encodeInto(username).length > 255 || encoder.encodeInto(password).length > 255))) {
      throw new Error(I18n.t('代理用户名或密码过长'));
    }
    return secret;
  }

  private static lookup(reference: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('qingqi-proxy-' + reference));
    return query;
  }

  static async add(secret: Uint8Array): Promise<string> {
    const reference = util.generateRandomUUID();
    const attributes = DownloadProxyCredentials.lookup(reference);
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    try {
      await asset.add(attributes);
      return reference;
    } catch (_) {
      throw new Error(I18n.t('无法安全保存代理凭据'));
    }
  }

  static async read(reference: string): Promise<DownloadProxyCredentials> {
    const credentials = new DownloadProxyCredentials();
    if (!reference) return credentials;
    try {
      const query = DownloadProxyCredentials.lookup(reference);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows = await asset.query(query);
      const secret = rows[0]?.get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        const value = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(secret);
        const delimiter = value.indexOf('\n');
        if (delimiter > 0 && delimiter < value.length - 1) {
          credentials.username = value.substring(0, delimiter);
          credentials.password = value.substring(delimiter + 1);
          return credentials;
        }
      }
    } catch (_) { /* Keep native error details and the secret out of UI and logs. */ }
    throw new Error(I18n.t('无法读取代理凭据，请重新输入'));
  }

  static async remove(reference: string): Promise<void> {
    try { await asset.remove(DownloadProxyCredentials.lookup(reference)); } catch (_) {}
  }
}
