const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const sort = loadEts('data/DiscoverSort');
const exported = loadEts('data/CatalogPaging', { './DiscoverSort': sort });
const { appendCatalogPage, filterCatalogCategory, shouldPrefetchCatalog } = exported;
const ids = rows => Array.from(rows, row => row.id);

test('pagination preserves the server ordering and does not duplicate moving boundaries', () => {
  const first = appendCatalogPage([], [
    { id: 1, stars: 5 }, { id: 2, stars: 200 }, { id: 3, stars: 150 }
  ]);
  assert.deepEqual(ids(first), [1, 2, 3]);
  const second = appendCatalogPage(first, [
    { id: 1, stars: 5 }, { id: 4, stars: 100 }, { id: 5, stars: 10000 }, { id: 5, stars: 10000 }
  ]);
  assert.deepEqual(ids(second), [1, 2, 3, 4, 5]);
  assert.deepEqual(ids(first), [1, 2, 3]);
  assert.equal(second[0], first[0]);
});

test('prefetch starts before the page boundary and cannot loop on busy, empty, failed or final pages', () => {
  assert.equal(shouldPrefetchCatalog(30, 90, 1, 30, 23, false, false), false);
  assert.equal(shouldPrefetchCatalog(30, 90, 1, 30, 24, false, false), true);
  assert.equal(shouldPrefetchCatalog(30, 90, 1, 30, 30, true, false), false);
  assert.equal(shouldPrefetchCatalog(30, 90, 1, 30, 30, false, true), false);
  assert.equal(shouldPrefetchCatalog(30, 30, 1, 30, 30, false, false), false);
  assert.equal(shouldPrefetchCatalog(29, 60, 2, 30, 60, false, false), false);
  assert.equal(shouldPrefetchCatalog(0, 90, 0, 30, 0, false, false), false);
});

test('complete category filtering ranks all high-star apps first and then follows server update time and id ordering', () => {
  const rows = [
    { id: 1, category: '工具', stars: 5, updatedAt: '2026-10-07T10:00:00Z' },
    { id: 2, category: '工具', stars: 100, updatedAt: '2026-10-07T12:00:00Z' },
    { id: 3, category: '工具', stars: 300, updatedAt: '2026-10-06T00:00:00Z' },
    { id: 4, category: '影音', stars: 2000, updatedAt: '2026-10-07T00:00:00Z' },
    { id: 5, category: '工具', stars: 300, updatedAt: '2026-10-07T00:00:00Z' },
    { id: 6, category: '工具', stars: 3, updatedAt: '2026-10-07T12:00:00Z' }
  ];
  assert.deepEqual(ids(filterCatalogCategory(rows, '工具')), [5, 3, 6, 2, 1]);
  assert.deepEqual(ids(rows), [1, 2, 3, 4, 5, 6]);
});
