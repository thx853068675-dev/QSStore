const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture(api = 26, capability = () => true) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/theme/StoreDesign.ets'), 'utf8');
  const start = source.indexOf('export struct StoreImmersiveAction {');
  const end = source.indexOf('  @Builder private immersiveContent(', start);
  const controller = source.slice(start, end).replace('export struct', 'class')
    .replace(/@(StorageProp|Watch)\([^)]*\)\s*|@(Prop|State|BuilderParam)\s*/g, '');
  const factoryStart = source.indexOf('export function storeTintedImmersiveMaterial(');
  const factory = source.slice(factoryStart, source.indexOf('\n}', factoryStart) + 2)
    .replace('export function', 'function');
  const box = { exports: {}, deviceInfo: { sdkApiVersion: api },
    uiMaterial: { isImmersiveMaterialSupported: capability, ImmersiveStyle: {THIN: 1},
      ImmersiveMaterial: class { constructor(options) { Object.assign(this, options); } } } };
  vm.runInNewContext(ts.transpileModule(factory + '\n' + controller + '\n}\nexports.Action = StoreImmersiveAction;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return new box.exports.Action();
}

test('support and an open request cannot hide the primary action before actual popup acknowledgement', () => {
  const action = fixture();
  assert.equal(action.popupRequested(), false);
  assert.equal(action.fallbackVisible(), true);
  action.measuredWidth = 320;
  assert.equal(action.popupRequested(), true);
  assert.equal(action.fallbackVisible(), true);
  action.onPopupStateChanged(true);
  assert.equal(action.fallbackVisible(), false);
});

test('clipped toolbar tint disables intrinsic material shadows while detail actions retain them', () => {
  const detail = fixture();
  assert.equal(detail.actionMaterial().applyShadow, true);
  const toolbar = fixture(); toolbar.popupShadow = false; toolbar.controlRadius = 22;
  toolbar.tint = '#C62663';
  for (const strength of [0, .5, 1]) {
    toolbar.tintStrength = strength;
    const material = toolbar.actionMaterial();
    assert.equal(material.applyShadow, false, 'transparent tint must not leave a clipped shadow underneath');
    assert.equal(material.interactive, true);
    assert.equal(material.lightEffect.color, '#C62663');
    assert.equal(material.materialColor.slice(3), 'C62663');
  }
  toolbar.colored = false;
  assert.equal(toolbar.actionMaterial().applyShadow, false);
  assert.equal(toolbar.actionMaterial().interactive, true);
});

test('a failed or unexpectedly closed native popup restores the in-page action', () => {
  const action = fixture(); action.measuredWidth = 320;
  action.onPopupStateChanged(false);
  assert.equal(action.fallbackVisible(), true);
  action.onPopupStateChanged(true);
  action.onPopupStateChanged(false);
  assert.equal(action.fallbackVisible(), true);
});

test('page hiding and transitions reject late visible events and reopen with a usable fallback', () => {
  for (const field of ['visible', 'routeTransitioning']) {
    const action = fixture(); action.measuredWidth = 320;
    action.onPopupStateChanged(true);
    action[field] = field === 'visible' ? false : true;
    action.onPopupRequestChanged(); action.onPopupStateChanged(true);
    assert.equal(action.popupVisible, false);
    assert.equal(action.fallbackVisible(), false);
    action[field] = field === 'visible' ? true : false;
    action.onPopupRequestChanged();
    assert.equal(action.fallbackVisible(), true);
    action.onPopupStateChanged(true);
    assert.equal(action.fallbackVisible(), false);
  }
});

test('unsupported systems and capability-query failures always retain the ordinary action', () => {
  for (const api of [24, 25]) {
    const action = fixture(api, () => { throw Error('Older system must never query immersive support'); });
    action.measuredWidth = 320;
    assert.equal(action.canUseMaterial(), false);
    assert.equal(action.fallbackVisible(), true);
  }
  const failed = fixture(26, () => { throw Error('Native service unavailable'); });
  failed.measuredWidth = 320; failed.popupVisible = true;
  assert.equal(failed.canUseMaterial(), false);
  assert.equal(failed.fallbackVisible(), true);
});

test('resizing a visible popup retains its acknowledgement and cannot draw a duplicate fallback', () => {
  const action = fixture(); action.measuredWidth = 320;
  action.onPopupStateChanged(true);
  action.measuredWidth = 280; action.onPopupRequestChanged();
  assert.equal(action.fallbackVisible(), false);
  action.onPopupStateChanged(false);
  assert.equal(action.fallbackVisible(), true);
});

test('embedded clipping never shrinks a native bubble as its button crosses either edge', () => {
  const action = fixture(); action.measuredWidth = 88; action.embedded = true;
  action.controlHeight = 44; action.anchorAtStart = true;
  for (const offset of [-87, -30, 0, 240, 337]) {
    action.viewportOffset = offset;
    assert.equal(action.popupWidth(), 88);
    assert.equal(action.popupAnchorX(), -offset);
    const position = action.popupOffset();
    assert.equal(position.x, offset); assert.equal(position.y, -44);
  }
  action.visible = false; action.onPopupRequestChanged();
  assert.equal(action.popupRequested(), false);
});

test('placement calibration cancels measured native avoidance without changing size or radius', () => {
  const action = fixture(); action.measuredWidth = 88; action.embedded = true;
  action.controlHeight = 44; action.controlRadius = 22; action.anchorAtStart = true;
  action.anchorX = 78; action.anchorY = 47; action.viewportOffset = 320;
  action.correctEmbeddedPlacement({globalPosition:{x:405,y:43}});
  assert.equal(action.placementCorrectionX, -7); assert.equal(action.placementCorrectionY, 4);
  assert.equal(action.popupOffset().x, 313); assert.equal(action.popupOffset().y, -40);
  action.correctEmbeddedPlacement({globalPosition:{x:398,y:47}});
  assert.equal(action.placementCorrectionX, -7); assert.equal(action.placementCorrectionY, 4);
  action.viewportOffset = -50;
  action.correctEmbeddedPlacement({globalPosition:{x:28,y:47}});
  assert.equal(action.placementCorrectionX, -7); assert.equal(action.popupWidth(), 88);
  assert.equal(action.controlRadius, 22);
});

test('ordinary detail actions retain their upward placement and ignore viewport calibration', () => {
  const action = fixture(); action.measuredWidth = 320;
  action.anchorX = 20; action.anchorY = 600;
  action.correctEmbeddedPlacement({globalPosition:{x:100,y:100}});
  assert.equal(action.popupOffset().x, 0); assert.equal(action.popupOffset().y, 52);
  assert.equal(action.popupAnchorX(), 0);
});

test('hidden, unmeasured, and invalid popup geometry cannot apply late placement corrections', () => {
  const action = fixture(); action.embedded = true; action.measuredWidth = 88;
  action.correctEmbeddedPlacement({globalPosition:{x:5,y:5}});
  action.anchorX = 20; action.anchorY = 40;
  action.correctEmbeddedPlacement({globalPosition:{x:NaN,y:5}});
  action.visible = false;
  action.correctEmbeddedPlacement({globalPosition:{x:5,y:5}});
  assert.equal(action.placementCorrectionX, 0); assert.equal(action.placementCorrectionY, 0);
});
