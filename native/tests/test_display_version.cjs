const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const exportsForTest = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/DisplayVersion.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsForTest });
const { displayVersion } = exportsForTest;

test('known names tolerate spaces, hyphens, underscores and separator changes', () => {
  for (const value of ['My App  1.2.3', 'My-App-v1.2.3', 'My_App : v1.2.3', 'MY—APP 1.2.3'])
    assert.equal(displayVersion(value, 'My App'), '1.2.3');
  assert.equal(displayVersion('轻启  ·  安装器-v0.4.52-pre', '轻启·安装器'), '0.4.52-pre');
  assert.equal(displayVersion('工具-2.0-v1.2.3', '工具 2.0'), '1.2.3');
  assert.equal(displayVersion('OHcode2-v1.8.0', 'OHcode2'), '1.8.0');
});
test('semantic prereleases and build metadata remain visible', () => {
  for (const version of ['1.2.3-beta.2', '1.2.3-rc.1+build.9', '0.4.52-pre', '1.2.3-M1', '1.2.3+abc123'])
    assert.equal(displayVersion('HarmonyX-v'+version, 'HarmonyX'), version);
  assert.equal(displayVersion('MyApp 1.2.3 Beta 2', 'MyApp'), '1.2.3-beta.2');
});
test('calendar and four-part versions, major-only and numeric build names are supported', () => {
  for(const version of ['2026.10.04','1.2.3.4','2026100403'])
    assert.equal(displayVersion('MyApp '+version, 'MyApp'), version);
  assert.equal(displayVersion('MyApp v2', 'MyApp'), '2');
  assert.equal(displayVersion('unknown title-v1.8.0.hap'), '1.8.0');
});
test('uncertain labels remain intact and extraction does not mutate original values', () => {
  for(const raw of ['nightly','main','工具 2','abc123def','build-a1b2c3','暂无预览版本'])
    assert.equal(displayVersion(raw),raw);
  const raw='MyApp-v1.2.3-beta.2+build.9';
  assert.equal(displayVersion(raw,'MyApp'),'1.2.3-beta.2+build.9');
  assert.equal(raw,'MyApp-v1.2.3-beta.2+build.9');
  assert.equal(displayVersion('  '),'');
});
