const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture() {
  const storage = new Map(), handlers = new Map(), state = {
    top: 144, cutout: 100, density: 3, unavailable: false, loaded: false, uiReads: 0,
    events: [], failFullscreen: false, enabledBars: {}
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
    setSpecificSystemBarEnabled: async (name, enabled) => {
      state.enabledBars[name] = enabled;
      state.events.push(name);
      // Restoring system navigation can restore its default opaque background.
      if(enabled)state.bars={navigationBarColor:'#FFFFFFFF'};
    },
    setWindowBackgroundColor: color => { state.backgroundColor = color; },
    setWindowSystemBarProperties: async bars => { state.events.push('bars'); state.bars = bars; },
    setWindowLayoutFullScreen: async enabled => {
      state.fullscreen = enabled;
      // The native callback can fire before the page has a UIContext.
      handlers.get('avoidAreaChange')({ type: 0 });
      await Promise.resolve();
      if (state.failFullscreen) throw Error('fullscreen rejected');
      // A native layout transition may reset window defaults after an earlier bar update.
      state.bars = { statusBarColor: '#FFFFFFFF' };
      state.events.push('fullscreen-complete');
    }
  };
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, {
    exports, AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    require: name => name === '../jobs/BackgroundInstallTask' ? {
      BackgroundInstallTask: { configure: () => {}, onForeground: () => {} }
    } : name === '../jobs/WirelessDebugLifecycle' ? {
      WirelessDebugLifecycle: { configure() {}, onForeground() {}, onBackground() {} }
    } : name === '@kit.AbilityKit' ? {
      UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 1 } }
    } : {
      window: { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_CUTOUT: 1 } },
      display: { getDisplayByIdSync: id => { assert.equal(id, 7); return { densityPixels: state.density }; } }
    }
  });
  const ability = new exports.default();
  ability.context = { config: { colorMode: 0 }, filesDir: '/sandbox' };
  const stage = { getMainWindowSync: () => win,
    loadContent: (page, callback) => {
      assert.equal(page, 'pages/Index'); state.loaded = true;
      state.events.push('load');
      // Loading the content can restore component defaults too.
      state.bars = { statusBarColor: '#FFFFFFFF' };
      callback({ code: 0 });
    } };
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
  assert.equal(f.state.backgroundColor, '#00000000');
  const transition = f.state.events.indexOf('fullscreen-complete');
  const load = f.state.events.indexOf('load');
  assert.ok(f.state.events.slice(transition + 1, load).includes('bars'));
  assert.ok(f.state.events.slice(load + 1).includes('bars'));
});

test('a rejected full-screen transition still loads the page with transparent bars', async () => {
  const f = fixture(); f.state.failFullscreen = true;
  f.ability.onWindowStageCreate(f.stage);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.loaded, true);
  assert.equal(f.state.bars.statusBarColor, '#00000000');
});

test('a destroyed stage does not load content after its full-screen transition settles', async () => {
  const f = fixture();
  f.ability.onWindowStageCreate(f.stage);
  f.ability.onWindowStageDestroy();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.loaded, false);
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
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.storage.get('darkMode'), true);
  assert.equal(f.state.bars.statusBarColor, '#00000000');
  assert.equal(f.state.bars.navigationBarColor, '#00000000');
  assert.notEqual(f.state.bars.statusBarContentColor, lightText);
});

test('returning from settings retains the gesture indicator and clears the background after restoring it', async () => {
  const f = fixture();
  f.ability.onWindowStageCreate(f.stage);
  await new Promise(resolve => setImmediate(resolve));
  f.state.enabledBars.navigation = false;
  f.state.enabledBars.navigationIndicator = false;
  f.state.bars = { statusBarColor: '#FFFFFFFF' };
  f.ability.onForeground();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.bars.statusBarColor, '#00000000');
  assert.equal(f.state.bars.navigationBarColor, '#00000000');
  assert.equal(f.state.enabledBars.navigation, true);
  assert.equal(f.state.enabledBars.navigationIndicator, true);
  assert.deepEqual(f.state.events.slice(-3), ['navigation', 'navigationIndicator', 'bars']);
});
