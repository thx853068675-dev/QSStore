const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const exportsForTest = {};
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/VersionBadgeLayout.ets'), 'utf8');
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsForTest });
const { fitVersionBadge } = exportsForTest;

test('a truncated preview badge reserves only the displayed glyphs and padding', () => {
  const value = 'v0.4.51-preview.1';
  for (const scale of [1, 1.3, 2]) {
    const measure = text => Array.from(text).reduce((width, char) =>
      width + (char === '.' ? 2 : char === '…' ? 8 : 6) * scale, 0);
    const badge = fitVersionBadge(value, 77, measure);
    assert.ok(badge.text.endsWith('…'));
    assert.equal(badge.width, Math.ceil(measure(badge.text) + 8));
    assert.ok(badge.width <= 77);
    assert.ok(value.startsWith(badge.text.slice(0, -1)));
  }
});

test('short versions keep their natural width and changes can restore a full label', () => {
  const measure = text => Array.from(text).length * 5;
  assert.equal(fitVersionBadge('v1.0', 77, measure).width, 28);
  assert.equal(fitVersionBadge('v0.4.51-preview.1', 200, measure).text, 'v0.4.51-preview.1');
  for (const width of [0, 8, 12, NaN]) {
    assert.equal(fitVersionBadge('v1.0', width, measure).width, 0);
  }
  assert.equal(fitVersionBadge('', 77, measure).width, 0);
});

test('truncation never leaves half a Unicode code point', () => {
  const badge = fitVersionBadge('v1.0-🚀preview', 48,
    text => Array.from(text).length * 5);
  assert.equal(badge.text, 'v1.0-🚀p…');
  assert.equal(badge.width, 48);
});
