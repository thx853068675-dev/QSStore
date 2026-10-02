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
  const f = { viewed: [], icons: [], scans: 0 };
  const box = { StoreClient: class { static consumeViewedApps() { const rows = f.viewed; f.viewed = []; return rows; } },
    getContext: () => ({}) };
  vm.runInNewContext(ts.transpileModule(`class Index { static TAB_MANAGE = 2;
    ${['onPageShow', 'onPageHide', 'syncViewedCatalog'].map(method).join('\n')} }; globalThis.Page = Index;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  box.InstallConfirmation = { deactivate() {} }; box.InstallReconnect = { deactivate() {} };
  const ui = new box.Page(); Object.assign(ui, { pageVisible: false, topActionEpoch: 3,
    currentTab: 0, apps: [{ id: 1, iconRev: 'old' }, { id: 2, iconRev: 'same' }],
    updateCatalog: [{ id: 1, iconRev: 'old' }, { id: 2, iconRev: 'same' }],
    appIcons: [{ id: 1, rev: 'old', pixels: 'original pixels' }], catalogPage: 4,
    discoverShowTop: true, scrollOffset: 1234, activeQuery: 'saved search',
    observeReconnect() {}, observeInstallTasks() {}, drainInstallQueue() {},
    refreshCatalogInstallState() {}, reconcileInterruptedInstalls: async () => {}, reconcileStuckJobs() {},
    scanDeviceInstalled() { f.scans++; },
    loadApps() { throw Error('return must not restart paginated network loading'); },
    loadAppIcon(_client, app) { f.icons.push(app); } });
  f.ui = ui; return f;
}
test('return from detail preserves discovery pagination, scroll and icons, and renews native popup ownership', () => {
  const { ui } = fixture(); const apps = ui.apps, icons = ui.appIcons;
  ui.onPageShow(); assert.equal(ui.pageVisible, true); assert.equal(ui.topActionEpoch, 4);
  assert.equal(ui.apps, apps); assert.equal(ui.appIcons, icons); assert.equal(ui.catalogPage, 4);
  assert.equal(ui.scrollOffset, 1234); assert.equal(ui.discoverShowTop, true);
  ui.onPageHide(); assert.equal(ui.pageVisible, false);
  ui.onPageShow(); assert.equal(ui.topActionEpoch, 5); assert.equal(ui.discoverShowTop, true);
});
test('return to Management merges only viewed changes, leaving other rows and old icon pixels until replacement', () => {
  const f = fixture(), ui = f.ui; ui.currentTab = 2;
  const untouched = ui.apps[1]; f.viewed = [{ id: 1, iconRev: 'new', category: '工具' }];
  ui.onPageShow(); assert.equal(f.scans, 1); assert.equal(ui.apps.length, 2);
  assert.equal(ui.apps[1], untouched); assert.equal(ui.apps[0].category, '工具');
  assert.equal(ui.updateCatalog[0].iconRev, 'new'); assert.equal(f.icons.length, 1);
  assert.equal(ui.appIcons[0].pixels, 'original pixels'); assert.equal(ui.catalogPage, 4);
  const apps = ui.apps; f.viewed = [{ ...ui.apps[0] }]; ui.onPageShow();
  assert.equal(ui.apps, apps, 'unchanged detail data must not replace list state');
});
