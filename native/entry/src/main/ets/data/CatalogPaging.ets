import { CatalogApp } from './CatalogApp';

/** Rank a new page without moving any card the user has already scrolled past. */
export function appendCatalogPage(previous: CatalogApp[], incoming: CatalogApp[]): CatalogApp[] {
  const known = new Set<number>(previous.map((app: CatalogApp) => app.id));
  const fresh = incoming.filter((app: CatalogApp) => {
    if (known.has(app.id)) return false;
    known.add(app.id);
    return true;
  });
  const featured = fresh.filter((app: CatalogApp) => app.stars > 100)
    .sort((a: CatalogApp, b: CatalogApp) => b.stars - a.stars || a.id - b.id);
  return previous.concat(featured, fresh.filter((app: CatalogApp) => app.stars <= 100));
}

/** The list includes a heading and footer; starting a little early is intentional. */
export function shouldPrefetchCatalog(loaded: number, total: number, page: number,
  pageSize: number, lastVisible: number, busy: boolean, retryBlocked: boolean): boolean {
  return !busy && !retryBlocked && page > 0 && loaded > 0 && page * pageSize < total &&
    lastVisible >= Math.max(0, loaded - 6);
}
