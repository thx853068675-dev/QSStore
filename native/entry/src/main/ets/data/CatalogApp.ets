import { HapAsset } from './ReleaseInfo';

export class CatalogApp {
  id: number = 0;
  displayName: string = '';
  repo: string = '';
  secondaryRepo: string = '';
  summary: string = '';
  category: string = '';
  publisherName: string = '';
  stars: number = 0;
  /** -1: not collected; GitHub Release attachment downloads, not store installs. */
  githubDownloads: number = -1;
  iconUrl: string = '';
  iconRev: string = '';
  latestName: string = '';
  /** 服务端 /apps/{id} 返回的 rating: {count, average}。列表接口没有这个字段。 */
  ratingAverage: number = 0;
  ratingCount: number = 0;
  /** Primary package for Discover; all packages are available for Management matching. */
  latestAsset: HapAsset | undefined = undefined;
  latestAssets: HapAsset[] = [];

  /** 仅用于本机选中的版本频道，不写入服务端目录缓存。 */
  previewChannel: boolean = false;
  channelUnavailable: boolean = false;
  knownAssets: HapAsset[] = [];

  static copy(app: CatalogApp): CatalogApp {
    const copy = new CatalogApp();
    copy.id = app.id; copy.displayName = app.displayName; copy.repo = app.repo;
    copy.secondaryRepo = app.secondaryRepo;
    copy.summary = app.summary; copy.category = app.category; copy.publisherName = app.publisherName;
    copy.stars = app.stars; copy.iconUrl = app.iconUrl; copy.iconRev = app.iconRev;
    copy.githubDownloads = app.githubDownloads;
    copy.latestName = app.latestName; copy.latestAsset = app.latestAsset; copy.latestAssets = app.latestAssets;
    copy.ratingAverage = app.ratingAverage; copy.ratingCount = app.ratingCount;
    return copy;
  }

  static fromJson(row: Record<string, Object>): CatalogApp {
    const app = new CatalogApp();
    app.id = Number(row['id'] ?? 0);
    app.displayName = String(row['display_name'] ?? row['name'] ?? '');
    app.repo = String(row['repo'] ?? '');
    app.secondaryRepo = String(row['secondary_repo'] ?? '');
    app.summary = String(row['summary'] ?? '');
    app.category = String(row['category'] ?? '');
    app.publisherName = String(row['publisher_name'] ?? '');
    app.stars = Number(row['stars'] ?? 0);
    const downloads = Number(row['github_downloads'] ?? -1);
    app.githubDownloads = Number.isFinite(downloads) && downloads >= 0 ? Math.floor(downloads) : -1;
    app.iconUrl = String(row['icon_url'] ?? '');
    app.iconRev = String(row['icon_rev'] ?? '');
    const latest = row['latest'] as Record<string, Object> | undefined;
    app.latestName = latest ? String(latest['name'] ?? '') : '';
    const rating = row['rating'] as Record<string, Object> | undefined;
    app.ratingAverage = rating ? Number(rating['average'] ?? 0) : 0;
    app.ratingCount = rating ? Number(rating['count'] ?? 0) : 0;
    const asset = row['latest_asset'] as Record<string, Object> | undefined;
    app.latestAsset = asset ? HapAsset.fromJson(asset) : undefined;
    const assets = row['latest_assets'] as Record<string, Object>[] | undefined;
    app.latestAssets = assets ? assets.map((item: Record<string, Object>) => HapAsset.fromJson(item)) :
      (app.latestAsset !== undefined ? [app.latestAsset] : []);
    return app;
  }
}
