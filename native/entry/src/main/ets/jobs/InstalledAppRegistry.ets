import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 跨页面复用设备已确认的版本；没有安装记录的侧载应用也能被识别。 */
class InstalledVersionEntry {
  version: number = 0;
  at: number = 0;
}

class SavedInstalledEntry {
  bundleName: string = '';
  version: number = 0;
  at: number = 0;
  moduleName: string = '';
  abilityName: string = '';
}

export class InstalledLaunchTarget {
  bundleName: string = '';
  moduleName: string = '';
  abilityName: string = '';
}

/** 设备当前安装包的签名身份；仅实时 bm dump 可作为覆盖更新的预检依据。 */
export class InstalledSigningIdentity {
  versionCode: number = 0;
  fingerprint: string = '';
  appIdentifier: string = '';
}

export class InstalledAppRegistry {
  private static readonly STORE_NAME: string = 'installed-bundles';
  private static readonly STORE_KEY: string = 'last-confirmed';
  private static readonly SAVED_MAX_AGE_MS: number = 30 * 24 * 60 * 60 * 1000;
  private static readonly SAVED_MAX_ROWS: number = 300;
  private static loading?: Promise<void>;
  private static saving: Promise<void> = Promise.resolve();
  private static launchers: Map<string, InstalledLaunchTarget> = new Map();
  private static savedVersions: Map<string, InstalledVersionEntry> = new Map();

  /** 只载入设备曾确认安装的应用；过期或损坏的缓存不参与展示。 */
  static async load(context: common.UIAbilityContext): Promise<void> {
    if (InstalledAppRegistry.loading !== undefined) return InstalledAppRegistry.loading;
    InstalledAppRegistry.loading = InstalledAppRegistry.loadSaved(context);
    return InstalledAppRegistry.loading;
  }

  private static async loadSaved(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, InstalledAppRegistry.STORE_NAME);
      const raw = await store.get(InstalledAppRegistry.STORE_KEY, '') as string;
      if (raw.length === 0 || raw.length > 256 * 1024) return;
      const rows = JSON.parse(raw) as Array<Record<string, Object>>;
      if (!Array.isArray(rows)) return;
      const now = Date.now();
      for (const row of rows.slice(0, InstalledAppRegistry.SAVED_MAX_ROWS)) {
        if (row === null || typeof row !== 'object') continue;
        const name = String(row['bundleName'] ?? '');
        const version = Number(row['version'] ?? 0);
        const at = Number(row['at'] ?? 0);
        if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(name) ||
          !Number.isSafeInteger(version) || version <= 0 || !Number.isFinite(at) ||
          at <= 0 || at > now || now - at > InstalledAppRegistry.SAVED_MAX_AGE_MS) continue;
        const existing = InstalledAppRegistry.savedVersions.get(name);
        if (existing !== undefined && existing.at >= at) continue;
        const entry = new InstalledVersionEntry();
        entry.version = version;
        entry.at = at;
        InstalledAppRegistry.savedVersions.set(name, entry);
        const moduleName = String(row['moduleName'] ?? '');
        const abilityName = String(row['abilityName'] ?? '');
        if (/^[A-Za-z][A-Za-z0-9_.]{0,255}$/.test(moduleName) &&
          /^[A-Za-z][A-Za-z0-9_.]{0,255}$/.test(abilityName)) {
          const target = new InstalledLaunchTarget();
          target.bundleName = name;
          target.moduleName = moduleName;
          target.abilityName = abilityName;
          InstalledAppRegistry.launchers.set(name, target);
        }
      }
    } catch (_) {
      // 缓存读不到不能妨碍实时查询。
    }
  }

  /** HDC 批量查询只在最后调用一次；写入失败不影响安装状态查询。 */
  static async persist(context: common.UIAbilityContext): Promise<void> {
    await InstalledAppRegistry.load(context);
    InstalledAppRegistry.saving = InstalledAppRegistry.saving.then(async () => {
      try {
        const now = Date.now();
        const rows: SavedInstalledEntry[] = [];
        for (const name of InstalledAppRegistry.savedVersions.keys()) {
          const entry = InstalledAppRegistry.savedVersions.get(name);
          if (entry === undefined || entry.version <= 0 ||
            now - entry.at > InstalledAppRegistry.SAVED_MAX_AGE_MS) continue;
          const row = new SavedInstalledEntry();
          row.bundleName = name;
          row.version = entry.version;
          row.at = entry.at;
          const target = InstalledAppRegistry.launchers.get(name);
          row.moduleName = target?.moduleName ?? '';
          row.abilityName = target?.abilityName ?? '';
          rows.push(row);
        }
        rows.sort((left: SavedInstalledEntry, right: SavedInstalledEntry) => right.at - left.at);
        const store = await preferences.getPreferences(context, InstalledAppRegistry.STORE_NAME);
        await store.put(InstalledAppRegistry.STORE_KEY,
          JSON.stringify(rows.slice(0, InstalledAppRegistry.SAVED_MAX_ROWS)));
        await store.flush();
      } catch (_) {
        // 缓存失败不能让实时查询变成失败。
      }
    });
    return InstalledAppRegistry.saving;
  }

  static launcher(bundleName: string): InstalledLaunchTarget | undefined {
    return InstalledAppRegistry.version(bundleName) > 0 ? InstalledAppRegistry.launchers.get(bundleName) : undefined;
  }

  static rememberLauncher(output: string, bundleName: string): void {
    const row = JSON.parse(output.substring(output.indexOf('{'))) as Record<string, Object>;
    if (String(row['name'] ?? '') !== bundleName) return;
    const modules = row['hapModuleInfos'] as Array<Record<string, Object>> | undefined;
    const entry = String(row['entryModuleName'] ?? row['mainEntry'] ?? '');
    const module = modules?.find((item: Record<string, Object>) =>
      String(item['moduleName'] ?? item['name'] ?? '') === entry);
    if (module === undefined) return;
    const target = new InstalledLaunchTarget();
    target.bundleName = bundleName;
    target.moduleName = entry;
    target.abilityName = String(module['mainAbility'] ?? module['mainElementName'] ?? '');
    if (target.moduleName.length > 0 && target.abilityName.length > 0) {
      InstalledAppRegistry.launchers.set(bundleName, target);
    }
  }

  private static versions: Map<string, InstalledVersionEntry> = new Map();
  private static readonly TTL_MS: number = 60000;

  static remember(bundleName: string, version: number): void {
    if (!Number.isInteger(version) || version < 0) return;
    const previous = InstalledAppRegistry.savedVersions.get(bundleName);
    const entry = new InstalledVersionEntry();
    entry.version = version;
    entry.at = Date.now();
    InstalledAppRegistry.versions.set(bundleName, entry);
    if (version > 0) {
      if (previous !== undefined && previous.version !== version) {
        InstalledAppRegistry.launchers.delete(bundleName);
      }
      InstalledAppRegistry.savedVersions.set(bundleName, entry);
    }
    else {
      InstalledAppRegistry.savedVersions.delete(bundleName);
      InstalledAppRegistry.launchers.delete(bundleName);
    }
  }

  static version(bundleName: string): number {
    const entry = InstalledAppRegistry.versions.get(bundleName);
    if (entry !== undefined && Date.now() - entry.at < InstalledAppRegistry.TTL_MS) return entry.version;
    const saved = InstalledAppRegistry.savedVersions.get(bundleName);
    return saved !== undefined && Date.now() - saved.at < InstalledAppRegistry.SAVED_MAX_AGE_MS ?
      saved.version : -1;
  }

  /** -a 是存在性清单，不含版本；缺席才可以记为未安装。 */
  static parseNames(output: string): Map<string, number> | undefined {
    if (!/^ID:\s*\d+:\s*$/m.test(output) || /\[Fail\]|error:/i.test(output)) return undefined;
    const found = new Map<string, number>();
    for (const raw of output.split('\n')) {
      const name = raw.trim();
      if (/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(name)) found.set(name, 0);
    }
    // 空/截断输出无法证明卸载，避免清空安装记录。
    return found.size > 0 ? found : undefined;
  }

  static parseVersion(output: string, bundleName: string): number {
    const start = output.indexOf('{');
    if (start < 0) throw new Error('设备未返回应用版本信息');
    const row = JSON.parse(output.substring(start)) as Record<string, Object>;
    const version = Number(row['versionCode']);
    if (String(row['name'] ?? '') !== bundleName || !Number.isInteger(version) || version <= 0) {
      throw new Error('设备返回的应用身份或版本无效');
    }
    return version;
  }

  /** 返回 undefined 表示设备没给出可靠身份，仍由包管理器最终裁决。 */
  static parseSigningIdentity(output: string, bundleName: string): InstalledSigningIdentity | undefined {
    const start = output.indexOf('{');
    if (start < 0 || output.includes('[Fail]')) return undefined;
    try {
      const row = JSON.parse(output.substring(start)) as Record<string, Object>;
      const version = Number(row['versionCode'] ?? 0);
      if (String(row['name'] ?? '') !== bundleName || !Number.isSafeInteger(version) || version <= 0) {
        return undefined;
      }
      const app = row['applicationInfo'] as Record<string, Object> | undefined;
      const fingerprint = String(app?.['fingerprint'] ?? '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();
      const appIdentifier = String(row['appIdentifier'] ?? '');
      if (fingerprint.length !== 64 && appIdentifier.length === 0) return undefined;
      const identity = new InstalledSigningIdentity();
      identity.versionCode = version;
      identity.fingerprint = fingerprint.length === 64 ? fingerprint : '';
      identity.appIdentifier = appIdentifier;
      return identity;
    } catch (_) {
      return undefined;
    }
  }
}
