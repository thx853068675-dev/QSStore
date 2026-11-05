// Run: node --test native/tests/test_catalog_icon_cache.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const file = path.join(__dirname, '../entry/src/main/ets/data/CatalogCache.ets');
const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture(hooks = {}) {
  const values = new Map();
  const prefs = {
    async getAll() { return Object.fromEntries(values); },
    async get(key, fallback) { return values.get(key) ?? fallback; },
    async put(key, value) { if (hooks.put) await hooks.put(key, value); values.set(key, value); },
    async delete(key) { values.delete(key); },
    async flush() {},
    async clear() { if (hooks.clear) await hooks.clear(); values.clear(); }
  };
  const exports = {};
  vm.runInNewContext(code, {
    exports,
    require: name => name === '@kit.ArkData' ?
      { preferences: { getPreferences: async () => { if (hooks.store) await hooks.store(); return prefs; } } } :
      name === './DiscoverSort' ? { DiscoverSort: { cacheKey: (sort, direction) => sort + '-' + direction } } :
      name === '@kit.ArkTS' ?
        { util: { TextEncoder: class { encodeInto(input) { return Buffer.from(input); } }, Base64Helper: class {
          decodeSync(input) { return Uint8Array.from(Buffer.from(input, 'base64')); }
        } } } : {}
  });
  return { values, cache: exports.CatalogCache, CachedIcon: exports.CachedIcon };
}

test('cache size includes icon bytes and Chinese catalog text; clearing leaves no cached payload', async () => {
  const f = fixture();
  const icon = JSON.stringify({ id: '1', rev: 'v1', data: Buffer.from('image').toString('base64') });
  const catalog = JSON.stringify([{ id: 1, display_name: '轻启' }]);
  f.values.set('icon-1', icon); f.values.set('catalog', catalog); f.values.set('other', 'ignored');
  assert.equal(await f.cache.size({}), Buffer.byteLength(icon) + Buffer.byteLength(catalog));
  await f.cache.clear({}); assert.equal(await f.cache.size({}), 0);
  assert.equal((await f.cache.loadIcons({}, [{ id: 1, iconRev: 'v1' }])).size, 0);
});

function deferred() { let resolve; const promise = new Promise(done => resolve = done); return { resolve, promise }; }
const tick = () => new Promise(resolve => setImmediate(resolve));
const icon = (id, rev = 'one') => ({ id: String(id), rev, data: Buffer.from('image-' + id).toString('base64') });

test('clear invalidates immediately and serializes old active, queued and fresh cache writes', async () => {
  const gate = deferred(); let blocked = true;
  const f = fixture({ put: async () => { if (blocked) { blocked = false; await gate.promise; } } });
  const oldGeneration = f.cache.generation();
  const active = f.cache.saveIcons({}, [icon(1)]); await tick();
  const queued = f.cache.saveIcons({}, [icon(2)], oldGeneration);
  const clearing = f.cache.clear({});
  assert.equal(f.cache.generation(), oldGeneration + 1, 'invalidates before the active writer finishes');
  const lateOld = f.cache.save({}, [], [{ id: 99 }], 'stars', 'desc', oldGeneration);
  const fresh = f.cache.saveIcons({}, [icon(3)]);
  gate.resolve(); await Promise.all([active, queued, clearing, lateOld, fresh]);
  assert.deepEqual(Array.from(f.values.keys()), ['icon-3']);
});

test('a stale writer waiting for Preferences acquisition is discarded before its first put', async () => {
  const gate = deferred(); let waiting = true, writes = 0;
  const f = fixture({ store: async () => { if (waiting) { waiting = false; await gate.promise; } },
    put: async () => writes++ });
  const writing = f.cache.saveIcons({}, [icon(1)]); await tick();
  const clearing = f.cache.clear({});
  gate.resolve(); await Promise.all([writing, clearing]);
  assert.equal(writes, 0); assert.equal(f.values.size, 0);
});

test('both catalog and icons reject late old results, while new calls retain backward-compatible caching', async () => {
  const f = fixture(), before = f.cache.generation();
  await f.cache.clear({});
  await f.cache.save({}, [], [{ id: 1 }], 'stars', 'desc', before);
  await f.cache.saveIcons({}, [icon(1)], before);
  assert.equal(f.values.size, 0);
  await f.cache.save({}, [], [{ id: 2 }]);
  await f.cache.saveIcons({}, [icon(2)]);
  assert.equal(JSON.parse(f.values.get('catalog-stars-desc'))[0].id, 2);
  assert.equal(JSON.parse(f.values.get('icon-2')).id, '2');
});

test('a failed clear rejects explicitly without poisoning future cache writes or retries', async () => {
  let failed = false;
  const f = fixture({ clear: async () => { if (!failed) { failed = true; throw Error('flush unavailable'); } } });
  await assert.rejects(f.cache.clear({}), /flush unavailable/);
  await f.cache.saveIcons({}, [icon(1)]);
  assert.equal(f.values.has('icon-1'), true);
  await f.cache.clear({}); assert.equal(f.values.size, 0);
});

test('all catalog icons survive restart and a new revision replaces only its own icon', async () => {
  const f = fixture();
  const rows = Array.from({ length: 15 }, (_, i) => {
    const row = new f.CachedIcon();
    row.id = String(i + 1); row.rev = 'v1';
    row.data = Buffer.from('icon-' + row.id).toString('base64');
    return row;
  });
  await f.cache.saveIcons({}, rows);
  const apps = rows.map(row => ({ id: Number(row.id), iconRev: 'v1' }));
  assert.equal((await f.cache.loadIcons({}, apps)).size, 15);
  assert.equal(f.values.has('icons'), false, 'icons are stored separately');
  const changed = new f.CachedIcon();
  changed.id = '10'; changed.rev = 'v2';
  changed.data = Buffer.from('new-icon').toString('base64');
  await f.cache.saveIcons({}, [changed]);
  apps[9].iconRev = 'v2';
  const restored = await f.cache.loadIcons({}, apps);
  assert.equal(restored.size, 15);
  assert.equal(Buffer.from(restored.get(10)).toString(), 'new-icon');
});
