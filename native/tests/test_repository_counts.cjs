const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function load(name) {
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data', name + '.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: () => ({}) });
  return exports;
}

test('repository counts use K at boundaries without rounding an incomplete thousand up', () => {
  const { repositoryCount } = load('RepositoryCount');
  for (const [value, expected] of [[0, '0'], [999, '999'], [1000, '1K'],
    [1999, '1.9K'], [10000, '10K'], [123456, '123.4K'], [-1, '—'], [NaN, '—']]) {
    assert.equal(repositoryCount(value), expected);
  }
});

test('catalog refresh, copies and cached JSON preserve counts while old servers remain compatible', () => {
  const { CatalogApp } = load('CatalogApp');
  for (const [raw, expected] of [[0, 0], [123456, 123456], [null, -1],
    [undefined, -1], [-2, -1], ['invalid', -1]]) {
    const row = { id: 3, github_downloads: raw };
    const app = CatalogApp.fromJson(row);
    assert.equal(app.githubDownloads, expected);
    assert.equal(CatalogApp.copy(app).githubDownloads, expected);
    assert.equal(CatalogApp.fromJson(JSON.parse(JSON.stringify(row))).githubDownloads, expected);
  }
});
