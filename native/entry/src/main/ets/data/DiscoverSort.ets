import { CatalogApp } from './CatalogApp';

export type DiscoverSortKey = 'discover' | 'stars' | 'downloads' | 'new';
export type SortDirection = 'asc' | 'desc';

export class DiscoverSort {
  static key(value: string): DiscoverSortKey {
    return value === 'stars' || value === 'downloads' || value === 'new' ? value : 'discover';
  }
  static direction(value: string): SortDirection { return value === 'asc' ? 'asc' : 'desc'; }
  static label(key: string): string {
    return key === 'stars' ? '星数' : key === 'downloads' ? '下载' : key === 'new' ? '上架' : '推荐';
  }
  static cacheKey(key: string, direction: string): string {
    return DiscoverSort.key(key) + '-' + DiscoverSort.direction(direction);
  }
  private static updated(app: CatalogApp): number {
    const number = Number(app.updatedAt || 0);
    if (Number.isFinite(number)) return number;
    const date = Date.parse(app.updatedAt);
    return Number.isFinite(date) ? date / 1000 : 0;
  }
  /** Same total order as the server, only used with a verified complete catalog. */
  static compare(a: CatalogApp, b: CatalogApp, key: string, direction: string): number {
    const sign = direction === 'asc' ? 1 : -1;
    if (key === 'downloads') {
      const unknown = Number(a.githubDownloads < 0) - Number(b.githubDownloads < 0);
      if (unknown !== 0) return unknown;
      return sign * (a.githubDownloads - b.githubDownloads || a.id - b.id);
    }
    if (key === 'stars') return sign * (a.stars - b.stars || a.id - b.id);
    if (key === 'new') return sign * (a.createdAt - b.createdAt || a.id - b.id);
    return sign * (Number(a.stars > 100) - Number(b.stars > 100) ||
      (a.stars > 100 && b.stars > 100 ? a.stars - b.stars : 0) ||
      DiscoverSort.updated(a) - DiscoverSort.updated(b) || a.id - b.id);
  }
}
