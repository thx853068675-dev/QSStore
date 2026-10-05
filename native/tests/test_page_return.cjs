const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
  assert(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function fixture() {
  const f = { viewed: [], icons: [], scans: 0, myAppsCalls: 0, myAppsFetch: async () => [] };
  const timers = new Map(); let nextTimer = 0;
  f.flushResume = () => { for (const [id, fn] of timers) { timers.delete(id); fn(); } };
  f.timers = timers;
  const box = { ForegroundIdle: { onForeground() {}, interaction() {},
    defer: (key, fn) => timers.set(key, fn), cancel: key => timers.delete(key) }, setTimeout: fn => { timers.set(++nextTimer, fn); return nextTimer; },
    clearTimeout: id => timers.delete(id), StoreClient: class {
    static consumeViewedApps() { const rows = f.viewed; f.viewed = []; return rows; }
    myApps() { f.myAppsCalls++; return f.myAppsFetch(); }
  }, getContext: () => ({}), errorText: error => error.message };
  vm.runInNewContext(ts.transpileModule(`class Index { static TAB_MANAGE = 2; static TAB_MINE = 3;
    ${['onPageShow', 'onPageHide', 'cancelResumeMaintenance', 'syncViewedCatalog', 'loadMyApps', 'onTabChanged'].map(method).join('\n')} }; globalThis.Page = Index;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  box.InstallConfirmation = { deactivate() {} }; box.InstallReconnect = { deactivate() {} };
  const ui = new box.Page(); Object.assign(ui, { pageVisible: false, topActionEpoch: 3,
    resumeMaintenancePending: false,
    currentTab: 0, signedIn: true, account: {}, myApps: [{ id: 1, category: '工具' }], syncManagementIcons() {},
    myAppsLoaded: true, myAppsBusy: false, myAppsRefreshing: false, myAppsMessage: '',
    apps: [{ id: 1, iconRev: 'old' }, { id: 2, iconRev: 'same' }],
    updateCatalog: [{ id: 1, iconRev: 'old' }, { id: 2, iconRev: 'same' }],
    appIcons: [{ id: 1, rev: 'old', pixels: 'original pixels' }], catalogPage: 4,
    discoverMotion: { showTop: true }, scrollOffset: 1234, activeQuery: 'saved search',
    observeReconnect() {}, observeInstallTasks() {}, drainInstallQueue() {}, syncManagementRows() {}, syncDiscoverRows() {},
    refreshCatalogInstallState() {}, reconcileInterruptedInstalls: async () => {}, reconcileStuckJobs() {},
    scanDeviceInstalled() { f.scans++; }, loadSigningExpiries() {},
    loadApps() { throw Error('return must not restart paginated network loading'); },
    loadAppIcon(_client, app) { f.icons.push(app); } });
  f.ui = ui; return f;
}
test('return from detail preserves discovery pagination, scroll and icons, and renews native popup ownership', () => {
  const { ui } = fixture(); const apps = ui.apps, icons = ui.appIcons;
  ui.onPageShow(); assert.equal(ui.pageVisible, true); assert.equal(ui.topActionEpoch, 4);
  assert.equal(ui.apps, apps); assert.equal(ui.appIcons, icons); assert.equal(ui.catalogPage, 4);
  assert.equal(ui.scrollOffset, 1234); assert.equal(ui.discoverMotion.showTop, true);
  ui.onPageHide(); assert.equal(ui.pageVisible, false);
  ui.onPageShow(); assert.equal(ui.topActionEpoch, 5); assert.equal(ui.discoverMotion.showTop, true);
});
test('return to Management merges only viewed changes, leaving other rows and old icon pixels until replacement', () => {
  const f = fixture(), ui = f.ui; ui.currentTab = 2;
  const untouched = ui.apps[1]; f.viewed = [{ id: 1, iconRev: 'new', category: '工具' }];
  ui.onPageShow(); assert.equal(f.scans, 0); f.flushResume(); assert.equal(f.scans, 1); assert.equal(ui.apps.length, 2);
  assert.equal(ui.apps[1], untouched); assert.equal(ui.apps[0].category, '工具');
  assert.equal(ui.updateCatalog[0].iconRev, 'new'); assert.equal(f.icons.length, 1);
  assert.equal(ui.appIcons[0].pixels, 'original pixels'); assert.equal(ui.catalogPage, 4);
  const apps = ui.apps; f.viewed = [{ ...ui.apps[0] }]; ui.onPageShow(); f.flushResume();
  assert.equal(ui.apps, apps, 'unchanged detail data must not replace list state');
});
test('rapid background transitions cancel stale resume maintenance and preserve the visible list', () => {
  const f = fixture(), ui = f.ui, apps = ui.apps;
  ui.currentTab = 2;
  ui.onPageShow(); ui.onPageHide(); f.flushResume();
  assert.equal(f.scans, 0); assert.equal(ui.apps, apps);
  ui.onPageShow(); ui.onPageShow(); assert.equal(f.timers.size, 1);
  f.flushResume(); assert.equal(f.scans, 1);
});

test('rapid tab changes paint immediately but only the last visible tab runs automatic maintenance', () => {
  const f = fixture(), ui = f.ui, seen = []; ui.pageVisible = true;
  ui.loadJobs = () => seen.push('jobs'); ui.loadMyApps = () => seen.push('published');
  ui.loadUpdateCatalog = () => seen.push('catalog'); ui.recoverSigningIdentity = () => seen.push('identity');
  ui.checkDevice = async () => seen.push('device');
  ui.onTabChanged(2); assert.equal(ui.currentTab, 2); assert.deepEqual(seen, []);
  ui.onTabChanged(3); ui.onTabChanged(2); assert.equal(f.timers.size, 1);
  f.flushResume(); assert.deepEqual(seen, ['jobs', 'published', 'catalog']); assert.equal(f.scans, 1);
  ui.onTabChanged(3); ui.onPageHide(); f.flushResume(); assert(!seen.includes('identity'));
});
test('automatic refresh retains published rows throughout a delayed request and does not replace identical data', async () => {
  const f = fixture(), ui = f.ui, before = ui.myApps;
  let resolve; f.myAppsFetch = () => new Promise(done => { resolve = done; });
  const refresh = ui.loadMyApps();
  assert.equal(ui.myApps, before); assert.equal(ui.myAppsBusy, true);
  assert.equal(ui.myAppsRefreshing, false, 'background checks must not display transient loading UI');
  resolve(JSON.parse(JSON.stringify(before))); await refresh;
  assert.equal(ui.myApps, before); assert.equal(ui.myAppsBusy, false);
});
test('manual refresh joins a background request and clears its fixed-position progress when that request finishes', async () => {
  const f = fixture(), ui = f.ui;
  let resolve; f.myAppsFetch = () => new Promise(done => { resolve = done; });
  const background = ui.loadMyApps(); await ui.loadMyApps(true);
  assert.equal(f.myAppsCalls, 1); assert.equal(ui.myAppsRefreshing, true);
  resolve([{ id: 2 }]); await background;
  assert.equal(ui.myApps[0].id, 2); assert.equal(ui.myAppsRefreshing, false);
});
test('empty publication is confirmed only after successful loading; a failed refresh keeps previous rows and remains retryable', async () => {
  const f = fixture(), ui = f.ui, before = ui.myApps;
  ui.myAppsLoaded = false; f.myAppsFetch = async () => { throw Error('network unavailable'); };
  await ui.loadMyApps(true);
  assert.equal(ui.myApps, before); assert.equal(ui.myAppsLoaded, false);
  assert.equal(ui.myAppsMessage, 'network unavailable'); assert.equal(ui.myAppsBusy, false);
  assert.equal(ui.myAppsRefreshing, false);
  f.myAppsFetch = async () => []; await ui.loadMyApps();
  assert.equal(ui.myApps.length, 0); assert.equal(ui.myAppsLoaded, true); assert.equal(ui.myAppsMessage, '');
});
test('installed information closes material popups before returning to Management', () => {
  const detail = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/InstalledDetail.ets'), 'utf8');
  const start = detail.indexOf('  private back():void{');
  const back = detail.slice(start, detail.indexOf('\n  }', start) + 4);
  let timer, routed;
  const box = { StorePageMotion: { prepare() {} }, setTimeout: fn => { timer = fn; return 1; }, router: { back: args => {
    assert.equal(ui.headerVisible, false); routed = args;
  } } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${back} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { disposed: false, returning: false, headerVisible: true });
  ui.back(); assert.equal(ui.headerVisible, false); assert.equal(routed, undefined);
  timer(); assert.equal(routed.url, 'pages/Index');
});
for (const file of ['Detail', 'LocalInstall', 'PackageTools']) {
  test(file + ' closes the shared material once before routing, even if popup and page both receive Back', () => {
    const detail = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/' + file + '.ets'), 'utf8');
    const start = detail.search(/^  private back\(/m);
    assert.ok(start >= 0);
    const back = detail.slice(start, detail.indexOf('\n  }', start) + 4);
    const timers = []; let routed = 0;
    const box = { StorePageMotion: { prepare() {} }, setTimeout: fn => { timers.push(fn); return timers.length; }, router: { back: () => {
      assert.equal(ui.headerVisible, false); routed++;
    } } };
    vm.runInNewContext(ts.transpileModule('class Page { ' + back + ' };globalThis.Page=Page;', {
      compilerOptions: { target: ts.ScriptTarget.ES2020 }
    }).outputText, box);
    const ui = new box.Page(); Object.assign(ui, { disposed: false, returning: false, headerVisible: true });
    ui.back(); ui.back(); assert.equal(timers.length, 1); assert.equal(ui.headerVisible, false);
    assert.equal(routed, 0); timers[0](); assert.equal(routed, 1);
  });
}
for (const file of ['LocalInstall', 'PackageTools']) {
  test(file + ' retains the page receiver when the shared header invokes its tools builder', () => {
    const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/' + file + '.ets'), 'utf8');
    // A bare BuilderParam method acquires StorePageHeader as its receiver on
    // device. Its popup Back/plus callbacks then call nonexistent page methods.
    const wrapper = source.match(/tools:\s*(\(\)\s*=>\s*\{\s*this\.headerTools\(\);?\s*\})/);
    assert.ok(wrapper, 'capture the page receiver before passing the tools builder');
    let received;
    const box = {};
    vm.runInNewContext('globalThis.make = function(){ return ' + wrapper[1] + '; };', box);
    const page = { headerTools() { received = this; } };
    const tools = box.make.call(page);
    tools.call({ title: 'shared header' });
    assert.equal(received, page);
  });
}
