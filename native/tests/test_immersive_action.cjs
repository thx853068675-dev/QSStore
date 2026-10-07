const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture(api = 26, capability = () => true) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/theme/StoreDesign.ets'), 'utf8');
  const start = source.indexOf('export struct StoreImmersiveAction {');
  const end = source.indexOf('  @Builder private immersiveContent()', start);
  const controller = source.slice(start, end).replace('export struct', 'class')
    .replace(/@(StorageProp|Watch)\([^)]*\)\s*|@(Prop|State|BuilderParam)\s*/g, '');
  const box = { exports: {}, deviceInfo: { sdkApiVersion: api },
    uiMaterial: { isImmersiveMaterialSupported: capability } };
  vm.runInNewContext(ts.transpileModule(controller + '\n}\nexports.Action = StoreImmersiveAction;', {
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

test('remeasuring an anchor clears its previous popup acknowledgement', () => {
  const action = fixture(); action.measuredWidth = 320;
  action.onPopupStateChanged(true);
  action.measuredWidth = 280; action.onPopupRequestChanged();
  assert.equal(action.fallbackVisible(), true);
  action.onPopupStateChanged(true);
  assert.equal(action.fallbackVisible(), false);
});
