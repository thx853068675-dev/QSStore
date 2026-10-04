import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 跨页面复用设备已确认的版本；没有安装记录的侧载应用也能被识别。 */
class InstalledVersionEntry {
  version: number = 0;
  versionName: string = '';
  at: number = 0;
  firstSeenAt: number = 0;
  installationUpdateTime: number = 0;
  displayName: string = '';
  sideloaded: boolean = false;
  iconId: number = 0;
  iconModuleName: string = '';
  signingFingerprint: string = '';
  signingUpdateTime: number = 0;
  signingAppIdentifier: string = '';
}

class SavedInstalledEntry {
  bundleName: string = '';
  version: number = 0;
  versionName: string = '';
  at: number = 0;
  firstSeenAt: number = 0;
  installationUpdateTime: number = 0;
  moduleName: string = '';
  abilityName: string = '';
  displayName: string = '';
  sideloaded: boolean = false;
  iconId: number = 0;
  iconModuleName: string = '';
  signingFingerprint: string = '';
  signingUpdateTime: number = 0;
  signingAppIdentifier: string = '';
}

/** 设备清单的展示模型，独立于安装任务和历史记录。 */
export class InstalledDeviceApp {
  bundleName: string = '';
  displayName: string = '';
  versionCode: number = 0;
  versionName: string = '';
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
  updateTime: number = 0;
  fingerprint: string = '';
  appIdentifier: string = '';
}

export class InstalledAppRegistry {
  private static readonly STORE_NAME: string = 'installed-bundles';
  private static readonly STORE_KEY: string = 'last-confirmed';
  private static readonly SCAN_KEY: string = 'catalog-scan-at';
  private static scanAt: number = 0;
  private static readonly SAVED_MAX_AGE_MS: number = 30 * 24 * 60 * 60 * 1000;
  private static readonly SAVED_MAX_ROWS: number = 1000;
  private static loading?: Promise<void>;
  private static saving: Promise<void> = Promise.resolve();
  private static launchers: Map<string, InstalledLaunchTarget> = new Map();
  private static savedVersions: Map<string, InstalledVersionEntry> = new Map();

  /** 恢复本机确认状态；卸载记录保留到下一次真实安装，避免旧安装历史复活。 */
  static async load(context: common.UIAbilityContext): Promise<void> {
    if (InstalledAppRegistry.loading !== undefined) return InstalledAppRegistry.loading;
    InstalledAppRegistry.loading = InstalledAppRegistry.loadSaved(context);
    return InstalledAppRegistry.loading;
  }

  private static async loadSaved(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, InstalledAppRegistry.STORE_NAME);
      const now = Date.now();
      const scanAt = Number(await store.get(InstalledAppRegistry.SCAN_KEY, 0));
      if (Number.isFinite(scanAt) && scanAt > 0 && scanAt <= now) {
        InstalledAppRegistry.scanAt = scanAt;
      }
      const raw = await store.get(InstalledAppRegistry.STORE_KEY, '') as string;
      if (raw.length === 0 || raw.length > 1024 * 1024) return;
      const rows = JSON.parse(raw) as Array<Record<string, Object>>;
      if (!Array.isArray(rows)) return;
      for (const row of rows.slice(0, InstalledAppRegistry.SAVED_MAX_ROWS)) {
        if (row === null || typeof row !== 'object') continue;
        const name = String(row['bundleName'] ?? '');
        const version = Number(row['version'] ?? 0);
        const at = Number(row['at'] ?? 0);
        if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(name) ||
          typeof row['version'] !== 'number' || !Number.isSafeInteger(version) || version < 0 || !Number.isFinite(at) ||
          at <= 0 || at > now || (version > 0 && now - at > InstalledAppRegistry.SAVED_MAX_AGE_MS)) continue;
        // 启动读盘期间的实时观察优先，包括尚未落盘的卸载。
        if (InstalledAppRegistry.versions.has(name)) continue;
        const existing = InstalledAppRegistry.savedVersions.get(name);
        if (existing !== undefined && existing.at >= at) continue;
        const entry = new InstalledVersionEntry();
        entry.version = version;
        entry.versionName = String(row['versionName'] ?? '').trim().substring(0, 128);
        entry.at = at;
        const firstSeenAt = Number(row['firstSeenAt'] ?? at);
        entry.firstSeenAt = Number.isSafeInteger(firstSeenAt) && firstSeenAt > 0 && firstSeenAt <= at ? firstSeenAt : at;
        const installationUpdateTime = Number(row['installationUpdateTime'] ?? row['signingUpdateTime'] ?? 0);
        entry.installationUpdateTime = version > 0 && Number.isSafeInteger(installationUpdateTime) &&
          installationUpdateTime > 0 && installationUpdateTime <= now + 300000 ? installationUpdateTime : 0;
        entry.displayName = String(row['displayName'] ?? '').trim().substring(0, 256);
        entry.sideloaded = version > 0 && row['sideloaded'] === true;
        const iconId = Number(row['iconId'] ?? 0);
        entry.iconId = Number.isSafeInteger(iconId) && iconId > 0 ? iconId : 0;
        entry.iconModuleName = String(row['iconModuleName'] ?? '');
        const fingerprint = String(row['signingFingerprint'] ?? '');
        const updateTime = Number(row['signingUpdateTime'] ?? 0);
        if (version > 0 && /^[A-F0-9]{64}$/.test(fingerprint) && Number.isSafeInteger(updateTime) && updateTime > 0) {
          entry.signingFingerprint = fingerprint; entry.signingUpdateTime = updateTime;
          entry.signingAppIdentifier = String(row['signingAppIdentifier'] ?? '');
        }
        InstalledAppRegistry.savedVersions.set(name, entry);
        const moduleName = String(row['moduleName'] ?? '');
        const abilityName = String(row['abilityName'] ?? '');
        if (version > 0 && /^[A-Za-z][A-Za-z0-9_.]{0,255}$/.test(moduleName) &&
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

  static hasCatalogSnapshot(): boolean {
    return InstalledAppRegistry.scanAt > 0 &&
      Date.now() - InstalledAppRegistry.scanAt < InstalledAppRegistry.SAVED_MAX_AGE_MS;
  }

  /** 只有完整目录的安装状态都已核实时才记录，局部或失败查询不算首轮完成。 */
  static async markCatalogSnapshot(context: common.UIAbilityContext): Promise<void> {
    await InstalledAppRegistry.load(context);
    try {
      const at = Date.now();
      const store = await preferences.getPreferences(context, InstalledAppRegistry.STORE_NAME);
      await store.put(InstalledAppRegistry.SCAN_KEY, at);
      await store.flush();
      InstalledAppRegistry.scanAt = at;
    } catch (_) {}
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
          if (entry === undefined || entry.version < 0 || (entry.version > 0 &&
            now - entry.at > InstalledAppRegistry.SAVED_MAX_AGE_MS)) continue;
          const row = new SavedInstalledEntry();
          row.bundleName = name;
          row.version = entry.version;
          row.versionName = entry.versionName;
          row.at = entry.at;
          row.firstSeenAt = entry.firstSeenAt;
          row.installationUpdateTime = entry.installationUpdateTime;
          row.displayName = entry.displayName;
          row.sideloaded = entry.sideloaded;
          row.iconId = entry.iconId;
          row.iconModuleName = entry.iconModuleName;
          row.signingFingerprint = entry.signingFingerprint; row.signingUpdateTime = entry.signingUpdateTime;
          row.signingAppIdentifier = entry.signingAppIdentifier;
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
    InstalledAppRegistry.rememberLauncherRow(row, bundleName);
  }

  private static rememberLauncherRow(row: Record<string, Object>, bundleName: string): void {
    if (String(row['name'] ?? '') !== bundleName) return;
    const observed = InstalledAppRegistry.savedVersions.get(bundleName);
    if (observed !== undefined && observed.version === Number(row['versionCode'])) {
      const updateTime = Number(row['updateTime'] || row['installTime'] || 0);
      observed.installationUpdateTime = Number.isSafeInteger(updateTime) && updateTime > 0 &&
        updateTime <= Date.now() + 300000 ? updateTime : 0;
      observed.versionName = String(row['versionName'] ?? '').trim().substring(0, 128);
      const app = row['applicationInfo'] as Record<string, Object> | undefined;
      const icon = app?.['iconResource'] as Record<string, Object> | undefined;
      const iconId = Number(icon?.['id'] ?? app?.['iconId'] ?? 0);
      observed.iconId = Number.isSafeInteger(iconId) && iconId > 0 ? iconId : 0;
      observed.iconModuleName = String(icon?.['moduleName'] ?? row['entryModuleName'] ?? '');
      const signing = InstalledAppRegistry.signingIdentityFromRow(row, bundleName);
      // A complete dump that lacks signing evidence invalidates an older guess.
      observed.signingFingerprint = signing?.fingerprint ?? '';
      observed.signingUpdateTime = signing?.updateTime ?? 0;
      observed.signingAppIdentifier = signing?.appIdentifier ?? '';
    }
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

  static remember(bundleName: string, version: number, versionName: string = ''): void {
    if (!Number.isInteger(version) || version < 0) return;
    const previous = InstalledAppRegistry.savedVersions.get(bundleName);
    const entry = new InstalledVersionEntry();
    entry.version = version;
    entry.versionName = version > 0 && versionName.trim().length > 0 ? versionName.trim().substring(0, 128) :
      previous?.version === version ? previous.versionName : '';
    entry.displayName = version > 0 ? previous?.displayName ?? '' : '';
    entry.sideloaded = version > 0 && (previous?.sideloaded ?? false);
    entry.iconId = previous?.version === version ? previous.iconId : 0;
    entry.iconModuleName = previous?.version === version ? previous.iconModuleName : '';
    if (version > 0 && previous?.version === version) {
      entry.signingFingerprint = previous.signingFingerprint; entry.signingUpdateTime = previous.signingUpdateTime;
      entry.signingAppIdentifier = previous.signingAppIdentifier;
    }
    entry.at = Date.now();
    entry.firstSeenAt = previous?.version === version ? previous.firstSeenAt || previous.at : entry.at;
    entry.installationUpdateTime = version > 0 && previous?.version === version ? previous.installationUpdateTime : 0;
    InstalledAppRegistry.versions.set(bundleName, entry);
    InstalledAppRegistry.savedVersions.set(bundleName, entry);
    if (version > 0) {
      if (previous !== undefined && previous.version !== version) {
        InstalledAppRegistry.launchers.delete(bundleName);
      }
    }
    else {
      InstalledAppRegistry.launchers.delete(bundleName);
    }
  }

  static version(bundleName: string): number {
    const entry = InstalledAppRegistry.versions.get(bundleName);
    if (entry !== undefined && Date.now() - entry.at < InstalledAppRegistry.TTL_MS) return entry.version;
    const saved = InstalledAppRegistry.savedVersions.get(bundleName);
    return saved !== undefined && (saved.version === 0 ||
      Date.now() - saved.at < InstalledAppRegistry.SAVED_MAX_AGE_MS) ?
      saved.version : -1;
  }

  /** Cached identity is display evidence only; install safety still uses a live dump. */
  static signingIdentity(bundleName: string, maxAgeMs: number = InstalledAppRegistry.SAVED_MAX_AGE_MS): InstalledSigningIdentity | undefined {
    const entry = InstalledAppRegistry.savedVersions.get(bundleName);
    if (!entry || InstalledAppRegistry.version(bundleName) !== entry.version || entry.version <= 0 ||
      Date.now() - entry.at > maxAgeMs || entry.signingFingerprint.length !== 64 || entry.signingUpdateTime <= 0) return undefined;
    const identity = new InstalledSigningIdentity(); identity.versionCode = entry.version;
    identity.fingerprint = entry.signingFingerprint; identity.updateTime = entry.signingUpdateTime;
    identity.appIdentifier = entry.signingAppIdentifier; return identity;
  }

  /** 与 version() 同一份有效观察，用于跨页面比较新旧状态。 */
  static observedAt(bundleName: string): number {
    return InstalledAppRegistry.version(bundleName) >= 0 ?
      InstalledAppRegistry.savedVersions.get(bundleName)?.at ?? 0 : 0;
  }

  /** Stable estimation baseline, independent of unavailable signing metadata. */
  static installationTime(bundleName: string, versionCode: number): number {
    const entry = InstalledAppRegistry.savedVersions.get(bundleName);
    if (!entry || entry.version !== versionCode || versionCode <= 0 ||
      InstalledAppRegistry.version(bundleName) !== versionCode) return 0;
    return entry.installationUpdateTime || entry.firstSeenAt || entry.at;
  }

  /** 版本名仅属于被核对的那个构建，不能套用商店最新版本或旧安装历史。 */
  static versionName(bundleName: string, versionCode: number): string {
    const saved = InstalledAppRegistry.savedVersions.get(bundleName);
    return saved !== undefined && saved.version === versionCode &&
      InstalledAppRegistry.version(bundleName) === versionCode ? saved.versionName : '';
  }

  static displayName(bundleName: string): string {
    return InstalledAppRegistry.version(bundleName) > 0 ?
      InstalledAppRegistry.savedVersions.get(bundleName)?.displayName ?? '' : '';
  }

  /** 通过设备给出的资源标识读取分层/单层图标，不复制整份已安装 HAP。 */
  static iconResource(bundleName: string): Resource | undefined {
    const entry = InstalledAppRegistry.savedVersions.get(bundleName);
    if (InstalledAppRegistry.version(bundleName) <= 0 || entry === undefined || entry.iconId <= 0 ||
      !/^[A-Za-z][A-Za-z0-9_.]{0,255}$/.test(entry.iconModuleName)) return undefined;
    return { id: entry.iconId, type: 20000, params: [], bundleName: bundleName,
      moduleName: entry.iconModuleName };
  }

  static rememberDisplayName(bundleName: string, output: string): void {
    const entry = InstalledAppRegistry.savedVersions.get(bundleName);
    const label = output.trim();
    if (entry !== undefined && label.length > 0 && label.length <= 256 &&
      !/[\r\n]|\[Fail\]|error:|^\$string:/i.test(label)) entry.displayName = label;
  }

  /** -g 来自调试签名清单，不能用 applicationInfo.debug（编译模式）替代。 */
  static parseSideloadedNames(output: string): string[] | undefined {
    return InstalledAppRegistry.parseCompletedNames(output);
  }

  /** 原生 shell 仅在 bm 成功结束后写入标记；断连留下的完整行也不能证明卸载。 */
  private static parseCompletedNames(output: string): string[] | undefined {
    if (!output.endsWith('\n')) return undefined;
    const lines = output.trimEnd().split('\n');
    if (lines.pop()?.trim() !== '__QINGQI_BUNDLE_LIST_END__') return undefined;
    let header = false;
    const names = new Set<string>();
    for (const raw of lines) {
      const line = raw.trim();
      if (line.length === 0) continue;
      if (/^ID:\s*\d+:$/.test(line)) { header = true; continue; }
      // 系统元服务形如 com.atomicservice.6917587889453404644，数字段同样有效。
      if (!header || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(line)) return undefined;
      names.add(line);
    }
    return header ? Array.from(names) : undefined;
  }

  static rememberSideloadedNames(names: string[]): void {
    const present = new Set<string>(names);
    for (const name of InstalledAppRegistry.savedVersions.keys()) {
      InstalledAppRegistry.savedVersions.get(name)!.sideloaded = present.has(name);
    }
  }

  static sideloadedApps(): InstalledDeviceApp[] {
    const rows: InstalledDeviceApp[] = [];
    for (const name of InstalledAppRegistry.savedVersions.keys()) {
      const entry = InstalledAppRegistry.savedVersions.get(name)!;
      if (!entry.sideloaded || InstalledAppRegistry.version(name) <= 0) continue;
      const app = new InstalledDeviceApp();
      app.bundleName = name; app.displayName = entry.displayName || name;
      app.versionCode = entry.version; app.versionName = entry.versionName;
      const target = InstalledAppRegistry.launcher(name);
      app.moduleName = target?.moduleName ?? ''; app.abilityName = target?.abilityName ?? '';
      rows.push(app);
    }
    return rows;
  }

  /** -a 是存在性清单，不含版本；缺席才可以记为未安装。 */
  static parseNames(output: string): Map<string, number> | undefined {
    const names = InstalledAppRegistry.parseCompletedNames(output);
    if (names === undefined) return undefined;
    const found = new Map<string, number>();
    for (const name of names) found.set(name, 0);
    return found;
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

  /** The display scan consumes one validated dump instead of parsing it three times. */
  static observe(output: string, bundleName: string): number {
    const startedAt = Date.now();
    const start = output.indexOf('{');
    if (start < 0 || output.includes('[Fail]')) throw new Error('设备未返回应用版本信息');
    const row = JSON.parse(output.substring(start)) as Record<string, Object>;
    const version = Number(row['versionCode']);
    if (String(row['name'] ?? '') !== bundleName || !Number.isSafeInteger(version) || version <= 0) {
      throw new Error('设备返回的应用身份或版本无效');
    }
    InstalledAppRegistry.remember(bundleName, version);
    InstalledAppRegistry.rememberLauncherRow(row, bundleName);
    const elapsed = Date.now() - startedAt;
    if (elapsed > 8) console.info('InstalledApps observation: bytes=' + output.length + ' elapsedMs=' + elapsed);
    return version;
  }

  /** 返回 undefined 表示设备没给出可靠身份，仍由包管理器最终裁决。 */
  static parseSigningIdentity(output: string, bundleName: string): InstalledSigningIdentity | undefined {
    const start = output.indexOf('{');
    if (start < 0 || output.includes('[Fail]')) return undefined;
    try {
      const row = JSON.parse(output.substring(start)) as Record<string, Object>;
      return InstalledAppRegistry.signingIdentityFromRow(row, bundleName);
    } catch (_) {
      return undefined;
    }
  }
  private static signingIdentityFromRow(row: Record<string, Object>,
    bundleName: string): InstalledSigningIdentity | undefined {
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
    const updateTime = Number(row['updateTime'] ?? 0);
    identity.updateTime = Number.isSafeInteger(updateTime) && updateTime > 0 ? updateTime : 0;
    identity.fingerprint = fingerprint.length === 64 ? fingerprint : '';
    identity.appIdentifier = appIdentifier;
    return identity;
  }

}
