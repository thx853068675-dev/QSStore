const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function fixture(disk = new Map()) {
  const f = { disk, requests: [], revision: 0, fail: false };
  const mocks = { '@kit.ArkData': { preferences: { async getPreferences(_, name) {
    return { async get(key, fallback) { return disk.get(name + ':' + key) ?? fallback; },
      async put(key, value) { disk.set(name + ':' + key, value); }, async flush() {},
      async getAll() { return Object.fromEntries([...disk].filter(([key]) => key.startsWith(name + ':'))
        .map(([key, value]) => [key.slice(name.length + 1), value])); } };
  } } }, './StoreClient': { StoreClient: class { listReleases(...args) {
    const d = {}; const promise = new Promise((resolve, reject) => Object.assign(d, { resolve, reject }));
    f.requests.push({ args, ...d }); return promise;
  } } } };
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data', file + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText, { exports, console, AppStorage: { get: () => f.revision, setOrCreate: (_, value) => f.revision = value },
      require: name => mocks[name] || (name.startsWith('./') ? load(name.slice(2)) : {}) });
    return exports;
  }
  f.registry = load('ReleaseChannelRegistry').ReleaseChannelRegistry;
  f.app = (id = 7) => load('CatalogApp').CatalogApp.fromJson({ id, display_name: 'App',
    latest: { name: 'Stable' }, latest_asset: { name: 'app.hap', url: 'https://example.com/stable.hap',
      bundle_name: 'com.example.app', version_code: 2, version_name: '2', sha256: 'a'.repeat(64) } });
  f.release = (version = 3, preview = true) => load('ReleaseInfo').ReleaseInfo.fromJson({
    tag: 'v' + version, name: preview ? 'Preview' : 'Stable', prerelease: preview,
    assets: [{ name: 'app.hap', url: 'https://example.com/' + version + '.hap',
      bundle_name: 'com.example.app', version_code: version, version_name: String(version), sha256: 'b'.repeat(64) }] });
  return f;
}
const tick = () => new Promise(resolve => setImmediate(resolve));
test('a mirror updating one bundle keeps the other primary preview package and all current variants', async () => {
  const f = fixture(), newest = f.release(4), primary = f.release(3), older = f.release(2);
  newest.sourceKind = 'secondary';
  primary.assets.push(Object.assign({}, primary.assets[0], { bundleName:'com.example.helper', name:'helper.hap' }));
  newest.assets.push(Object.assign({}, newest.assets[0], { name:'tablet.hap' }));
  await f.registry.select({}, 7, true, [newest,primary,older]);
  const selected = f.registry.apply(f.app());
  assert.deepEqual(Array.from(selected.latestAssets, a => [a.name,a.versionCode]),
    [['app.hap',4],['tablet.hap',4],['helper.hap',3]]);
});
test('a successful channel change supplies one preview target to Discover and Management without mutating the server catalog', async () => {
  const f = fixture(), catalog = f.app(); await f.registry.restore({});
  await f.registry.select({}, 7, true, [f.release()]);
  const visible = f.registry.apply(catalog), management = f.registry.apply(catalog);
  assert.equal(visible, management); assert.equal(visible.latestAsset.versionCode, 3);
  assert.equal(catalog.latestAsset.versionCode, 2); assert.equal(visible.previewChannel, true);
  await f.registry.select({}, 7, false, [f.release(2, false)]);
  assert.equal(f.registry.apply(catalog), catalog);
});
test('preview target and mode survive restart, with an independent stable default for other apps', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const restart = fixture(f.disk); await restart.registry.restore({});
  assert.equal(restart.registry.preview(7), true); assert.equal(restart.registry.preview(8), false);
  assert.equal(restart.registry.apply(restart.app()).latestAsset.versionCode, 3);
});
test('an empty preview channel preserves application identity and does not offer the stable package', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, []);
  const selected = f.registry.apply(f.app());
  assert.equal(selected.channelUnavailable, true); assert.equal(selected.latestAsset, undefined);
  assert.equal(selected.latestAssets.length, 0); assert.equal(selected.knownAssets[0].bundleName, 'com.example.app');
});
test('only explicitly selected previews are requested, concurrent refreshes share the request, and network failure retains the target', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const work = f.registry.refreshTargets({}, [f.app(), f.app(8)], true);
  const joined = f.registry.refreshTargets({}, [f.app()], true); await tick();
  assert.equal(f.requests.length, 1); assert.deepEqual(f.requests[0].args, [7, 1, 20, true]);
  f.requests[0].reject(Error('offline')); await Promise.all([work, joined]);
  assert.equal(f.registry.preview(7), true); assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 3);
});
test('a late preview response cannot undo a subsequent stable selection', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const work = f.registry.refreshTargets({}, [f.app()], true); await tick();
  await f.registry.select({}, 7, false, [f.release(2, false)]);
  f.requests[0].resolve({ items: [f.release(4)] }); await work;
  assert.equal(f.registry.preview(7), false); assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 2);
});
test('older boolean-only preferences recover the preview channel and read its target in the background', async () => {
  const f = fixture(new Map([['release-channels:app-7', true], ['release-channel-targets:targets', '[null]']]));
  await f.registry.restore({}); assert.equal(f.registry.preview(7), true);
  assert.equal(f.registry.apply(f.app()).channelUnavailable, true);
  const work = f.registry.refreshTargets({}, [f.app()]); await tick();
  f.requests[0].resolve({ items: [f.release()] }); await work;
  assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 3);
});
test('Discovery and Management calculate the same preview update entirely from observed memory', async () => {
  const f = fixture(), source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const names = ['displayInstalledVersion', 'installedAssets', 'latestAssets', 'assetForBundle', 'updateApps', 'catalogApp',
    'catalogForJob', 'allInstalledJobs', 'recentInstalledJobs', 'currentInstalledView', 'installedVersionOf', 'updateForApp',
    'checkInstalledUpdates', 'updateFor'];
  const methods = names.map(name => { const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4); });
  const box = { ReleaseChannelRegistry: f.registry, UpdateTarget: class {},
    InstalledAppRegistry: { observedAt: () => 0, version: () => -1, versionName: () => '' }, InstallStage: { INSTALLED: 'INSTALLED' },
    LocalBundles: { isKnown: v => v >= 0, installedVersion() { throw Error('render invoked synchronous system query'); } } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { apps: [f.app()], updateCatalog: [f.app()], updateCatalogReady: true,
    installedDisplay: new Map([['com.example.app', { version: 2, versionName: '2' }]]), installedVersions: new Map([[7, 2]]),
    storeInstalled: [], installedJobs: [{ id: 'done', appId: 7, bundleName: 'com.example.app', assetName: 'app.hap',
      stage: 'INSTALLED', versionCode: 2, versionName: '2' }], updates: [] });
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  await f.registry.select({}, 7, true, [f.release()]); ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(7).versionCode, 3); assert.equal(ui.updateFor('com.example.app').versionCode, 3);
  await f.registry.select({}, 7, true, []); ui.checkInstalledUpdates();
  assert.equal(ui.updates.length, 0); assert.equal(ui.catalogForJob(ui.installedJobs[0]).id, 7);
});
test('header motion clamps overscroll and stops notifications once the search is pinned', () => {
  const source = fs.readFileSync(path.join(root, 'components/DiscoverHeader.ets'), 'utf8');
  const start = source.indexOf('export class DiscoverMotion'); const end = source.indexOf('\n@Component', start);
  const box = { exports: {} }; vm.runInNewContext(ts.transpileModule(source.slice(start, end).replace(/@Track /g, ''), {
    compilerOptions: { module: ts.ModuleKind.None, target: ts.ScriptTarget.ES2020 }
  }).outputText.replace('export ', '') + '\nglobalThis.Motion = DiscoverMotion;', box);
  const motion = new box.Motion(); motion.scroll(-100, 88); assert.equal(motion.scrollOffset, 0);
  motion.scroll(40, 88); assert.equal(motion.scrollOffset, 40);
  motion.scroll(1000, 88); assert.equal(motion.scrollOffset, 88);
  motion.pull(60); assert.equal(motion.pullOffset, 60); assert.equal(motion.scrollOffset, 0);
  motion.pull(0); motion.reachStart(-50);
  motion.scroll(38, 88); assert.equal(motion.scrollOffset, 88);
  motion.reachStart(0); motion.scroll(0, 88); assert.equal(motion.scrollOffset, 0);
});

test('returning to the list start reveals the title before refresh and the top action jumps without animation', () => {
  const component = fs.readFileSync(path.join(root, 'components/DiscoverHeader.ets'), 'utf8');
  const first = component.indexOf('export class DiscoverMotion'), last = component.indexOf('\n@Component', first);
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const methods = ['syncDiscoverScroll', 'revealDiscoverTop', 'backToDiscoverTop'].map(name => {
    const start = source.search(new RegExp(`^  private ${name}\\(`, 'm'));
    assert.ok(start >= 0); return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { ForegroundIdle: { interaction() {} }, exports: {}, Edge: { Top: 'top' } };
  vm.runInNewContext(ts.transpileModule(component.slice(first, last).replace(/@Track /g, '') +
    `\nclass Page { ${methods.join('\n')} }; globalThis.Page = Page; globalThis.Motion = DiscoverMotion;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  let offset = -50, jumped;
  const ui = new box.Page(); Object.assign(ui, { discoverMotion: new box.Motion(),
    discoverTitleHeight: 88, discoverCanRefresh: true,
    discoverScroller: { currentOffset: () => ({ yOffset: offset }), scrollEdge(...args) { jumped = args; offset = -50; } } });
  ui.revealDiscoverTop(); offset = 1000; ui.syncDiscoverScroll();
  assert.equal(ui.discoverCanRefresh, false); assert.equal(ui.discoverMotion.showTop, true);
  offset = 0; ui.syncDiscoverScroll(); assert.equal(ui.discoverMotion.scrollOffset, 50);
  assert.equal(ui.discoverCanRefresh, false, 'partially collapsed title cannot start refreshing');
  offset = -50; ui.syncDiscoverScroll(); assert.equal(ui.discoverMotion.scrollOffset, 0);
  assert.equal(ui.discoverCanRefresh, true); assert.equal(ui.discoverMotion.showTop, false);
  offset = 1000; ui.syncDiscoverScroll(); ui.backToDiscoverTop();
  assert.deepEqual(jumped, ['top']); assert.equal(ui.discoverMotion.scrollOffset, 0);
  assert.equal(ui.discoverCanRefresh, true); assert.equal(ui.discoverMotion.showTop, false);
});
