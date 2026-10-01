const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture() {
  const storage = new Map(), handlers = new Map(), state = {
    top: 144, cutout: 100, density: 3, unavailable: false, loaded: false, uiReads: 0
  };
  const win = {
    on: (name, callback) => handlers.set(name, callback),
    off: (name, callback) => { assert.equal(handlers.get(name), callback); handlers.delete(name); },
    getWindowAvoidArea: type => {
      if (state.unavailable) throw Error('window switching');
      return { topRect: { height: type === 0 ? state.top : state.cutout } };
    },
    getWindowProperties: () => ({ displayId: 7 }),
    getUIContext: () => { state.uiReads++; throw Error('UI content not loaded'); },
    setSpecificSystemBarEnabled: async () => {},
    setWindowSystemBarProperties: async bars => { state.bars = bars; },
    setWindowLayoutFullScreen: async enabled => {
      state.fullscreen = enabled;
      // The native callback can fire before the page has a UIContext.
      handlers.get('avoidAreaChange')({ type: 0 });
    }
  };
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, {
    exports, AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    require: name => name === '@kit.AbilityKit' ? {
      UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 1 } }
    } : {
      window: { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_CUTOUT: 1 } },
      display: { getDisplayByIdSync: id => { assert.equal(id, 7); return { densityPixels: state.density }; } }
    }
  });
  const ability = new exports.default();
  ability.context = { config: { colorMode: 0 }, filesDir: '/sandbox' };
  const stage = { getMainWindowSync: () => win,
    loadContent: page => { assert.equal(page, 'pages/Index'); state.loaded = true; } };
  return { ability, stage, state, storage, handlers };
}

test('edge-to-edge startup reads real insets before UI content without obtaining UIContext', async () => {
  const f = fixture();
  f.ability.onWindowStageCreate(f.stage);
  f.ability.onForeground();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.loaded, true);
  assert.equal(f.state.fullscreen, true);
  assert.equal(f.state.uiReads, 0);
  assert.equal(f.storage.get('statusBarInset'), 48);
  assert.equal(f.state.bars.statusBarColor, '#00000000');
  assert.equal(f.state.bars.navigationBarColor, '#00000000');
});

test('cutout and density changes update the inset; unavailable windows retain the last value', async () => {
  const f = fixture();
  f.ability.onWindowStageCreate(f.stage);
  await new Promise(resolve => setImmediate(resolve));
  f.state.cutout = 180; f.state.density = 2;
  f.handlers.get('avoidAreaChange')({ type: 1 });
  assert.equal(f.storage.get('statusBarInset'), 90);
  f.state.unavailable = true;
  assert.doesNotThrow(() => f.ability.onForeground());
  assert.equal(f.storage.get('statusBarInset'), 90);
  f.ability.onWindowStageDestroy();
  assert.equal(f.handlers.size, 0);
});

test('theme changes keep the status bar transparent while switching text contrast', async () => {
  const f = fixture();
  f.ability.onWindowStageCreate(f.stage);
  await new Promise(resolve => setImmediate(resolve));
  const lightText = f.state.bars.statusBarContentColor;
  f.ability.onConfigurationUpdate({ colorMode: 1 });
  assert.equal(f.storage.get('darkMode'), true);
  assert.equal(f.state.bars.statusBarColor, '#00000000');
  assert.equal(f.state.bars.navigationBarColor, '#00000000');
  assert.notEqual(f.state.bars.statusBarContentColor, lightText);
});
