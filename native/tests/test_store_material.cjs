const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture(api = 26, capability = () => true, options={}) {
  let queries = 0;
  const uiMaterial = { isImmersiveMaterialSupported() { queries++; return capability(); },
    ImmersiveStyle: { ULTRA_THIN: 11, THIN: 12, REGULAR: 13 },
    ImmersiveMaterial: class { constructor(value) { if(options.constructorFails)throw Error('native material unavailable');Object.assign(this, value); } } };
  const Hds = { MaterialType: { IMMERSIVE: 101 }, MaterialLevel: { ADAPTIVE: 10, EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 },
    getSystemMaterialTypes: () => options.hds===false?[]:[101] };
  const mocks = { '@kit.ArkUI': { uiMaterial }, '@kit.UIDesignKit': { hdsMaterial: Hds },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: api } } };
  function load(file) {
    const box = { exports: {}, require: key => mocks[key] || {},
      $r: name => ({ id: name, type: 'Resource' }),
      BlurStyle: { COMPONENT_ULTRA_THIN: 21, COMPONENT_THIN: 22, COMPONENT_REGULAR: 23 } };
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
      '../entry/src/main/ets', file + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText, box);
    return box.exports;
  }
  mocks['../data/MaterialPreferences'] = load('data/MaterialPreferences');
  mocks['./Palette'] = load('theme/Palette');
  return { service: load('theme/StoreMaterial').StoreMaterial, queries: () => queries,
    Palette: mocks['./Palette'].Palette };
}

test('all native material strengths share preferences for glass and branded controls', () => {
  const f = fixture();
  for (const [mode, style] of [['adaptive', 12], ['strong', 11], ['balanced', 12], ['weak', 13]]) {
    const glass = f.service.glass(mode, false), tint = f.service.tinted(mode, '#2463E9');
    assert.equal(glass.style, style); assert.equal(tint.style, style);
    assert.equal(glass.colorInvert, true, 'unbranded material delegates contrast to the system');
    assert.equal(tint.colorInvert, false, 'brand fills retain white text instead of changing their meaning');
    assert.equal(glass.interactive, true); assert.equal(tint.interactive, true);
    assert.equal(tint.materialColor.slice(3), '2463E9');
    assert.equal(parseInt(tint.materialColor.slice(1, 3), 16), 153);
    const expected = mode === 'balanced' ? Math.round(255 * .7) : mode === 'weak' ? Math.round(255 * .35) : 255;
    const light = tint.lightEffect.color;
    assert.equal(light.slice(-6), '2463E9');
    assert.equal(light.length === 7 ? 255 : parseInt(light.slice(1, 3), 16), expected);
  }
});

test('floating shadows and tint transparency survive changes in strength', () => {
  const f = fixture();
  for (const mode of ['adaptive', 'strong', 'balanced', 'weak']) {
    assert.equal(f.service.glass(mode, true, false).applyShadow, false);
    for (const strength of [-2, 0, .5, 1, 3, NaN, Infinity]) {
      const material = f.service.tinted(mode, '#C62663', strength, false);
      assert.equal(material.applyShadow, false);
      assert.match(material.materialColor, /^#[0-9A-Fa-f]{8}$/);
      assert.equal(material.materialColor.slice(3), 'C62663');
      const alpha = parseInt(material.materialColor.slice(1, 3), 16);
      assert.ok(Number.isFinite(alpha) && alpha >= 0 && alpha <= 153);
      if (Number.isFinite(strength)) assert.equal(alpha, Math.round(153 * Math.max(0, Math.min(1, strength))));
      else assert.equal(alpha, 153, 'invalid animation input restores the default tint instead of emitting NaN');
    }
  }
});

test('official adaptive foregrounds retain resource identity instead of being resolved to fixed hex', () => {
  const f = fixture();
  for (const dark of [false, true]) {
    for (const secondary of [false, true]) {
      const color = f.service.foreground(dark, secondary);
      assert.equal(typeof color, 'object');
      assert.equal(color.type, 'Resource');
      assert.equal(color.id, secondary ? 'sys.color.font_secondary' : 'sys.color.font_primary');
    }
    const icon = f.service.icon(dark);
    assert.equal(icon.type, 'Resource'); assert.equal(icon.id, 'sys.color.icon_primary');
  }
  assert.equal(f.queries(), 1, 'capability must be shared and cached across all controls');
});

test('6.1 and unavailable native services keep readable theme foregrounds without unsupported queries', () => {
  for (const api of [24, 25]) {
    const f = fixture(api, () => { throw Error('API 26 capability queried on old system'); });
    assert.equal(f.service.supported(), false);
    for (const dark of [false, true]) {
      assert.equal(f.service.foreground(dark), f.Palette.forMode(dark).text);
      assert.equal(f.service.foreground(dark, true), f.Palette.forMode(dark).textSecondary);
      assert.equal(typeof f.service.icon(dark), 'string');
    }
    assert.equal(f.queries(), 0);
  }
  const unavailable = fixture(26, () => { throw Error('material service unavailable'); });
  assert.equal(unavailable.service.supported(), false);
  assert.equal(typeof unavailable.service.foreground(false), 'string');
  assert.equal(unavailable.queries(), 1);
});

test('old-system blur styles respond to the same strength preference', () => {
  const f = fixture(24);
  assert.equal(f.service.blurStyle('adaptive'), 22);
  assert.equal(f.service.blurStyle('strong'), 21);
  assert.equal(f.service.blurStyle('balanced'), 22);
  assert.equal(f.service.blurStyle('weak'), 23);
  assert.equal(f.queries(), 0);
});
test('API 26 with a disabled device policy or broken constructor uses the readable 6.1 fallback',()=>{
 for(const options of [{hds:false},{constructorFails:true}]){
  const f=fixture(26,()=>true,options);assert.equal(f.service.supported(),false);
  for(const dark of [false,true]){
   assert.equal(f.service.foreground(dark),f.Palette.forMode(dark).text);
   assert.equal(f.service.fallbackFill(dark),'#E6'+f.Palette.forMode(dark).surface.slice(1));
  }
  assert.equal(f.queries(),1);
 }
 const missing=fixture(26,()=>false);assert.equal(missing.service.supported(),false);
});
test('off bypasses all native capability/material work, has 6.1 colors and can be reenabled without poisoning capability',()=>{
 const f=fixture();assert.equal(f.service.supported('off'),false);assert.equal(f.queries(),0);
 for(const dark of [false,true]){
  assert.equal(f.service.foreground(dark,false,'off'),f.Palette.forMode(dark).text);
  assert.equal(f.service.foreground(dark,true,'off'),f.Palette.forMode(dark).textSecondary);
  assert.equal(f.service.icon(dark,'off'),f.Palette.forMode(dark).text);
 }
 assert.equal(f.queries(),0);assert.throws(()=>f.service.glass('off',false),/已关闭/);assert.throws(()=>f.service.tinted('off','#2463E9'),/已关闭/);
 assert.equal(f.service.supported('strong'),true);assert.equal(f.queries(),1);
 assert.equal(f.service.supported('off'),false);assert.equal(f.service.supported('adaptive'),true);assert.equal(f.queries(),1);
});
test('retiring an existing native modifier clears only the API 26 renderer, never touching unavailable old-system APIs',()=>{
 for(const api of [24,25,26]){
  const f=fixture(api),calls=[];f.service.clearNative({systemMaterial:value=>{calls.push(value);}});
  assert.equal(calls.length,api>=26?1:0);if(calls.length)assert.equal(calls[0],undefined);assert.equal(f.queries(),0);
 }
});
