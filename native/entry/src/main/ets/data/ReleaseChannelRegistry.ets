import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CatalogApp } from './CatalogApp';
import { HapAsset, ReleaseInfo } from './ReleaseInfo';
import { ReleaseChannelPreference } from './ReleaseChannelPreference';
import { StoreClient } from './StoreClient';
import { CatalogPackageVariant } from './CatalogPackageVariant';
import { ReleaseUpdate } from '../jobs/ReleaseUpdate';

class ChannelTarget {
  appId: number = 0;
  preview: boolean = false;
  latestName: string = '';
  publishedAt:string='';
  assets: HapAsset[] = [];
  /** 稳定频道读取版本时对应的目录修订，旧详情不能覆盖更新后的目录。 */
  sourceUpdatedAt: string = '';
  sourceAssets: HapAsset[] = [];
}

/** 频道与最新可安装目标共用一份状态；安装任务本身不会随频道切换而改变。 */
export class ReleaseChannelRegistry {
  private static targets: Map<number, ChannelTarget> = new Map();
  private static sources: Map<number, CatalogApp> = new Map();
  private static applied: Map<number, CatalogApp> = new Map();
  private static restoring: Promise<void> | undefined = undefined;
  private static restored: boolean = false;
  private static saving: Promise<void> = Promise.resolve();
  private static flights: Map<number, Promise<void>> = new Map();
  private static fetchedAt: Map<number, number> = new Map();

  static async restore(context: common.UIAbilityContext): Promise<void> {
    if (ReleaseChannelRegistry.restored) return;
    if (ReleaseChannelRegistry.restoring !== undefined) return ReleaseChannelRegistry.restoring;
    ReleaseChannelRegistry.restoring = ReleaseChannelRegistry.readSaved(context).finally(() => {
      ReleaseChannelRegistry.restoring = undefined;
    });
    return ReleaseChannelRegistry.restoring;
  }

  private static async readSaved(context: common.UIAbilityContext): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, 'release-channels');
      const modes = await prefs.getAll() as Record<string, Object>;
      const store = await preferences.getPreferences(context, 'release-channel-targets');
      const raw = await store.get('targets', '') as string;
      let saved: Array<Record<string, Object>> = [];
      try {
        if (raw.length > 0 && raw.length <= 1024 * 1024) {
          const parsed = JSON.parse(raw) as Array<Record<string, Object>>;
          if (Array.isArray(parsed)) saved = parsed.filter((row: Record<string, Object>) => row !== null &&
            typeof row === 'object').slice(0, 500);
        }
      } catch (_) {}
      for (const key of Object.keys(modes)) {
        if (!/^app-[1-9][0-9]*$/.test(key) || modes[key] !== true) continue;
        const id = Number(key.substring(4));
        if (!Number.isSafeInteger(id)) continue;
        const target = new ChannelTarget(); target.appId = id; target.preview = true;
        const row = saved.find((item: Record<string, Object>) => Number(item['appId']) === id);
        if (row !== undefined && row['preview'] === true) {
          target.latestName = String(row['latestName'] ?? '').substring(0, 256);
          target.publishedAt=String(row['publishedAt']??'');
          const assets = row['assets'] as Array<Record<string, Object>> | undefined;
          if (Array.isArray(assets)) {
            target.assets = assets.filter((item: Record<string, Object>) => item !== null &&
              typeof item === 'object').slice(0, 50).map((item: Record<string, Object>) => {
              const asset = new HapAsset();
              asset.name = String(item['name'] ?? ''); asset.url = String(item['url'] ?? '');
              asset.sha256 = String(item['sha256'] ?? ''); asset.size = Number(item['size'] ?? 0);
              asset.bundleName = String(item['bundleName'] ?? '');
              asset.versionCode = Number(item['versionCode'] ?? 0);
              asset.versionName = String(item['versionName'] ?? '');
              asset.releaseName = String(item['releaseName'] ?? '');
              asset.releaseTag = String(item['releaseTag'] ?? '') || HapAsset.tagFromUrl(asset.url);
              asset.deviceTypes = HapAsset.normalizeDeviceTypes(item['deviceTypes']);
              const mirrors = item['mirrorUrls'] as string[] | undefined;
              asset.mirrorUrls = Array.isArray(mirrors) ? mirrors.filter((url: string) =>
                typeof url === 'string' && /^https:\/\//.test(url)) : [];
              return asset;
            }).filter((asset: HapAsset) => /\.(hap|app)$/i.test(asset.name) &&
              /^https:\/\//.test(asset.url) && Number.isSafeInteger(asset.versionCode) && asset.versionCode >= 0);
          }
        }
        ReleaseChannelRegistry.targets.set(id, target);
      }
      ReleaseChannelRegistry.restored = true;
      ReleaseChannelRegistry.notify();
    } catch (_) {
      // 保持已显示的目录，后续恢复可重试。
    }
  }

  static preview(appId: number): boolean {
    return ReleaseChannelRegistry.targets.get(appId)?.preview ?? false;
  }

  static async select(context: common.UIAbilityContext, appId: number, preview: boolean,
    releases: ReleaseInfo[], source?: CatalogApp): Promise<void> {
    await ReleaseChannelRegistry.restore(context);
    if (!Number.isSafeInteger(appId) || appId <= 0) return;
    const target = new ChannelTarget(); target.appId = appId; target.preview = preview;
    const sourceAt = Number(source?.updatedAt);
    target.sourceUpdatedAt = Number.isFinite(sourceAt) && sourceAt > 0 ? source?.updatedAt ?? '' : '';
    if (!preview && source !== undefined) target.sourceAssets = (source.latestAssets?.length ?? 0) > 0 ?
      source.latestAssets : source.latestAsset !== undefined ? [source.latestAsset] : [];
    const latest = releases.find((release: ReleaseInfo) => release.prerelease === preview &&
      release.assets.length > 0);
    target.latestName = latest?.name ?? ''; target.publishedAt=latest?.publishedAt??'';
    target.assets = ReleaseChannelRegistry.releaseAssets(releases, preview);
    ReleaseChannelRegistry.fetchedAt.set(appId, Date.now());
    if (JSON.stringify(ReleaseChannelRegistry.targets.get(appId)) === JSON.stringify(target)) return;
    ReleaseChannelRegistry.targets.set(appId, target);
    ReleaseChannelRegistry.notify();
    // 按提交顺序写入；慢的旧写入不能覆盖后一次选择。
    ReleaseChannelRegistry.saving = ReleaseChannelRegistry.saving.then(async () => {
      await ReleaseChannelPreference.save(context, appId, preview);
      try {
        const store = await preferences.getPreferences(context, 'release-channel-targets');
        await store.put('targets', JSON.stringify(Array.from(ReleaseChannelRegistry.targets.values())
          .filter((row: ChannelTarget) => row.preview).slice(0, 500)));
        await store.flush();
      } catch (_) { console.warn('Release channel targets could not be saved'); }
    });
    await ReleaseChannelRegistry.saving;
  }

  private static releaseAssets(releases: ReleaseInfo[], preview: boolean): HapAsset[] {
    // 子仓可以只更新其中一个包；保留每个 bundle 的最新发行及其所有包类型。
    let assets: HapAsset[] = [];
    const seen: string[] = [];
    for (const release of releases) {
      if (release.prerelease !== preview) continue;
      const added = release.assets.filter((asset: HapAsset) =>
        !seen.includes(asset.bundleName || asset.name));
      assets = assets.concat(added);
      for (const asset of added) seen.push(asset.bundleName || asset.name);
    }
    return assets;
  }

  /** 目录与版本列表各自有短缓存；包目标冲突时需要同时重读两端一次。 */
  static staleReleases(source: CatalogApp, releases: ReleaseInfo[], preview: boolean = false): boolean {
    const primary = source.latestAsset;
    if (preview || primary === undefined || !primary.bundleName ||
      !Number.isSafeInteger(primary.versionCode) || primary.versionCode <= 0) return false;
    const targets = ReleaseChannelRegistry.releaseAssets(releases, false);
    // 默认包可能来自已装 APP 的记录，不能只验证目录主 HAP。
    const sources = (source.latestAssets?.length ?? 0) > 0 ? source.latestAssets : [primary];
    for (const asset of sources) {
      if (!asset.bundleName || !Number.isSafeInteger(asset.versionCode) || asset.versionCode <= 0) continue;
      const candidates = targets.filter((target: HapAsset) => target.bundleName === asset.bundleName &&
        CatalogPackageVariant.key(target.name) === CatalogPackageVariant.key(asset.name));
      const variant = CatalogPackageVariant.choose(candidates, asset.name, asset);
      // 历史分页没有这个包时，不把缺少数据当作目录失效。
      if (variant === undefined) continue;
      if (variant.versionCode !== asset.versionCode) return true;
      if (asset.releaseTag && variant.releaseTag && asset.releaseTag !== variant.releaseTag) return true;
      const order = ReleaseUpdate.compare(ReleaseUpdate.version(asset), ReleaseUpdate.version(variant));
      if ((order !== undefined && order !== 0) || ReleaseChannelRegistry.digestConflict(asset, variant)) return true;
      if (ReleaseChannelRegistry.samePackage(asset, variant) &&
        ReleaseChannelRegistry.deviceTypesDiffer(asset, variant)) return true;
    }
    return false;
  }

  private static digestConflict(left: HapAsset, right: HapAsset): boolean {
    const a = left.sha256.toLowerCase(), b = right.sha256.toLowerCase();
    return /^[a-f0-9]{64}$/.test(a) && /^[a-f0-9]{64}$/.test(b) && a !== b;
  }

  private static sameRelease(left: HapAsset, right: HapAsset): boolean {
    if (left.versionCode !== right.versionCode || CatalogPackageVariant.key(left.name) !==
      CatalogPackageVariant.key(right.name)) return false;
    return (left.releaseTag.length > 0 && left.releaseTag === right.releaseTag) ||
      ReleaseUpdate.compare(ReleaseUpdate.version(left), ReleaseUpdate.version(right)) === 0;
  }

  /** Archive digests can be shared by several selected entries, so match the exact attachment too. */
  private static samePackage(left: HapAsset, right: HapAsset): boolean {
    const digest = left.sha256.toLowerCase();
    return /^[a-f0-9]{64}$/.test(digest) && digest === right.sha256.toLowerCase() &&
      left.bundleName.length > 0 && left.bundleName === right.bundleName &&
      Number.isSafeInteger(left.versionCode) && left.versionCode > 0 && left.versionCode === right.versionCode &&
      left.name.length > 0 && left.name === right.name && left.url.length > 0 && left.url === right.url &&
      (!left.releaseTag || !right.releaseTag || left.releaseTag === right.releaseTag);
  }

  private static deviceTypesDiffer(left: HapAsset, right: HapAsset): boolean {
    const a = HapAsset.normalizeDeviceTypes(left.deviceTypes).map((type: string) => type.toLowerCase()).sort();
    const b = HapAsset.normalizeDeviceTypes(right.deviceTypes).map((type: string) => type.toLowerCase()).sort();
    return JSON.stringify(a) !== JSON.stringify(b);
  }

  private static withDeviceTypes(asset: HapAsset, types: string[]): HapAsset {
    const copy = new HapAsset();
    copy.name = asset.name; copy.url = asset.url; copy.sha256 = asset.sha256; copy.size = asset.size;
    copy.bundleName = asset.bundleName; copy.versionCode = asset.versionCode; copy.versionName = asset.versionName;
    copy.releaseName = asset.releaseName; copy.releaseTag = asset.releaseTag;
    copy.mirrorUrls = asset.mirrorUrls;
    copy.deviceTypes = types;
    return copy;
  }

  private static notify(): void {
    ReleaseChannelRegistry.sources.clear(); ReleaseChannelRegistry.applied.clear();
    AppStorage.setOrCreate('releaseChannelRevision',
      (AppStorage.get<number>('releaseChannelRevision') ?? 0) + 1);
  }

  private static newer(left: HapAsset, right: HapAsset): boolean {
    if (left.versionCode !== right.versionCode) return left.versionCode > right.versionCode;
    return (ReleaseUpdate.compare(ReleaseUpdate.version(left), ReleaseUpdate.version(right)) ?? 0) > 0;
  }

  private static stableAssets(target: ChannelTarget, app: CatalogApp): HapAsset[] {
    const assets = target.assets.slice();
    // 来源目录提供该修订的完整包集合。缺少最近 20 条版本中的 helper 可以保留，
    // 但更旧的页面中已经下架的包不能借这次合并复活。
    const catalog = target.sourceAssets.slice();
    if (Number(app.updatedAt) === Number(target.sourceUpdatedAt)) {
      for (const asset of app.latestAssets) {
        if (target.sourceAssets.some((source: HapAsset) => source.bundleName === asset.bundleName &&
          CatalogPackageVariant.key(source.name) === CatalogPackageVariant.key(asset.name))) catalog.push(asset);
      }
    }
    for (const original of catalog) {
      const matching = assets.filter((asset: HapAsset) => asset.bundleName === original.bundleName);
      if (matching.length === 0) { assets.push(original); continue; }
      const variant = CatalogPackageVariant.choose(matching, original.name, original);
      const authoritativeReplacement = variant !== undefined && target.sourceAssets.includes(original) &&
        ReleaseChannelRegistry.sameRelease(original, variant) && ReleaseChannelRegistry.digestConflict(original, variant);
      if (variant !== undefined && (ReleaseChannelRegistry.newer(original, variant) || authoritativeReplacement)) {
        assets[assets.indexOf(variant)] = original;
      } else if (variant !== undefined && ReleaseChannelRegistry.samePackage(original, variant) &&
        HapAsset.normalizeDeviceTypes(variant.deviceTypes).length === 0 &&
        HapAsset.normalizeDeviceTypes(original.deviceTypes).length > 0) {
        // A metadata backfill need not change the catalog revision, tag or build number.
        assets[assets.indexOf(variant)] = ReleaseChannelRegistry.withDeviceTypes(variant,
          HapAsset.normalizeDeviceTypes(original.deviceTypes));
      } else if (variant === undefined && matching.every((asset: HapAsset) => ReleaseChannelRegistry.newer(original, asset))) {
        assets.push(original);
      }
    }
    return assets;
  }

  /** 使用选中频道的目标；空预览频道不能悄悄退回正式包。 */
  static apply(app: CatalogApp): CatalogApp {
    const target = ReleaseChannelRegistry.targets.get(app.id);
    if (target === undefined) return app;
    if (!target.preview) {
      // 稳定目标来自详情版本接口，只有知道它对应哪次目录读取才能投影。
      if (!target.sourceUpdatedAt) return app;
      const currentAt = Number(app.updatedAt), sourceAt = Number(target.sourceUpdatedAt);
      if (Number.isFinite(currentAt) && Number.isFinite(sourceAt) && currentAt > sourceAt) return app;
    }
    if (ReleaseChannelRegistry.sources.get(app.id) === app) return ReleaseChannelRegistry.applied.get(app.id)!;
    const copy = CatalogApp.copy(app);
    copy.previewChannel = target.preview;
    copy.knownAssets = target.preview ? app.latestAssets.concat(target.assets) : target.sourceAssets.concat(target.assets);
    const assets = target.preview ? target.assets : ReleaseChannelRegistry.stableAssets(target, app);
    copy.channelUnavailable = assets.length === 0;
    const matching = assets.filter((asset: HapAsset) => asset.bundleName === app.latestAsset?.bundleName);
    const preferred = CatalogPackageVariant.choose(matching, app.latestAsset?.name ?? '', app.latestAsset) ?? assets[0];
    copy.latestAsset = preferred;
    copy.latestAssets = assets;
    copy.latestName = target.latestName; copy.latestPublishedAt=target.publishedAt;
    ReleaseChannelRegistry.sources.set(app.id, app); ReleaseChannelRegistry.applied.set(app.id, copy);
    return copy;
  }

  /** 只为用户已选预览频道的应用读已有版本；合并重复请求，不触发仓库采集。 */
  static async refreshTargets(context: common.UIAbilityContext, apps: CatalogApp[], force: boolean = false): Promise<void> {
    await ReleaseChannelRegistry.restore(context);
    const ids = Array.from(new Set<number>(apps.filter((app: CatalogApp) =>
      ReleaseChannelRegistry.preview(app.id)).map((app: CatalogApp) => app.id)));
    const client = new StoreClient(context);
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < ids.length) {
        const id = ids[cursor++];
        const existing = ReleaseChannelRegistry.flights.get(id);
        if (existing !== undefined) { await existing; continue; }
        if (!ReleaseChannelRegistry.preview(id) ||
          (!force && Date.now() - (ReleaseChannelRegistry.fetchedAt.get(id) ?? 0) < 60000)) continue;
        const selected = ReleaseChannelRegistry.targets.get(id);
        const flight = client.listReleases(id, 1, 20, true, force).then(async (page) => {
          if (ReleaseChannelRegistry.targets.get(id) !== selected) return;
          await ReleaseChannelRegistry.select(context, id, true, page.items,
            apps.find((app: CatalogApp) => app.id === id));
        }).catch(() => {
          // 网络失败保留已选频道和目标，不能混用正式版本。
        }).finally(() => ReleaseChannelRegistry.flights.delete(id));
        ReleaseChannelRegistry.flights.set(id, flight);
        await flight;
      }
    };
    // 两路网络读取，避免串行超时累加；完成信号仍覆盖所有预览目标。
    await Promise.all([worker(), worker()]);
  }
}
