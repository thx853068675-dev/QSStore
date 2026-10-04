const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const exported = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/CatalogPaging.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exported });
const { appendCatalogPage, shouldPrefetchCatalog } = exported;
const ids = rows => Array.from(rows, row => row.id);

test('a later high-star page never moves cards already displayed or duplicates a moving page boundary', () => {
  const first = appendCatalogPage([], [
    { id: 1, stars: 5 }, { id: 2, stars: 200 }, { id: 3, stars: 150 }
  ]);
  assert.deepEqual(ids(first), [2, 3, 1]);
  const second = appendCatalogPage(first, [
    { id: 1, stars: 5 }, { id: 4, stars: 100 }, { id: 5, stars: 10000 }, { id: 5, stars: 10000 }
  ]);
  assert.deepEqual(ids(second), [2, 3, 1, 5, 4]);
  assert.deepEqual(ids(first), [2, 3, 1]);
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
