import { CatalogApp } from './CatalogApp';
import { I18n } from './I18n';

export type DiscoverSortKey = 'stars' | 'downloads' | 'new';
export type SortDirection = 'asc' | 'desc';

export class DiscoverSort {
  static key(value: string): DiscoverSortKey {
    return value === 'downloads' || value === 'new' ? value : 'stars';
  }
  static direction(value: string): SortDirection { return value === 'asc' ? 'asc' : 'desc'; }
  static label(key: string): string {
    return I18n.sortLabel(key);
  }
  static cacheKey(key: string, direction: string): string {
    return DiscoverSort.key(key) + '-' + DiscoverSort.direction(direction);
  }
  /** Same total order as the server, only used with a verified complete catalog. */
  static compare(a: CatalogApp, b: CatalogApp, key: string, direction: string): number {
    const sign = direction === 'asc' ? 1 : -1;
    if (key === 'downloads') {
      const unknown = Number(a.githubDownloads < 0) - Number(b.githubDownloads < 0);
      if (unknown !== 0) return unknown;
      return sign * (a.githubDownloads - b.githubDownloads || a.id - b.id);
    }
    if (key === 'new') return sign * (a.createdAt - b.createdAt || a.id - b.id);
    return sign * (a.stars - b.stars || a.id - b.id);
  }
}
