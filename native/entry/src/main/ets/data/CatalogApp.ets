import { HapAsset } from './ReleaseInfo';

export class CatalogApp {
  id: number = 0;
  displayName: string = '';
  repo: string = '';
  summary: string = '';
  category: string = '';
  publisherName: string = '';
  stars: number = 0;
  iconUrl: string = '';
  iconRev: string = '';
  latestName: string = '';
  /** 服务端 /apps/{id} 返回的 rating: {count, average}。列表接口没有这个字段。 */
  ratingAverage: number = 0;
  ratingCount: number = 0;
  /**
   * 最新版本里最大的那个 HAP，服务端在列表接口里一并给出。
   *
   * 卡片要显示「安装 / 打开」、更新检查要比版本号，都需要 bundleName 与
   * versionCode，而这两个字段只有 releases 里才有。没有它时客户端得为目录里
   * 每个应用单独请求一次 releases，一屏 30 个应用就是 30 次来回。
   */
  latestAsset: HapAsset | undefined = undefined;

  static fromJson(row: Record<string, Object>): CatalogApp {
    const app = new CatalogApp();
    app.id = Number(row['id'] ?? 0);
    app.displayName = String(row['display_name'] ?? row['name'] ?? '');
    app.repo = String(row['repo'] ?? '');
    app.summary = String(row['summary'] ?? '');
    app.category = String(row['category'] ?? '');
    app.publisherName = String(row['publisher_name'] ?? '');
    app.stars = Number(row['stars'] ?? 0);
    app.iconUrl = String(row['icon_url'] ?? '');
    app.iconRev = String(row['icon_rev'] ?? '');
    const latest = row['latest'] as Record<string, Object> | undefined;
    app.latestName = latest ? String(latest['name'] ?? '') : '';
    const rating = row['rating'] as Record<string, Object> | undefined;
    app.ratingAverage = rating ? Number(rating['average'] ?? 0) : 0;
    app.ratingCount = rating ? Number(rating['count'] ?? 0) : 0;
    const asset = row['latest_asset'] as Record<string, Object> | undefined;
    app.latestAsset = asset ? HapAsset.fromJson(asset) : undefined;
    return app;
  }
}
