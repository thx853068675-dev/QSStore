// Production update matching and pagination, without a device or network.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const names = ['updateApps', 'catalogApp', 'catalogForJob', 'openJobDetails', 'loadUpdateCatalog',
  'installedVersionOf', 'installedBundleOf', 'installedJobFor', 'updateForApp',
  'installFromCatalog', 'checkInstalledUpdates', 'updateFor', 'allInstalledJobs', 'currentInstalledView',
  'recentInstalledJobs', 'startUpdate', 'versionLabel'];
const methods = names.map(name => {
  const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
});
const code = ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;
function app(id = 7, bundleName = 'com.example.app', versionCode = 2) {
  return { id, displayName: '同名应用', latestAsset: { bundleName, versionCode,
    versionName: String(versionCode), name: 'app.hap', url: 'https://example.com/app.hap',
    sha256: 'a'.repeat(64), mirrorUrls: [] } };
}
function local() {
  return { id: 'local:hash', appId: 0, sourceUrl: 'local', bundleName: 'com.example.app',
    versionCode: 1, stage: 'INSTALLED', updatedAt: 1 };
}
function fixture() {
  const f = { requests: [], routes: [], downloads: [], enqueues: [], actual: -1,
    fetch: async () => ({ items: [], pageSize: 100, total: 0 }) };
  const store = { enqueue: async (...args) => {
    f.enqueues.push(args); f.lastJob = { id: 'online', appId: args[0], stage: 'QUEUED' };
    return f.lastJob;
  } };
  const sandbox = {
    StoreClient: class { listApps(...args) { f.requests.push(args); return f.fetch(...args); } },
    InstallStage: { QUEUED: 'QUEUED', DOWNLOADING: 'DOWNLOADING', WAITING_NETWORK: 'WAITING_NETWORK',
      INSTALLED: 'INSTALLED' },
    UpdateTarget: class {}, LocalBundles: { isKnown: v => v !== -1,
      installedVersion: () => f.actual, liveInstalledVersion: () => f.actual,
      installedVersionName: () => f.versionName ?? '' },
    router: { pushUrl: value => f.routes.push(value) }, getContext: () => ({}),
    errorText: e => e.message, JobStore: { open: async () => store },
    JobScheduler: { runDownload: async (_, __, job) => f.downloads.push(job) }
  };
  vm.runInNewContext(code, sandbox);
  f.ui = new sandbox.Page();
  Object.assign(f.ui, { apps: [], updateCatalog: [], updateCatalogReady: false,
    updateCatalogBusy: false, updateCatalogError: '', installedJobs: [local()],
    enqueuingAppIds: [], signedIn: true, taskPending: () => false, loadJobs: async () => {},
    storeInstalled: [], installedVersions: new Map(), updates: [], activeJobId: '',
    refreshCatalogInstallState() { this.checkInstalledUpdates(); }, jobRunning: () => false,
    forgetInstalledVersions() {}, drainInstallQueue() { f.downloads.push(f.lastJob); f.continued = f.lastJob; } });
  return f;
}
test('a local install gains an update after publication, without rewriting provenance', async () => {
  const { ui } = fixture(); const before = JSON.stringify(ui.installedJobs);
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  ui.checkInstalledUpdates();
  assert.equal(ui.updateFor('com.example.app').appId, 7);
  assert.equal(ui.installedVersionOf(7), 1);
  assert.equal(ui.installedJobFor(7).id, 'local:hash');
  assert.equal(JSON.stringify(ui.installedJobs), before);
});
test('only the exact nonempty bundle and a higher version qualify', () => {
  const { ui } = fixture(); ui.updateCatalogReady = true;
  for (const candidate of [app(7, 'com.other.app'), app(7, ''), app(7, 'com.example.app', 1), app(7, 'com.example.app', 0)]) {
    ui.updateCatalog = [candidate]; ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  }
});
test('newer actual device version suppresses a stale local record update', () => {
  const f = fixture(); f.actual = 3; f.ui.updateCatalog = [app()]; f.ui.updateCatalogReady = true;
  f.ui.checkInstalledUpdates(); assert.equal(f.ui.updates.length, 0);
});

test('self update shows the system version name and stops updating after the target build is installed', () => {
  const f = fixture(), { ui } = f;
  const original = { ...local(), bundleName: 'com.tonghongxiang.hapstore',
    versionCode: 2026092910, versionName: '0.4.45' };
  ui.installedJobs = [original];
  const latest = app(3, original.bundleName, 2026093015);
  latest.latestAsset.versionName = '0.4.48';
  ui.updateCatalog = [latest]; ui.updateCatalogReady = true;
  f.actual = 2026093012; f.versionName = '0.4.48';
  ui.checkInstalledUpdates();
  assert.equal(ui.allInstalledJobs()[0].versionName, '0.4.48');
  assert.equal(ui.versionLabel(ui.allInstalledJobs()[0]), '0.4.48');
  assert.equal(original.versionName, '0.4.45', 'historical records must remain unchanged');
  assert.equal(ui.updates.length, 1, 'a genuinely newer build of the same release can update');
  ui.installedVersions.set(3, 2026093012);
  f.actual = 2026093015;
  ui.checkInstalledUpdates();
  assert.equal(ui.updates.length, 0, 'stale records and display caches cannot keep self update visible');
});

test('a detected self install without a job version name never displays its numeric build code', () => {
  const f = fixture();
  f.actual = 2026093015; f.versionName = '0.4.48';
  const detected = { ...local(), bundleName: 'com.tonghongxiang.hapstore',
    versionCode: f.actual, versionName: '', assetName: '' };
  assert.equal(f.ui.versionLabel(detected), '0.4.48');
});
test('an unresolved offline catalog app can still begin installation', async () => {
  const f = fixture();
  f.ui.installedJobs = [];
  f.ui.apps = [app()];
  assert.equal(f.ui.installedVersionOf(7), -1);
  await f.ui.installFromCatalog(f.ui.apps[0]);
  assert.equal(f.enqueues.length, 1);
  assert.equal(f.downloads.length, 1);
  assert.equal(f.continued.id, 'online');
});
test('ambiguous local sources are not chosen automatically; an existing online source stays pinned', () => {
  const { ui } = fixture(); ui.updateCatalogReady = true; ui.updateCatalog = [app(8), app(7)];
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  ui.installedJobs[0].appId = 7; ui.checkInstalledUpdates();
  assert.equal(ui.updates[0].appId, 7);
  ui.updateCatalog = [app(8)]; ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
});
test('management fetches every page independently of Discover search, and coalesces overlapping checks', async () => {
  const f = fixture(); const { ui } = f;
  ui.apps = [app(999, 'search.result')]; ui.activeQuery = 'search';
  let release; const gate = new Promise(r => release = r);
  f.fetch = async page => { await gate; return page === 1 ? {
    items: Array.from({ length: 100 }, (_, i) => app(1000 + i, `other.${i}`)), total: 101, pageSize: 100
  } : { items: [app()], total: 101, pageSize: 100 }; };
  const work = ui.loadUpdateCatalog(); await ui.loadUpdateCatalog();
  assert.equal(f.requests.length, 1); release(); await work;
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[1][0], 2); assert.equal(f.requests[1][3], '');
  assert.equal(ui.apps[0].id, 999); assert.equal(ui.updates[0].appId, 7);
  ui.apps = []; ui.checkInstalledUpdates(); assert.equal(ui.updates[0].appId, 7);
});
test('failed pagination preserves the last complete catalog; retry and unpublishing remove stale updates', async () => {
  const f = fixture(); const { ui } = f;
  ui.updateCatalogReady = true; ui.updateCatalog = [app()]; ui.checkInstalledUpdates();
  f.fetch = async page => { if (page === 2) throw Error('offline');
    return { items: [app(8)], pageSize: 1, total: 2 }; };
  await ui.loadUpdateCatalog(); assert.match(ui.updateCatalogError, /offline/);
  assert.equal(ui.updateCatalog[0].id, 7); assert.equal(ui.updates[0].appId, 7);
  assert.equal(ui.updateCatalogBusy, false);
  f.fetch = async () => ({ items: [], pageSize: 100, total: 0 });
  await ui.loadUpdateCatalog(); assert.equal(ui.updates.length, 0); assert.equal(ui.updateCatalogError, '');
});
test('a nonadvancing page terminates with an error instead of looping', async () => {
  const f = fixture(); f.fetch = async () => ({ items: [], total: 200, pageSize: 100 });
  await f.ui.loadUpdateCatalog(); assert.equal(f.requests.length, 1);
  assert.match(f.ui.updateCatalogError, /分页/); assert.equal(f.ui.updateCatalogReady, false);
});
test('a linked local row opens its online detail and update enqueues the catalog asset', async () => {
  const f = fixture(); const { ui } = f; ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes[0].params.id, 7);
  ui.checkInstalledUpdates(); await ui.startUpdate(ui.installedJobs[0], ui.updates[0]);
  assert.equal(f.enqueues[0][0], 7); assert.equal(f.enqueues[0][2], app().latestAsset.url);
  assert.equal(f.downloads.length, 1); assert.equal(f.continued.appId, 7);
  ui.updateCatalog = []; ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes.length, 1);
});
test('after online update only one installed row remains while local history survives', () => {
  const { ui } = fixture(); const original = ui.installedJobs[0];
  ui.installedJobs = [{ ...original, id: 'online', appId: 7, versionCode: 2 }, original];
  ui.storeInstalled = [{ ...original, id: 'store-7' }]; ui.apps = [app()];
  assert.equal(ui.allInstalledJobs().length, 1); assert.equal(ui.allInstalledJobs()[0].id, 'online');
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0); assert.equal(ui.installedJobs.length, 2);
});

test('a partial Discover page cannot establish a unique source for a local install', () => {
  const { ui } = fixture(); ui.apps = [app()];
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  assert.equal(ui.installedVersionOf(7), 1);
});
test('a truncated final page is not committed as a complete catalog', async () => {
  const f = fixture(); f.fetch = async () => ({ items: [app()], total: 2, pageSize: 100 });
  await f.ui.loadUpdateCatalog(); assert.equal(f.ui.updateCatalogReady, false);
  assert.match(f.ui.updateCatalogError, /目录已变化/);
});

test('Discover enqueues the current update target, not the stale card closure', async () => {
  const f = fixture(), { ui } = f;
  const stale = app(7, 'com.example.app', 1);
  stale.latestAsset.name = 'old.hap'; stale.latestAsset.url = 'https://example.com/old.hap';
  ui.apps = [stale]; ui.updateCatalogReady = true; ui.updateCatalog = [app()];
  await ui.installFromCatalog(stale);
  assert.equal(f.enqueues[0][1], 'app.hap');
  assert.equal(f.enqueues[0][2], 'https://example.com/app.hap');
  assert.equal(f.downloads.length, 1); assert.equal(f.continued.appId, 7);
  assert.equal(ui.enqueuingAppIds.length, 0);
});
test('a stale Discover update click cannot reinstall a version already installed', async () => {
  const f = fixture(), { ui } = f;
  ui.apps = [app()]; f.actual = 2;
  await ui.installFromCatalog(app(7, 'com.example.app', 1));
  assert.equal(f.enqueues.length, 0); assert.equal(f.downloads.length, 0);
});
