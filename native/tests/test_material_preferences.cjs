const { test } = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(supported = true) {
  const disk = new Map(), storage = new Map(); let checks = 0;
  const exports = {};
  const Hds = { MaterialType: { NONE:0, IMMERSIVE: 101, ADAPTIVE:100 }, MaterialLevel: { ADAPTIVE: 10, EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 },
    getSystemMaterialTypes: () => { checks++; return supported ? [101] : []; } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/data/MaterialPreferences.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports,
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    require: name => ({ '@kit.UIDesignKit': { hdsMaterial: Hds },
      '@kit.ArkUI': { uiMaterial: { ImmersiveStyle: { ULTRA_THIN: 11, THIN: 12, REGULAR: 13 } } },
      '@kit.ArkData': { preferences: { getPreferences: async () => ({
        get: async (key, fallback) => disk.get(key) ?? fallback,
        put: async (key, value) => disk.set(key, value), flush: async () => {} }) } }
    })[name] || {} });
  return { service: exports.MaterialPreferences, disk, storage, checks: () => checks };
}
test('material preference uses official grades and caches device capability', () => {
  const f = fixture(); assert.equal(f.service.level('adaptive'), 10);
  assert.equal(f.service.level('strong'), 0); assert.equal(f.service.level('balanced'), 1);
  assert.equal(f.service.level('weak'), 2); assert.equal(f.checks(), 1);
});
test('unsupported hardware never receives a forced expensive material grade', () => {
  const f = fixture(false); assert.equal(f.service.level('strong'), 2);
  assert.equal(f.service.level('balanced'), 2); assert.equal(f.service.level('adaptive'), 10);
  assert.equal(f.service.type(),100);assert.equal(f.service.supported(),false);
});
test('component materials use the same saved strength without forcing unsupported hardware', () => {
  const f = fixture();
  for (const [mode, style] of [['adaptive', 12], ['strong', 11], ['balanced', 12], ['weak', 13]]) {
    assert.equal(f.service.style(mode), style);
    assert.equal(f.service.style(mode), style);
  }
  assert.equal(f.checks(), 0, 'style selection must not query capabilities for every floating control');
});
test('light strength preserves its color and attenuates only the alpha channel', () => {
  const f = fixture();
  for (const color of ['#2463E9', '#FFFFFF', '#000000']) {
    assert.equal(f.service.lightColor('adaptive', color), color);
    assert.equal(f.service.lightColor('strong', color), color);
    const balanced = f.service.lightColor('balanced', color), weak = f.service.lightColor('weak', color);
    assert.match(balanced, /^#[0-9A-Fa-f]{8}$/);
    assert.match(weak, /^#[0-9A-Fa-f]{8}$/);
    assert.equal(balanced.slice(3), color.slice(1));
    assert.equal(weak.slice(3), color.slice(1));
    assert.ok(parseInt(balanced.slice(1, 3), 16) > parseInt(weak.slice(1, 3), 16));
    assert.ok(Math.abs(parseInt(balanced.slice(1, 3), 16) / 255 - .7) < 1 / 255);
    assert.ok(Math.abs(parseInt(weak.slice(1, 3), 16) / 255 - .35) < 1 / 255);
  }
});
test('material choice survives reload and invalid old preferences recover to automatic', async () => {
  const f = fixture(); await f.service.save({}, 'balanced'); await f.service.load({});
  assert.equal(f.storage.get('materialMode'), 'balanced');
  f.disk.set('materialMode', 'invalid'); await f.service.load({});
  assert.equal(f.storage.get('materialMode'), 'adaptive');
});
test('explicit off persists, opts HDS out of system adaptation and keeps the compatible thin blur',async()=>{
 const f=fixture();assert.equal(f.service.normalize('off'),'off');assert.equal(f.service.label('off'),'关闭');
 assert.equal(f.service.type('off'),0);assert.equal(f.service.level('off'),2);assert.equal(f.service.style('off'),12);assert.equal(f.checks(),0);
 await f.service.save({},'off');await f.service.load({});assert.equal(f.storage.get('materialMode'),'off');
 await f.service.save({},'strong');assert.equal(f.service.type('strong'),101);assert.equal(f.service.level('strong'),0);
});
