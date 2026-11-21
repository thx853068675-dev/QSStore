import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DownloadProxyCredentials } from './DownloadProxyCredentials';

export class DownloadProxySetting extends DownloadProxyCredentials {
  enabled: boolean = false;
  address: string = '';
}

export class DownloadProxyProfiles {
  addresses: string[] = [];
  activeAddress: string = '';
  authRefs: Record<string, string> = {};
}

export class DownloadProxyPreferences {
  private static readonly profilesKey: string = 'downloadProxyProfiles';
  private static pending: Promise<void> = Promise.resolve();

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
    return 'http://' + match[1].toLowerCase() + ':' + String(Number(match[2]));
  }

  private static canonicalAddress(address: string): string {
    const value = address.trim();
    return /^socks5:\/\//i.test(value) ?
      'socks5://' + DownloadProxyPreferences.normalize(value.substring(9)).substring(7) :
      DownloadProxyPreferences.normalize(value);
  }

  private static readAddress(value: string): string {
    try { return DownloadProxyPreferences.canonicalAddress(value); } catch (_) { return ''; }
  }

  private static async readProfiles(store: preferences.Preferences, raw: string): Promise<DownloadProxyProfiles> {
    const profiles = new DownloadProxyProfiles();
    if (raw.length > 0) {
      try {
        const saved = JSON.parse(raw) as DownloadProxyProfiles;
        if (Array.isArray(saved.addresses)) {
          for (const value of saved.addresses) {
            if (typeof value !== 'string') continue;
            const address = DownloadProxyPreferences.readAddress(value);
            if (address && !profiles.addresses.includes(address)) profiles.addresses.push(address);
            const reference = saved.authRefs?.[value];
            if (address && typeof reference === 'string' && /^[a-f0-9-]{36}$/i.test(reference)) {
              profiles.authRefs[address] = reference;
            }
          }
        }
        if (typeof saved.activeAddress === 'string') {
          const active = DownloadProxyPreferences.readAddress(saved.activeAddress);
          if (profiles.addresses.includes(active)) profiles.activeAddress = active;
        }
        return profiles;
      } catch (_) { /* Recover the previous format if the profile record cannot be read. */ }
    }
    const previous = DownloadProxyPreferences.readAddress(String(await store.get('downloadProxyAddress', '')));
    if (previous) {
      profiles.addresses.push(previous);
      if (await store.get('downloadProxyEnabled', false) === true) profiles.activeAddress = previous;
    }
    return profiles;
  }

  static async loadProfiles(context: common.UIAbilityContext): Promise<DownloadProxyProfiles> {
    return DownloadProxyPreferences.inOrder(() => DownloadProxyPreferences.read(context));
  }

  private static async read(context: common.UIAbilityContext): Promise<DownloadProxyProfiles> {
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    return DownloadProxyPreferences.readProfiles(store, String(await store.get(DownloadProxyPreferences.profilesKey, '')));
  }

  static async load(context: common.UIAbilityContext): Promise<DownloadProxySetting> {
    return DownloadProxyPreferences.inOrder(async (): Promise<DownloadProxySetting> => {
      const profiles = await DownloadProxyPreferences.read(context);
      const result = new DownloadProxySetting();
      result.address = profiles.activeAddress;
      result.enabled = result.address.length > 0;
      const credentials = await DownloadProxyCredentials.read(profiles.authRefs[result.address] ?? '');
      result.username = credentials.username;
      result.password = credentials.password;
      return result;
    });
  }

  static credentialsFor(context: common.UIAbilityContext, address: string): Promise<DownloadProxyCredentials> {
    return DownloadProxyPreferences.inOrder(async (): Promise<DownloadProxyCredentials> => {
      const profiles = await DownloadProxyPreferences.read(context);
      return DownloadProxyCredentials.read(profiles.authRefs[address] ?? '');
    });
  }

  private static inOrder<T>(work: () => Promise<T>): Promise<T> {
    const result = DownloadProxyPreferences.pending.then(work);
    DownloadProxyPreferences.pending = result.then(() => {}, () => {});
    return result;
  }

  private static update(context: common.UIAbilityContext,
    change: (profiles: DownloadProxyProfiles) => void, credentialAddress: string = '',
    secret?: Uint8Array): Promise<DownloadProxyProfiles> {
    return DownloadProxyPreferences.inOrder(async (): Promise<DownloadProxyProfiles> => {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      const key = DownloadProxyPreferences.profilesKey;
      const previous = String(await store.get(key, ''));
      const profiles = await DownloadProxyPreferences.readProfiles(store, previous);
      const oldReferences = Object.values(profiles.authRefs);
      change(profiles);
      const reference = secret ? await DownloadProxyCredentials.add(secret) : '';
      const nextReferences: Record<string, string> = {};
      for (const address of profiles.addresses) {
        const saved = address === credentialAddress ? reference : profiles.authRefs[address];
        if (saved) nextReferences[address] = saved;
      }
      profiles.authRefs = nextReferences;
      try {
        await store.put(key, JSON.stringify(profiles));
        await store.flush();
      } catch (error) {
        try {
          await store.put(key, previous);
          await store.flush();
          if (reference) await DownloadProxyCredentials.remove(reference);
        } catch (_) {}
        throw error as Error;
      }
      const current = Object.values(profiles.authRefs);
      for (const old of oldReferences) {
        if (!current.includes(old)) await DownloadProxyCredentials.remove(old);
      }
      return profiles;
    });
  }

  static saveProfile(context: common.UIAbilityContext, address: string,
    previous: string = '', username: string = '', password: string = ''): Promise<DownloadProxyProfiles> {
    const normalized = DownloadProxyPreferences.canonicalAddress(address);
    const secret = DownloadProxyCredentials.encode(normalized.startsWith('socks5://') ? 'socks5' : 'http', username, password);
    return DownloadProxyPreferences.update(context, (profiles: DownloadProxyProfiles) => {
      const index = previous ? profiles.addresses.indexOf(previous) : -1;
      if (index < 0) {
        if (!profiles.addresses.includes(normalized)) profiles.addresses.push(normalized);
      } else if (normalized !== previous) {
        if (profiles.addresses.includes(normalized)) profiles.addresses.splice(index, 1);
        else profiles.addresses[index] = normalized;
        if (profiles.activeAddress === previous) profiles.activeAddress = normalized;
      }
    }, normalized, secret);
  }

  static activate(context: common.UIAbilityContext, address: string): Promise<DownloadProxyProfiles> {
    return DownloadProxyPreferences.update(context, (profiles: DownloadProxyProfiles) => {
      if (address && !profiles.addresses.includes(address)) throw new Error('代理配置已不存在');
      profiles.activeAddress = address;
    });
  }

  static remove(context: common.UIAbilityContext, address: string): Promise<DownloadProxyProfiles> {
    return DownloadProxyPreferences.update(context, (profiles: DownloadProxyProfiles) => {
      profiles.addresses = profiles.addresses.filter((item: string) => item !== address);
      if (profiles.activeAddress === address) profiles.activeAddress = '';
    });
  }
}
