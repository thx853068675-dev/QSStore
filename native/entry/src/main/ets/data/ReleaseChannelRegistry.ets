import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CatalogApp } from './CatalogApp';
import { HapAsset, ReleaseInfo } from './ReleaseInfo';
import { ReleaseChannelPreference } from './ReleaseChannelPreference';
import { StoreClient } from './StoreClient';

class ChannelTarget {
  appId: number = 0;
  preview: boolean = false;
  latestName: string = '';
  assets: HapAsset[] = [];
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
    releases: ReleaseInfo[]): Promise<void> {
    await ReleaseChannelRegistry.restore(context);
    if (!Number.isSafeInteger(appId) || appId <= 0) return;
    const target = new ChannelTarget(); target.appId = appId; target.preview = preview;
    const latest = releases.find((release: ReleaseInfo) => release.prerelease === preview &&
      release.assets.length > 0);
    target.latestName = latest?.name ?? '';
    target.assets = latest?.assets ?? [];
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

  private static notify(): void {
    ReleaseChannelRegistry.sources.clear(); ReleaseChannelRegistry.applied.clear();
    AppStorage.setOrCreate('releaseChannelRevision',
      (AppStorage.get<number>('releaseChannelRevision') ?? 0) + 1);
  }

  /** 使用选中频道的目标；空预览频道不能悄悄退回正式包。 */
  static apply(app: CatalogApp): CatalogApp {
    const target = ReleaseChannelRegistry.targets.get(app.id);
    if (target === undefined || !target.preview) return app;
    if (ReleaseChannelRegistry.sources.get(app.id) === app) return ReleaseChannelRegistry.applied.get(app.id)!;
    const copy = CatalogApp.copy(app);
    copy.previewChannel = true; copy.channelUnavailable = target.assets.length === 0;
    copy.knownAssets = app.latestAssets.concat(target.assets);
    const preferred = target.assets.find((asset: HapAsset) =>
      asset.bundleName === app.latestAsset?.bundleName && asset.name === app.latestAsset?.name) ??
      target.assets.find((asset: HapAsset) => asset.bundleName === app.latestAsset?.bundleName) ?? target.assets[0];
    copy.latestAsset = preferred; copy.latestAssets = target.assets; copy.latestName = target.latestName;
    ReleaseChannelRegistry.sources.set(app.id, app); ReleaseChannelRegistry.applied.set(app.id, copy);
    return copy;
  }

  /** 只为用户已选预览频道的应用读已有版本；合并重复请求，不触发仓库采集。 */
  static async refreshTargets(context: common.UIAbilityContext, apps: CatalogApp[], force: boolean = false): Promise<void> {
    await ReleaseChannelRegistry.restore(context);
    const ids = apps.filter((app: CatalogApp) => ReleaseChannelRegistry.preview(app.id)).map((app: CatalogApp) => app.id);
    const client = new StoreClient(context);
    for (const id of ids) {
      const existing = ReleaseChannelRegistry.flights.get(id);
      if (existing !== undefined) { await existing; continue; }
      if (!force && Date.now() - (ReleaseChannelRegistry.fetchedAt.get(id) ?? 0) < 60000) continue;
      const selected = ReleaseChannelRegistry.targets.get(id);
      const flight = client.listReleases(id, 1, 20, true).then(async (page) => {
        if (ReleaseChannelRegistry.targets.get(id) !== selected) return;
        await ReleaseChannelRegistry.select(context, id, true, page.items);
      }).catch(() => {
        // 网络失败保留已选频道和目标，不能混用正式版本。
      }).finally(() => ReleaseChannelRegistry.flights.delete(id));
      ReleaseChannelRegistry.flights.set(id, flight);
      await flight;
    }
  }
}
