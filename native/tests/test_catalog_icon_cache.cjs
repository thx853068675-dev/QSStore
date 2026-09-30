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

function fixture() {
  const values = new Map();
  const prefs = {
    async get(key, fallback) { return values.get(key) ?? fallback; },
    async put(key, value) { values.set(key, value); },
    async flush() {}
  };
  const exports = {};
  vm.runInNewContext(code, {
    exports,
    require: name => name === '@kit.ArkData' ?
      { preferences: { getPreferences: async () => prefs } } :
      name === '@kit.ArkTS' ?
        { util: { Base64Helper: class {
          decodeSync(input) { return Uint8Array.from(Buffer.from(input, 'base64')); }
        } } } : {}
  });
  return { values, cache: exports.CatalogCache, CachedIcon: exports.CachedIcon };
}

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
