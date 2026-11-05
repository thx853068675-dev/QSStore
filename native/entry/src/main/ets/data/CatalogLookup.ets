import { CatalogApp } from './CatalogApp';
import { HapAsset } from './ReleaseInfo';

/** One projection per catalog/channel revision, shared by every visible card. */
export class CatalogLookup {
  readonly rows: CatalogApp[];
  private primary: CatalogApp[];
  private visible: CatalogApp[];
  private complete: boolean;
  private revision: number;
  private byId: Map<number, CatalogApp> = new Map();
  private primaryById: Map<number, CatalogApp> = new Map();
  private byBundle: Map<string, CatalogApp[]> = new Map();

  constructor(primary: CatalogApp[], visible: CatalogApp[], complete: boolean, revision: number,
    project: (app: CatalogApp) => CatalogApp) {
    this.primary = primary; this.visible = visible; this.complete = complete; this.revision = revision;
    const sources = new Map<number, CatalogApp>();
    for (const app of primary) sources.set(app.id, app);
    for (const app of visible) {
      const original = sources.get(app.id);
      if (original === undefined) {
        if (!complete) sources.set(app.id, app);
        continue;
      }
      const at = Number(app.updatedAt), previousAt = Number(original.updatedAt);
      const newer = (Number.isFinite(at) && at > (Number.isFinite(previousAt) ? previousAt : 0)) ||
        ((!Number.isFinite(at) || !Number.isFinite(previousAt) || at === previousAt) &&
          (app.latestAsset?.versionCode ?? 0) > (original.latestAsset?.versionCode ?? 0));
      // The selected row still owns the catalog/package set. A matching digest
      // may only supply a missing declaration; it cannot revive another asset.
      sources.set(app.id, CatalogLookup.enrichDeviceMetadata(newer ? app : original, newer ? original : app));
    }
    this.rows = Array.from(sources.values()).map(project);
    for (const app of this.rows) {
      this.byId.set(app.id, app);
      this.primaryById.set(app.id, app);
      const bundles = new Set<string>();
      for (const asset of CatalogLookup.assets(app)) {
        if (!asset.bundleName || bundles.has(asset.bundleName)) continue;
        bundles.add(asset.bundleName);
        const matches = this.byBundle.get(asset.bundleName) ?? [];
        matches.push(app); this.byBundle.set(asset.bundleName, matches);
      }
    }
  }

  matches(primary: CatalogApp[], visible: CatalogApp[], complete: boolean, revision: number): boolean {
    return this.primary === primary && this.visible === visible && this.complete === complete && this.revision === revision;
  }

  app(id: number): CatalogApp | undefined { return this.byId.get(id); }

  source(appId: number, bundleName: string): CatalogApp | undefined {
    if (!bundleName) return undefined;
    const matches = this.byBundle.get(bundleName) ?? [];
    if (appId > 0) {
      const exact = matches.find((app: CatalogApp) => app.id === appId);
      if (exact !== undefined) return exact;
      // An existing online source remains online while its metadata is pending.
      const original = this.primaryById.get(appId);
      return original !== undefined && CatalogLookup.assets(original).every(
        (asset: HapAsset) => asset.bundleName.length === 0) ? original : undefined;
    }
    return this.complete && matches.length === 1 ? matches[0] : undefined;
  }

  private static assets(app: CatalogApp): HapAsset[] {
    return app.knownAssets !== undefined && app.knownAssets.length > 0 ? app.knownAssets :
      app.latestAssets !== undefined && app.latestAssets.length > 0 ? app.latestAssets :
        app.latestAsset !== undefined ? [app.latestAsset] : [];
  }

  /** Metadata can be backfilled without changing the package or catalog timestamp. */
  private static enrichDeviceMetadata(previous: CatalogApp, fresh: CatalogApp): CatalogApp {
    if (previous === fresh) return previous;
    const newAssets = (fresh.latestAssets ?? []).concat(fresh.latestAsset !== undefined ? [fresh.latestAsset] : []);
    if (!newAssets.length) return previous;
    const same = (left: HapAsset, right: HapAsset): boolean =>
      (left.name ?? '').length > 0 && (left.url ?? '').length > 0 && (left.bundleName ?? '').length > 0 &&
      Number.isSafeInteger(left.versionCode) && left.versionCode > 0 &&
      /^[a-f0-9]{64}$/i.test(left.sha256 ?? '') && left.sha256.toLowerCase() === right.sha256?.toLowerCase() &&
      left.bundleName === right.bundleName && left.versionCode === right.versionCode &&
      left.name === right.name && left.url === right.url;
    let changed = false;
    const upgrade = (asset: HapAsset): HapAsset => {
      if (HapAsset.normalizeDeviceTypes(asset.deviceTypes).length > 0) return asset;
      const matching = newAssets.find((candidate: HapAsset) => same(asset, candidate) &&
        HapAsset.normalizeDeviceTypes(candidate.deviceTypes).length > 0);
      if (matching === undefined) return asset;
      changed = true;
      return HapAsset.copyWithDeviceTypes(asset, matching.deviceTypes);
    };
    const latest = previous.latestAsset !== undefined ? upgrade(previous.latestAsset) : undefined;
    const assets = (previous.latestAssets ?? []).map(upgrade);
    const known = (previous.knownAssets ?? []).map(upgrade);
    if (!changed) return previous;
    const copy = CatalogApp.copy(previous);
    copy.latestAsset = latest; copy.latestAssets = assets; copy.knownAssets = known;
    copy.previewChannel = previous.previewChannel; copy.channelUnavailable = previous.channelUnavailable;
    return copy;
  }
}
