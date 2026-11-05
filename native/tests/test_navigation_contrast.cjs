const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(name, mocks = {}, globals = {}) {
  const box = { exports: {}, console: { info() {}, warn() {} }, ...globals,
    require: key => mocks[key] || {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return box.exports;
}
function navigationPage(api, dark, mode = 'adaptive', supported=true) {
  const resources = new Map();
  const resource = name => {
    if (!resources.has(name)) resources.set(name, { id: name, type: 10001, params: [name] });
    return resources.get(name);
  };
  const deviceInfo = { sdkApiVersion: api, apiAvailable: () => api >= 26 };
  const uiMaterial = {
    ImmersiveStyle: { ULTRA_THIN: 0, THIN: 1, REGULAR: 2, THICK: 3, ULTRA_THICK: 4 },
    MaterialLevel: { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 },
    ImmersiveMaterial: class { constructor(value) { Object.assign(this, value); } },
    isImmersiveMaterialSupported: () => api >= 26 && supported,
    getGlobalMaterialLevel: () => 0
  };
  const hdsMaterial = { MaterialLevel: { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2, ADAPTIVE: 10 },
    MaterialType: { IMMERSIVE: 101 }, getSystemMaterialTypes: () => [101] };
  const mocks = { '@kit.ArkUI': { uiMaterial }, '@kit.BasicServicesKit': { deviceInfo },
    '@kit.UIDesignKit': { hdsMaterial } };
  const globals = { $r: resource, AppStorage: { get: () => mode } };
  mocks['../data/MaterialPreferences'] = load('data/MaterialPreferences', mocks, globals);
  const { StoreMaterial } = load('theme/StoreMaterial', mocks, globals);
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private navigationColor(');
  assert(start >= 0, 'Index has the shared navigation foreground method');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4).replace('private ', '');
  const box = { exports: {}, deviceInfo, StoreMaterial };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} } exports.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return { page: Object.assign(new box.exports.Page(), { darkMode: dark, materialMode: mode }),
    StoreMaterial, resource };
}
test('API 24/25 keep black day and white night navigation text and icons', () => {
  for (const api of [24, 25]) for (const dark of [false, true]) {
    const { page } = navigationPage(api, dark);
    for (const index of [0, 1, 2, 3]) for (const selected of [false, true]) for (const icon of [false, true]) {
      assert.equal(page.navigationColor(index, selected, icon), dark ? '#FFFFFF' : '#000000');
    }
  }
});
test('API 26 preserves official foreground resources for native text and symbol contrast', () => {
  for (const dark of [false, true]) for (const mode of ['adaptive', 'strong', 'balanced', 'weak']) {
    const { page, resource } = navigationPage(26, dark, mode);
    for (const index of [0, 1, 2, 3]) {
      // Identity checks ensure resources reach ArkUI unchanged, rather than resolving them to hex colors.
      assert.equal(page.navigationColor(index, false), resource('sys.color.font_primary'));
      assert.equal(page.navigationColor(index, true), resource('sys.color.font_emphasize'));
      assert.equal(page.navigationColor(index, false, true), resource('sys.color.icon_primary'));
      assert.equal(page.navigationColor(index, true, true), resource('sys.color.icon_emphasize'));
    }
  }
});
test('explicit off on API 26 has the same black/white navigation foreground as 6.1',()=>{
 for(const dark of [false,true]){
  const {page}=navigationPage(26,dark,'off');
  for(const selected of [false,true])for(const icon of [false,true])assert.equal(page.navigationColor(0,selected,icon),dark?'#FFFFFF':'#000000');
 }
});
test('unsupported API 26 navigation keeps the 6.1 readable colors and background path',()=>{
 for(const dark of [false,true]){
  const {page}=navigationPage(26,dark,'adaptive',false);
  for(const selected of [false,true])for(const icon of [false,true])assert.equal(page.navigationColor(0,selected,icon),dark?'#FFFFFF':'#000000');
 }
 const source=fs.readFileSync(path.join(root,'pages/Index.ets'),'utf8');
 assert.equal((source.match(/if \(!StoreMaterial\.supported\(this\.materialMode\)\) \{ StoreTabBarBackdrop\(\{ barWidth: this\.fallbackBarWidth\(\) \}\); \}/g)||[]).length,4);
});
test('shared material helper returns system resource placeholders without parsing or replacing them', () => {
  const { StoreMaterial, resource } = navigationPage(26, false);
  assert.equal(StoreMaterial.navigationColor(false), resource('sys.color.font_primary'));
  assert.equal(StoreMaterial.navigationColor(true), resource('sys.color.font_emphasize'));
  assert.equal(StoreMaterial.navigationColor(false, true), resource('sys.color.icon_primary'));
  assert.equal(StoreMaterial.navigationColor(true, true), resource('sys.color.icon_emphasize'));
});
test('navigation no longer mounts a manual contrast sampler or rewrites colors during scrolling', () => {
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  assert.equal(/NavigationContrast|navigationContrast|navigationForeground|navigationBackdrop/.test(source), false,
    'Index must not import, instantiate, or publish a manual navigation contrast calculation');
  assert.equal(fs.existsSync(path.join(root, 'theme/NavigationContrast.ets')), false);
  assert.equal(fs.existsSync(path.join(root, 'theme/NavigationContrastSampler.ets')), false);
  for (const index of [0, 1, 2, 3]) {
    assert(new RegExp(`navigationColor\\(${index}, false, true\\)`).test(source), 'normal symbol uses official icon resource');
    assert(new RegExp(`navigationColor\\(${index}, true, true\\)`).test(source), 'selected symbol uses official icon resource');
    assert(new RegExp(`selectedColor: this\\.navigationColor\\(${index}, true\\)`).test(source), 'label retains official text resource');
    assert(new RegExp(`unselectedColor: this\\.navigationColor\\(${index}, false\\)`).test(source), 'label retains official text resource');
  }
});
test('transparent navigation mask retains a native background sampling region', () => {
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const tabs = source.slice(source.indexOf('  navigationTabs() {'), source.indexOf('\n  build() {', source.indexOf('  navigationTabs() {')));
  assert.match(tabs, /deviceInfo\.sdkApiVersion >= 26 && StoreMaterial\.supported\(this\.materialMode\)/);
  assert.match(tabs, /\bTabs\(\{[\s\S]*?systemMaterial: StoreMaterial\.dock\(this\.materialMode, this\.darkMode\)/,
    'API 26 navigation explicitly opts into native colorInvert rather than only requesting an HDS material grade');
  assert.match(tabs, /maskColor:\s*'#00000000'/);
  assert.match(tabs, /HdsTabs\(/, 'API 24/25 retain compatible HDS navigation');
  assert.doesNotMatch(tabs, /maskHeight:\s*0\b/,
    'zero height collapses the system luminance sample area even when the mask is transparent');
});
