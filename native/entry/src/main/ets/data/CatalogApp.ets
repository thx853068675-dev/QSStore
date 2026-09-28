export class CatalogApp {
  id: number = 0;
  displayName: string = '';
  repo: string = '';
  summary: string = '';
  category: string = '';
  publisherName: string = '';
  stars: number = 0;
  iconUrl: string = '';
  latestName: string = '';
  /** 服务端 /apps/{id} 返回的 rating: {count, average}。列表接口没有这个字段。 */
  ratingAverage: number = 0;
  ratingCount: number = 0;

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
    const latest = row['latest'] as Record<string, Object> | undefined;
    app.latestName = latest ? String(latest['name'] ?? '') : '';
    const rating = row['rating'] as Record<string, Object> | undefined;
    app.ratingAverage = rating ? Number(rating['average'] ?? 0) : 0;
    app.ratingCount = rating ? Number(rating['count'] ?? 0) : 0;
    return app;
  }
}
