const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const sort = loadEts('data/DiscoverSort');
const paging = loadEts('data/CatalogPaging', { './DiscoverSort': sort });

function preferences(disk = new Map()) {
  let fail = false;
  const kit = { preferences: { getPreferences: async () => {
    if (fail) throw Error('disk unavailable');
    return { get: async (key, fallback) => disk.get(key) ?? fallback,
      put: async (key, value) => disk.set(key, value),
      delete: async key => disk.delete(key), getAll: async () => Object.fromEntries(disk),
      flush: async () => {} };
  } } };
  const { DiscoverSortPreferences: service } = loadEts('data/DiscoverSortPreferences', {
    './DiscoverSort': sort, '@kit.ArkData': kit
  });
  return { service, kit, disk, fail: value => { fail = value; } };
}

test('each direction and selected mode survive restart; rapid writes keep the final choice', async () => {
  const f = preferences(); await f.service.load({});
  assert.equal(f.service.current().key, 'discover');
  await Promise.all([f.service.save({}, 'stars', 'asc'), f.service.save({}, 'new', 'desc'),
    f.service.save({}, 'downloads', 'asc')]);
  const restarted = preferences(f.disk); await restarted.service.load({});
  assert.equal(restarted.service.current().key, 'downloads');
  assert.equal(restarted.service.current().direction, 'asc');
  assert.equal(restarted.service.directionFor('stars'), 'asc');
  assert.equal(restarted.service.directionFor('new'), 'desc');
  assert.equal(restarted.service.directionFor('discover'), 'desc');
});

test('bad saved values are normalized and a failed write does not block later saves', async () => {
  const f = preferences(new Map([['selected', 'oops'], ['stars', 'DROP TABLE']]));
  await f.service.load({}); assert.equal(f.service.current().key, 'discover');
  assert.equal(f.service.directionFor('stars'), 'desc');
  f.fail(true); await assert.rejects(f.service.save({}, 'new', 'asc'));
  f.fail(false); await f.service.save({}, 'new', 'desc');
  const restarted = preferences(f.disk); await restarted.service.load({});
  assert.equal(restarted.service.current().direction, 'desc');
});

test('full category sort uses created_at, numeric update timestamps and unknown-last download counts', () => {
  const rows = [
    { id: 1, category: '工具', stars: 100, githubDownloads: 40, createdAt: 30, updatedAt: '500' },
    { id: 2, category: '工具', stars: 120, githubDownloads: 20, createdAt: 20, updatedAt: '10' },
    { id: 3, category: '工具', stars: 120, githubDownloads: 20, createdAt: 20, updatedAt: '10' },
    { id: 4, category: '工具', stars: 1000, githubDownloads: 0, createdAt: 10, updatedAt: '1' },
    { id: 5, category: '工具', stars: 0, githubDownloads: -1, createdAt: 1, updatedAt: '1' },
    { id: 6, category: '影音', stars: 9999, githubDownloads: 9999, createdAt: 999, updatedAt: '999' }
  ];
  for (const [key, expected] of [['discover',[4,3,2,1,5]], ['stars',[4,3,2,1,5]], ['new',[1,3,2,4,5]], ['downloads',[1,3,2,4,5]]]) {
    const result = paging.filterCatalogCategory(rows, '工具', key, 'desc');
    assert.deepEqual(Array.from(result, row => row.id), expected);
    const reverse = paging.filterCatalogCategory(rows, '工具', key, 'asc');
    assert.deepEqual(Array.from(reverse, row => row.id), key === 'downloads' ? [4,2,3,1,5] : [...expected].reverse());
  }
  assert.deepEqual(rows.map(row => row.id), [1,2,3,4,5,6], 'never mutate the shared Management catalog');
});

test('first-page caches are isolated by mode/direction and empty results replace stale rows', async () => {
  const f = preferences(new Map([['catalog', JSON.stringify([{id:99}])]]));
  const { CatalogCache } = loadEts('data/CatalogCache', {
    './DiscoverSort': sort, '@kit.ArkData': f.kit,
    '@kit.ArkTS': { util: { TextEncoder } }, './CatalogApp': { CatalogApp: { fromJson: row => row } }
  });
  assert.deepEqual(Array.from(await CatalogCache.load({}), row => row.id), [99]);
  assert.equal((await CatalogCache.load({}, 'downloads', 'asc')).length, 0);
  await CatalogCache.save({}, [], [{id:1}], 'stars', 'desc');
  await CatalogCache.save({}, [], [{id:2}], 'stars', 'asc');
  assert.deepEqual(Array.from(await CatalogCache.load({}, 'stars', 'desc'), row => row.id), [1]);
  assert.deepEqual(Array.from(await CatalogCache.load({}, 'stars', 'asc'), row => row.id), [2]);
  await CatalogCache.save({}, [], [], 'stars', 'asc');
  assert.equal((await CatalogCache.load({}, 'stars', 'asc')).length, 0);
  assert.equal((await CatalogCache.load({}, 'stars', 'desc')).length, 1);
});
