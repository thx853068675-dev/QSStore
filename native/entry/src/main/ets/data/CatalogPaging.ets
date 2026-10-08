import { CatalogApp } from './CatalogApp';
import { DiscoverSort } from './DiscoverSort';

/** Filter and order only a verified complete catalog. */
export function filterCatalogCategory(catalog: CatalogApp[], category: string,
  sort: string = 'discover', direction: string = 'desc'): CatalogApp[] {
  return catalog.filter((app: CatalogApp) => app.category.trim() === category.trim())
    .sort((a: CatalogApp, b: CatalogApp) => DiscoverSort.compare(a, b, sort, direction));
}

/** Append the server-ordered page without moving cards already displayed. */
export function appendCatalogPage(previous: CatalogApp[], incoming: CatalogApp[]): CatalogApp[] {
  const known = new Set<number>(previous.map((app: CatalogApp) => app.id));
  const fresh = incoming.filter((app: CatalogApp) => {
    if (known.has(app.id)) return false;
    known.add(app.id);
    return true;
  });
  // Preserve the server's order for every sort mode; only deduplicate appended IDs.
  return previous.concat(fresh);
}

/** The list includes a heading and footer; starting a little early is intentional. */
export function shouldPrefetchCatalog(loaded: number, total: number, page: number,
  pageSize: number, lastVisible: number, busy: boolean, retryBlocked: boolean): boolean {
  return !busy && !retryBlocked && page > 0 && loaded > 0 && page * pageSize < total &&
    lastVisible >= Math.max(0, loaded - 6);
}
