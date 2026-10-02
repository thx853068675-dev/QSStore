import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

class SavedIcon {
  version: number = 0;
  at: number = 0;
  data: string = '';
}

/** 图标独立于可清理的安装包，按包名和实际构建缓存，最多占用 8 MiB。 */
export class InstalledIconCache {
  private static saving: Promise<void> = Promise.resolve();
  private static readonly MAX_BYTES: number = 512 * 1024;
  private static readonly MAX_CHARACTERS: number = 700 * 1024;

  private static key(bundleName: string): string {
    return /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName) ? 'icon-' + bundleName : '';
  }

  static async load(context: common.UIAbilityContext, bundleName: string,
    version: number): Promise<ArrayBuffer | undefined> {
    const key = InstalledIconCache.key(bundleName);
    if (key.length === 0 || version <= 0) return undefined;
    try {
      const store = await preferences.getPreferences(context, 'installed-icons');
      const raw = await store.get(key, '') as string;
      if (raw.length === 0 || raw.length > InstalledIconCache.MAX_CHARACTERS) return undefined;
      const row = JSON.parse(raw) as SavedIcon;
      if (row.version !== version || typeof row.data !== 'string') return undefined;
      const bytes = new util.Base64Helper().decodeSync(row.data);
      if (bytes.byteLength === 0 || bytes.byteLength > InstalledIconCache.MAX_BYTES) return undefined;
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    } catch (_) { return undefined; }
  }

  static save(context: common.UIAbilityContext, bundleName: string, version: number,
    bytes: ArrayBuffer): Promise<void> {
    const key = InstalledIconCache.key(bundleName);
    if (key.length === 0 || !Number.isSafeInteger(version) || version <= 0 ||
      bytes.byteLength === 0 || bytes.byteLength > InstalledIconCache.MAX_BYTES) return Promise.resolve();
    // 在排队前复制数据，调用方可以释放解码来源。
    const row = new SavedIcon(); row.version = version; row.at = Date.now();
    row.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
    InstalledIconCache.saving = InstalledIconCache.saving.then(async () => {
      try {
        const store = await preferences.getPreferences(context, 'installed-icons');
        await store.put(key, JSON.stringify(row));
        const all = await store.getAll() as Record<string, Object>;
        const keys = Object.keys(all);
        let size = keys.reduce((sum: number, name: string) => sum + String(all[name]).length, 0);
        keys.sort((left: string, right: string) => {
          try { return (JSON.parse(String(all[left])) as SavedIcon).at - (JSON.parse(String(all[right])) as SavedIcon).at; }
          catch (_) { return 0; }
        });
        for (const name of keys) {
          if (size <= 8 * 1024 * 1024) break;
          if (name === key) continue;
          size -= String(all[name]).length;
          await store.delete(name);
        }
        await store.flush();
      } catch (_) {}
    });
    return InstalledIconCache.saving;
  }
}
