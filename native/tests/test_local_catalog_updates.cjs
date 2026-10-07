// Production update matching and pagination, without a device or network.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const names = ['displayInstalledVersion', 'installedAssets', 'latestAssets', 'assetForBundle', 'updateApps', 'catalogApp', 'catalogForJob', 'renewalAppId', 'openJobDetails', 'loadUpdateCatalog', 'syncDiscoveryCategories',
  'catalogBundleName', 'catalogInstallable', 'installedVersionOf', 'installedBundleOf', 'installedJobFor', 'updateForApp',
  'installFromCatalog', 'checkInstalledUpdates', 'updateFor', 'allInstalledJobs', 'currentInstalledView',
  'recentInstalledJobs', 'startUpdate', 'updatableInstalledJobs', 'updateAllInstalled', 'managementInstalledJobs', 'versionLabel', 'installedActionLabel', 'performInstalledAction'];
const methods = names.map(name => {
  const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
});
const code = ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;
function app(id = 7, bundleName = 'com.example.app', versionCode = 2) {
  return { id, displayName: '同名应用', category: '工具', latestAsset: { bundleName, versionCode,
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
  const sandbox = { Index: { TAB_MINE: 3 }, InstalledInspection:{selection:(job,title,appId)=>({...job,title,appId})}, ReleaseChannelRegistry: { apply: app => app, restore: async () => {}, refreshTargets: async () => {} }, VersionCacheEntry: class {},
    StoreClient: class { listApps(...args) { f.requests.push(args); return f.fetch(...args); } },
    InstallStage: { QUEUED: 'QUEUED', DOWNLOADING: 'DOWNLOADING', WAITING_NETWORK: 'WAITING_NETWORK',
      INSTALLED: 'INSTALLED' },
    UpdateTarget: class {}, LocalBundles: { isSelfBundle: () => false, isKnown: v => v !== -1,
      installedVersion: () => f.actual, liveInstalledVersion: () => f.actual,
      installedVersionName: () => f.versionName ?? '' },
    InstalledAppRegistry: { observedAt: () => 0, version: () => f.actual, versionName: () => f.observedName ?? '' },
    StorePageMotion: { pushUrl: value => f.routes.push(value) }, getContext: () => ({}),
    errorText: e => e.message, JobStore: { open: async () => store },
    JobScheduler: { runDownload: async (_, __, job) => f.downloads.push(job) }
  };
  const identity = { exports: {}, require: () => ({ InstallStage: sandbox.InstallStage }) };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/CatalogInstallIdentity.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, identity);
  sandbox.CatalogInstallIdentity = identity.exports.CatalogInstallIdentity;
  vm.runInNewContext(code, sandbox);
  f.ui = new sandbox.Page();
  Object.assign(f.ui, { activeQuery: '', activeCategory: '', discoveryCategories: [], apps: [], updateCatalog: [], updateCatalogReady: false,
    renewalDeadline: () => 1800000000,
    updateCatalogBusy: false, updateCatalogError: '', installedJobs: [local()],
    enqueuingAppIds: [], signedIn: true, taskPending: () => false, loadJobs: async () => {},
    installedDisplay: { get: () => f.actual >= 0 ? { version: f.actual, versionName: f.versionName ?? f.observedName ?? '' } : undefined }, storeInstalled: [], installedVersions: new Map(), updates: [], activeJobId: '',
    refreshCatalogInstallState() { this.checkInstalledUpdates(); }, jobRunning: () => false,
    jobIcon:()=>undefined,jobTitle:()=> '同名应用',openInstalled(job) { f.opened = job; },
    syncManagementIcons() {}, drainInstallQueue() { f.downloads.push(f.lastJob); f.continued = f.lastJob; } });
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
test('Management displays the HDC-detected external update while preserving installation history', () => {
  const f = fixture(), old = { ...local(), versionCode: 110003, versionName: '1.1.0' };
  f.ui.installedJobs = [old];
  f.actual = 120101; f.observedName = '1.2.1-beta';
  const displayed = f.ui.allInstalledJobs()[0];
  assert.equal(displayed.versionCode, 120101);
  assert.equal(displayed.versionName, '1.2.1-beta');
  assert.equal(old.versionName, '1.1.0');
  assert.equal(old.versionCode, 110003);
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
test('an unchanged background update check keeps the existing catalog objects', async () => {
  const f = fixture(); const previous = [app()];
  f.ui.updateCatalog = previous; f.ui.updateCatalogReady = true;
  f.fetch = async () => ({ items: [app()], total: 1, pageSize: 100 });
  await f.ui.loadUpdateCatalog();
  assert.equal(f.ui.updateCatalog, previous); assert.equal(f.ui.updateCatalog[0], previous[0]);
  assert.equal(f.ui.updateCatalogBusy, false); assert.equal(f.ui.updateCatalogError, '');
});
test('installed local and linked rows open installed information; updates still enqueue the catalog asset', async () => {
  const f = fixture(); const { ui } = f; ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes[0].url,'pages/InstalledDetail');assert.equal(JSON.parse(f.routes[0].params.selection).appId,7);
  ui.checkInstalledUpdates(); await ui.startUpdate(ui.installedJobs[0], ui.updates[0]);
  assert.equal(f.enqueues[0][0], 7); assert.equal(f.enqueues[0][2], app().latestAsset.url);
  assert.equal(f.downloads.length, 1); assert.equal(f.continued.appId, 7);
  ui.updateCatalog = []; ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes.length, 2);assert.equal(JSON.parse(f.routes[1].params.selection).appId,0);
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


test('an alternate selected HAP is matched by its bundle and exact variant name in Management', () => {
  const f = fixture(), ui = f.ui;
  const alternate = { ...app().latestAsset, name: 'alternate.hap', bundleName: 'com.example.alternate', versionCode: 4 };
  const candidate = app(); candidate.latestAssets = [candidate.latestAsset, alternate];
  const installed = { ...local(), bundleName: alternate.bundleName, assetName: alternate.name };
  ui.installedJobs = [installed]; ui.updateCatalogReady = true; ui.updateCatalog = [candidate];
  ui.checkInstalledUpdates();
  const target = ui.updateFor(installed.bundleName);
  assert.equal(target.appId, candidate.id); assert.equal(target.assetName, 'alternate.hap');
  assert.equal(target.versionCode, 4); assert.equal(ui.catalogForJob(installed).id, candidate.id);
  candidate.latestAssets.unshift({ ...alternate, name: 'different-variant.hap' });
  ui.checkInstalledUpdates(); assert.equal(ui.updateFor(installed.bundleName).assetName, 'alternate.hap');
  installed.assetName = 'old-variant-name.hap';
  ui.checkInstalledUpdates(); assert.equal(ui.updateFor(installed.bundleName), undefined, 'ambiguous variants need explicit selection');
});

test('Management uses the shared update action and enqueues the exact matching HAP', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [app()]; ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  ui.checkInstalledUpdates();
  const job = ui.installedJobs[0];
  assert.equal(ui.installedActionLabel(job), '更新');
  await ui.performInstalledAction(job);
  assert.equal(f.enqueues.length, 1);
  assert.equal(f.enqueues[0][0], 7);
  assert.equal(f.enqueues[0][1], 'app.hap');
  assert.equal(f.opened, undefined);
});

test('Management opens instead of installing when the observed version is current or newer', async () => {
  for (const installed of [2, 3]) {
    const f = fixture(); f.actual = installed; f.ui.apps = [app()];
    f.ui.checkInstalledUpdates();
    assert.equal(f.ui.installedActionLabel(f.ui.installedJobs[0]), '打开');
    await f.ui.performInstalledAction(f.ui.installedJobs[0]);
    assert.equal(f.opened.bundleName, 'com.example.app');
    assert.equal(f.enqueues.length, 0);
  }
});

test('Management does not pick an ambiguous publication for an offline install', async () => {
  const f = fixture(); f.ui.updateCatalogReady = true; f.ui.updateCatalog = [app(7), app(8)];
  await f.ui.performInstalledAction(f.ui.installedJobs[0]);
  assert.equal(f.opened.bundleName, 'com.example.app');
  assert.equal(f.enqueues.length, 0);
});

test('Discover recovers an installed XHS identity while the catalog has no package metadata', () => {
  const f = fixture();
  f.ui.apps = [{ ...app(41), latestAsset: undefined }];
  f.ui.installedJobs = [{ ...local(), appId: 41, bundleName: 'com.hmos.collection',
    assetName: 'collection-1.21.0-unsigned.hap', versionCode: 1000022 }];
  assert.equal(f.ui.installedVersionOf(41), 1000022);
  assert.equal(f.ui.installedBundleOf(41), 'com.hmos.collection');
  assert.equal(f.ui.installedJobFor(41).appId, 41);
  assert.equal(f.ui.catalogForJob(f.ui.installedJobs[0]).id, 41, 'known online provenance stays in the store section');
  assert.equal(f.ui.catalogInstallable(41), false, 'history never invents a download target');
  f.actual = 0;
  assert.equal(f.ui.installedBundleOf(41), '', 'confirmed removal must defeat historical success');
});

test('a stale empty Discover row uses the current catalog package for installation', () => {
  const f = fixture(); f.ui.apps = [{ ...app(), latestAsset: undefined }];
  f.ui.updateCatalogReady = true; f.ui.updateCatalog = [app()];
  assert.equal(f.ui.catalogInstallable(7), true);
});

test('Management pins updates without disturbing stable order or the other bundle from the same repository', () => {
  const { ui } = fixture();
  const a = { ...local(), id: 'a', bundleName: 'com.example.a' };
  const b = { ...local(), id: 'b', bundleName: 'com.example.b', appId: 12 };
  const c = { ...local(), id: 'c', bundleName: 'com.example.c', appId: 12 };
  ui.allInstalledJobs = () => [a, b, c];
  ui.updateCatalog = [app(10, a.bundleName), app(12, b.bundleName), app(13, c.bundleName)];
  ui.updateCatalogReady = true; ui.pendingJobs = []; ui.installedLocalOnly = false;
  ui.updates = [{ bundleName: c.bundleName }];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(), job => job.id), ['c', 'a', 'b']);
  ui.pendingJobs = [{ appId: 12, bundleName: b.bundleName, catalogBundleName: b.bundleName }];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(), job => job.id), ['c', 'a']);
});
test('one-click update enqueues every eligible bundle, skips existing tasks and coalesces repeated clicks', async () => {
  const f = fixture(), ui = f.ui;
  const installed = ['a', 'b', 'c'].map((key, i) => ({ ...local(), id: key, bundleName: 'com.example.' + key, appId: i + 1 }));
  ui.allInstalledJobs = () => installed;
  ui.updateCatalog = installed.map((job, i) => app(i + 1, job.bundleName)); ui.updateCatalogReady = true;
  ui.taskPending = (_id, bundle) => bundle === installed[1].bundleName;
  let release; const enqueued = [];
  ui.startUpdate = async (job, target) => { enqueued.push(target.bundleName); if (job.id === 'a') await new Promise(resolve => { release = resolve; }); };
  ui.checkInstalledUpdates = () => { ui.updates = installed.map((job, i) => ({ bundleName: job.bundleName, appId: i + 1 })); };
  const first = ui.updateAllInstalled(); await new Promise(setImmediate);
  assert.equal(ui.bulkUpdating, true); await ui.updateAllInstalled();
  release(); await first;
  assert.deepEqual(enqueued, [installed[0].bundleName, installed[2].bundleName]);
  assert.equal(ui.bulkUpdating, false); assert.equal(ui.jobsError, '');
});
test('bulk enqueue retains failures while continuing other apps and requires login before any enqueue', async () => {
  const f = fixture(), ui = f.ui;
  const installed = [local(), { ...local(), id: 'two', bundleName: 'com.example.two' }];
  ui.allInstalledJobs = () => installed; ui.taskPending = () => false;
  ui.checkInstalledUpdates = () => { ui.updates = installed.map((job, i) => ({ bundleName: job.bundleName, appId: i + 1 })); };
  let calls = 0; ui.startUpdate = async () => { calls++; if (calls === 1) throw Error('来源暂不可用'); };
  await ui.updateAllInstalled(); assert.equal(calls, 2); assert.match(ui.jobsError, /来源暂不可用/);
  ui.signedIn = false; await ui.updateAllInstalled(); assert.equal(calls, 2); assert.match(ui.jobsError, /登录/);
});


test('category strip uses the complete published catalog, not a searched page, and removes empty categories', () => {
  const f = fixture(), ui = f.ui; ui.activeQuery = 'query'; ui.apps = [{category: 'searched only'}];
  ui.updateCatalogReady = true; ui.updateCatalog = [{category: '工具'}, {category: '影音'}, {category: '工具'}, {category: '  '}];
  ui.syncDiscoveryCategories(); assert.deepEqual(Array.from(ui.discoveryCategories).sort(), ['工具', '影音'].sort());
  const same = ui.discoveryCategories; ui.syncDiscoveryCategories(); assert.equal(ui.discoveryCategories, same);
  ui.updateCatalog = [{category: '影音'}]; ui.syncDiscoveryCategories(); assert.deepEqual(Array.from(ui.discoveryCategories), ['影音']);
});
