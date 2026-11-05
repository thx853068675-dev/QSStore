const { DeviceInstallTarget } = require('./load_ets.cjs').loadEts('jobs/DeviceInstallTarget');
const { loadEts } = require('./load_ets.cjs');
const lookupRelease = loadEts('data/ReleaseInfo');
const { CatalogLookup } = loadEts('data/CatalogLookup', { './ReleaseInfo': lookupRelease,
  './CatalogApp': loadEts('data/CatalogApp', { './ReleaseInfo': lookupRelease }) });
const { InstallJob } = loadEts('jobs/InstallJob');
const ReleaseUpdate = require('./release_update_fixture.cjs').releaseUpdate({ INSTALLED: 'INSTALLED' });
const { CatalogPackageVariant } = loadEts('data/CatalogPackageVariant');
const { CatalogInstallTarget } = loadEts('jobs/CatalogInstallTarget', {
  '../data/CatalogPackageVariant': { CatalogPackageVariant }, './ReleaseUpdate': { ReleaseUpdate },
  './InstallJob': { InstallJob, InstallStage: { INSTALLED: 'INSTALLED' } }
});
const { releaseDisplayVersion } = loadEts('data/DisplayVersion');
const { InstalledVersionDisplay } = loadEts('data/InstalledVersionDisplay', {
  './DisplayVersion': loadEts('data/DisplayVersion'), '../jobs/ReleaseUpdate': { ReleaseUpdate }
});
// Production update matching and pagination, without a device or network.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const names = ['catalogLookup', 'displayInstalledVersion', 'installedAssets', 'latestAssets', 'assetForBundle', 'catalogTarget', 'updateApps', 'catalogApp', 'catalogForJob', 'renewalAppId', 'openJobDetails', 'openInstalledInformation', 'loadUpdateCatalog', 'syncDiscoveryCategories',
  'catalogBundleName', 'catalogInstallable', 'installedVersionOf', 'installedBundleOf', 'installedJobFor', 'updateForApp',
  'installFromCatalog', 'checkInstalledUpdates', 'updateFor', 'allInstalledJobs', 'currentInstalledView',
  'recentInstalledJobs', 'startUpdate', 'updatableInstalledJobs', 'hasInstalledUpdates', 'updateAllInstalled', 'managementInstalledJobs', 'versionLabel', 'installedActionLabel', 'performInstalledAction', 'syncDetectedInstalled', 'jobIcon'];
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
  const f = { requests: [], routes: [], downloads: [], enqueues: [], recognitions: [], actual: -1, official: new Set(), disabled: new Set(),
    fetch: async () => ({ items: [], pageSize: 100, total: 0 }) };
  const store = { enqueue: async (...args) => {
    f.enqueues.push(args); f.lastJob = { id: 'online', appId: args[0], stage: 'QUEUED' };
    return f.lastJob;
  } };
  const sandbox = { FollowingRegistry:{entries:()=>[]},ManagementSort:require('./load_ets.cjs').loadEts('data/ManagementSort').ManagementSort, MultiDeviceTargets:{snapshots:()=>['']}, MultiDeviceInstall:{enqueue:async(_store,job)=>[job]}, DeviceInstallTarget, CatalogInstallTarget, CatalogPackageVariant, CatalogLookup, InstallJob, ReleaseUpdate, releaseDisplayVersion, InstalledVersionDisplay, Index: { TAB_MINE: 3 }, InstalledInspection:{selection:(job,title,appId,displayReleaseLabel,displayReleaseUpdateTime)=>({...job,title,appId,displayReleaseLabel,displayReleaseUpdateTime,displayReleaseVersionCode:job.versionCode})}, ReleaseChannelRegistry: { apply: app => app, restore: async () => {}, refreshTargets: async () => {} }, VersionCacheEntry: class {},
    StoreClient: class { listApps(...args) { f.requests.push(args); return f.fetch(...args); } },
    InstallStage: { QUEUED: 'QUEUED', DOWNLOADING: 'DOWNLOADING', WAITING_NETWORK: 'WAITING_NETWORK',
      INSTALLED: 'INSTALLED' },
    UpdateTarget: class {}, LocalBundles: { isSelfBundle: () => false, isKnown: v => v !== -1,
      installedVersion: () => f.actual, liveInstalledVersion: () => f.actual,
      installedVersionName: () => f.versionName ?? '' },
    InstalledAppRegistry: { isAppGallery: bundle => f.official.has(bundle), installationTime: () => f.updateTime ?? 0, signingIdentity: () => f.signingIdentity, observedAt: () => 0, version: () => f.actual, versionName: () => f.observedName ?? '' },
    StorePageMotion: { pushUrl: value => f.routes.push(value) }, getContext: () => ({}),
    UpdatePolicy: { disabled: bundle => f.disabled.has(bundle) },
    InstallDeviceCompatibility: { confirm: async () => true, confirmedFingerprint: () => '' },
    errorText: e => e.message, JobStore: { open: async () => { if (f.storeWait) await f.storeWait; return store; } },
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
    enqueuingAppIds: [], signedIn: true, updatePolicyReady: true, taskPending: () => false, loadJobs: async () => {},
    installedDisplay: { get: () => f.actual >= 0 ? { version: f.actual, versionName: f.versionName ?? f.observedName ?? '' } : undefined }, storeInstalled: [], deviceInstalled: [], localIcons: [], pendingJobs: [], installedVersions: new Map(), updates: [], activeJobId: '',
    syncDetectedInstalled() {}, refreshCatalogInstallState(rescan, added) {
      f.recognitions.push({ rescan, added }); this.checkInstalledUpdates();
    }, jobRunning: () => false,
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

test('AppGallery Rock Kingdom is not the installed MiHoYo launcher despite their real bundle collision', () => {
  const f = fixture(), ui = f.ui, bundle = 'com.nrc.huawei';
  const launcher = app(73, bundle, 3002000);
  Object.assign(launcher, { displayName: '米哈游启动器', repo: 'muleos/MiHoYoLauncher' });
  launcher.latestAsset.versionName = '3.2.0';
  f.actual = 111112; f.versionName = '1.111.0.112'; f.official.add(bundle);
  ui.apps = [launcher]; ui.updateCatalog = [launcher]; ui.updateCatalogReady = true;
  const device = { ...local(), id: 'device-' + bundle, bundleName: bundle,
    sourceUrl: 'device', assetName: '洛克王国：世界', versionCode: 111112,
    versionName: '1.111.0.112' };
  ui.installedJobs = []; ui.deviceInstalled = [device];
  delete ui.syncDetectedInstalled;
  ui.syncDetectedInstalled(); ui.checkInstalledUpdates();
  assert.equal(ui.storeInstalled.length, 0, 'release AppGallery installs are never synthetic store receipts');
  assert.equal(ui.allInstalledJobs().length, 0, 'official release apps are outside the sideload inventory');
  assert.equal(ui.catalogForJob(device), undefined);
  assert.equal(ui.installedVersionOf(73), 0, 'Discover sees the launcher as not installed');
  assert.equal(ui.installedBundleOf(73), ''); assert.equal(ui.installedJobFor(73), undefined);
  assert.equal(ui.updateForApp(73), undefined); assert.equal(ui.updates.length, 0);
  assert.equal(ui.managementInstalledJobs(false).length, 0);
  assert.equal(ui.managementInstalledJobs(true).length, 0);
  assert.equal(ui.catalogInstallable(73), true, 'the real launcher remains a selectable download');
});

test('old store receipts cannot revive an AppGallery replacement or borrow a launcher icon', () => {
  const f = fixture(), ui = f.ui, bundle = 'com.nrc.huawei';
  f.actual = 111112; f.official.add(bundle);
  const launcher = app(73, bundle, 3002000);
  ui.apps = [launcher]; ui.updateCatalog = [launcher]; ui.updateCatalogReady = true;
  const history = { ...local(), appId: 73, bundleName: bundle, versionCode: 3000000,
    assetName: 'MiHoYoLauncher.hap', sourceUrl: 'https://example.com/launcher.hap' };
  const synthetic = { ...history, id: 'store-73-' + bundle, versionCode: 111112 };
  ui.installedJobs = [history]; ui.storeInstalled = [synthetic];
  ui.managedIconFor = () => { throw Error('an official install must not request launcher pixels'); };
  const actualPixels = { app: '洛克王国：世界' };
  ui.localIcons = [{ jobId: 'device-' + bundle, pixels: actualPixels }]; delete ui.jobIcon;
  assert.equal(ui.catalogForJob(history), undefined);
  assert.equal(ui.jobIcon(history), actualPixels, 'an explicit app information view still uses device pixels');
  assert.equal(ui.allInstalledJobs().length, 0); ui.checkInstalledUpdates();
  assert.equal(ui.updates.length, 0); assert.equal(ui.installedVersionOf(73), 0);
  delete ui.syncDetectedInstalled; ui.syncDetectedInstalled();
  assert.equal(ui.storeInstalled.length, 0, 'a rescan purges stale synthetic association');
  assert.equal(history.appId, 73); assert.equal(history.versionCode, 3000000,
    'guarded presentation never rewrites the historical installation receipt');
  f.official.delete(bundle);
  assert.equal(ui.jobIcon(history), actualPixels,
    'a verified installed icon also wins over catalog fallback for genuine debug sideloads');
});

test('the same bundle becomes associable again after a verified debug sideload replaces AppGallery', () => {
  const f = fixture(), ui = f.ui, bundle = 'com.nrc.huawei', launcher = app(73, bundle, 3002000);
  f.actual = 3000000; f.official.add(bundle);
  ui.installedJobs = []; ui.apps = [launcher]; ui.updateCatalog = [launcher]; ui.updateCatalogReady = true;
  delete ui.syncDetectedInstalled; ui.syncDetectedInstalled(); assert.equal(ui.storeInstalled.length, 0);
  f.official.delete(bundle); ui.syncDetectedInstalled(); ui.checkInstalledUpdates();
  assert.equal(ui.storeInstalled.length, 1); assert.equal(ui.storeInstalled[0].appId, 73);
  assert.equal(ui.catalogForJob(ui.storeInstalled[0]).id, 73);
  assert.equal(ui.installedVersionOf(73), 3000000); assert.equal(ui.updateForApp(73).versionCode, 3002000);
  assert.equal(ui.managementInstalledJobs(false).length, 1);
  assert.equal(ui.managementInstalledJobs(true).length, 0);
  f.actual = 3002000; ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(73), undefined); assert.equal(ui.updates.length, 0);
});

test('automatic inventory association refuses duplicate-repository bundle collisions in either catalog order', () => {
  for (const rows of [[app(7), app(8)], [app(8), app(7)]]) {
    const f = fixture(), ui = f.ui; f.actual = 1;
    ui.apps = rows; ui.updateCatalog = rows; ui.updateCatalogReady = true;
    const external = local(); ui.installedJobs = []; ui.deviceInstalled = [external];
    delete ui.syncDetectedInstalled; ui.syncDetectedInstalled(); ui.checkInstalledUpdates();
    assert.equal(ui.storeInstalled.length, 0, 'automatic linking cannot fabricate a pinned source from row order');
    assert.equal(ui.catalogForJob(external), undefined); assert.equal(ui.updates.length, 0);
    assert.equal(ui.managementInstalledJobs(false).length, 0);
    assert.equal(ui.managementInstalledJobs(true).length, 1, 'ambiguous sources remain local sideloads');
  }
});

test('unknown legacy provenance preserves a unique external sideload association without changing history', () => {
  const f = fixture(), ui = f.ui; f.actual = 1;
  ui.apps = [app()]; ui.updateCatalog = ui.apps; ui.updateCatalogReady = true;
  const before = JSON.stringify(ui.installedJobs);
  delete ui.syncDetectedInstalled; ui.syncDetectedInstalled(); ui.checkInstalledUpdates();
  assert.equal(ui.storeInstalled.length, 1); assert.equal(ui.catalogForJob(ui.installedJobs[0]).id, 7);
  assert.equal(ui.updateForApp(7).versionCode, 2);
  assert.equal(ui.managementInstalledJobs(false).length, 1);
  assert.equal(ui.managementInstalledJobs(true).length, 0);
  assert.equal(JSON.stringify(ui.installedJobs), before);
});

test('120391 stops updating immediately after the first upgrade despite an old-tag receipt without hashes', () => {
  const f=fixture(), bundle='com.tonghongxiang.quietstart', latest=app(1,bundle,120391);
  Object.assign(latest.latestAsset,{versionName:'1.2.2-beta',releaseName:'轻启 1.2.2-beta（120391）',
    releaseTag:'v1.2.2-beta-120391'});
  f.ui.installedJobs=[{...local(),appId:1,bundleName:bundle,versionCode:120391,versionName:'1.2.2-beta',
    releaseTag:'v1.2.2-beta-120375',releaseName:'轻启 1.2.2-beta（120375）'}];
  f.ui.apps=[latest];f.ui.updateCatalog=[latest];f.ui.updateCatalogReady=true;f.observedName='1.2.2-beta';
  f.actual=120375;f.ui.checkInstalledUpdates();assert.equal(f.ui.updates.length,1);
  f.actual=120391;f.ui.checkInstalledUpdates();
  assert.equal(f.ui.installedVersionOf(1),120391);
  assert.equal(f.ui.updates.length,0);assert.equal(f.ui.updateForApp(1),undefined);
  assert.equal(f.ui.updatableInstalledJobs().length,0);
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
  assert.equal(f.recognitions.length, 0, 'unchanged background metadata does not repeat the device scan');
  assert.equal(f.ui.updateCatalogBusy, false); assert.equal(f.ui.updateCatalogError, '');
});

test('background metadata changes reuse confirmed versions and only newly introduced bundles are probed', async () => {
  const f = fixture(); f.ui.updateCatalogReady = true; f.ui.updateCatalog = [app()];
  f.fetch = async () => ({ items: [app(7, 'com.example.app', 3)], total: 1, pageSize: 100 });
  await f.ui.loadUpdateCatalog();
  assert.equal(f.ui.updateFor('com.example.app').versionCode, 3);
  assert.equal(f.recognitions.length, 0);
  f.fetch = async () => ({ items: [app(7, 'com.example.app', 3), app(8, 'com.example.new')], total: 2, pageSize: 100 });
  await f.ui.loadUpdateCatalog();
  assert.equal(f.recognitions.length, 1);
  assert.deepEqual(Array.from(f.recognitions[0].added, a => a.id), [8]);
  assert.equal(f.recognitions[0].rescan, false);
});
test('linked cards open store details; local-only cards keep information on the separate swipe action', async () => {
  const f = fixture(); const { ui } = f; ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes[0].url,'pages/Detail');assert.equal(f.routes[0].params.id,7);
  ui.openInstalledInformation(ui.installedJobs[0]); assert.equal(f.routes[1].url,'pages/InstalledDetail');assert.equal(JSON.parse(f.routes[1].params.selection).appId,7);
  ui.checkInstalledUpdates(); await ui.startUpdate(ui.installedJobs[0], ui.updates[0]);
  assert.equal(f.enqueues[0][0], 7); assert.equal(f.enqueues[0][2], app().latestAsset.url);
  assert.equal(f.downloads.length, 1); assert.equal(f.continued.appId, 7);
  ui.updateCatalog = []; ui.openJobDetails(ui.installedJobs[0]); assert.equal(f.routes.length, 2);
  ui.openInstalledInformation(ui.installedJobs[0]); assert.equal(f.routes.length,3);assert.equal(JSON.parse(f.routes[2].params.selection).appId,0);
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

test('Harmony X filename-changing multi-package releases give Discover and Management the same update', () => {
  const f=fixture(),ui=f.ui,latest=app(23,'com.haohaoai0.harmonx',16);
  latest.updatedAt='200';latest.latestAsset.name='HarmonyX-v2.4.2-unsigned.hap';
  latest.latestAsset.versionName='2.4.2';latest.latestAsset.releaseTag='v2.4.2';
  const archive={...latest.latestAsset,name:'HarmonyX-v2.4.2-unsigned.app.zip / entry-default.hap'};
  latest.latestAssets=[latest.latestAsset,archive];
  const old={...local(),appId:23,bundleName:latest.latestAsset.bundleName,
    assetName:'HarmonyX-v2.4.0-unsigned.hap',versionCode:14,versionName:'2.4.0'};
  ui.installedJobs=[old];f.actual=14;f.versionName='2.4.0';
  ui.apps=[latest];ui.updateCatalog=[{...latest,updatedAt:'100',latestAsset:{...latest.latestAsset,versionCode:14}}];
  ui.updateCatalogReady=true;ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(23).assetName,latest.latestAsset.name);
  assert.equal(ui.updateFor(old.bundleName).assetName,latest.latestAsset.name);
  assert.equal(ui.installedActionLabel(old),'更新');
  f.actual=16;f.versionName='2.4.2';ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(23),undefined);assert.equal(ui.installedActionLabel(old),'打开');
});

test('same-code LNGA release updates are shared and enqueue a durable explicit replacement intent',async()=>{
  const f=fixture(),ui=f.ui,latest=app(26,'com.example.app',1000000);
  latest.latestAsset.versionName='1.0.0';latest.latestAsset.releaseTag='1.2.6';
  latest.latestAsset.sha256='b'.repeat(64);
  const old={...local(),appId:26,assetName:'app.hap',versionCode:1000000,versionName:'1.0.0',
    releaseTag:'1.2.5',expectedSha256:'a'.repeat(64),stageHistory:[{stage:'INSTALLED',at:100}]};
  f.actual=1000000;f.versionName='1.0.0';ui.installedJobs=[old];ui.apps=[latest];
  ui.checkInstalledUpdates();assert.equal(ui.installedActionLabel(old),'更新');
  assert.equal(ui.updateForApp(26).assetSha256,latest.latestAsset.sha256);
  await ui.installFromCatalog(latest);
  assert.equal(f.enqueues[0][8],'1.2.6');assert.equal(f.enqueues[0][10],true);
  ui.installedJobs=[{...old,releaseTag:'1.2.6',expectedSha256:'b'.repeat(64),
    stageHistory:[{stage:'INSTALLED',at:200}]}];f.updateTime=200;ui.checkInstalledUpdates();
  assert.equal(ui.installedActionLabel(ui.installedJobs[0]),'打开');
  assert.equal(ui.updateForApp(26),undefined);assert.equal(ui.versionLabel(ui.installedJobs[0]),'1.2.6');
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

test('Management sorts by latest release time and retains distinct packages from one repository', () => {
  const { ui } = fixture();
  const a = { ...local(), id: 'a', bundleName: 'com.example.a' };
  const b = { ...local(), id: 'b', bundleName: 'com.example.b', appId: 12 };
  const c = { ...local(), id: 'c', bundleName: 'com.example.c', appId: 12 };
  ui.allInstalledJobs = () => [a, b, c];
  const multiPackage = app(12, b.bundleName);
  multiPackage.latestAssets = [multiPackage.latestAsset, app(12, c.bundleName).latestAsset];
  ui.managementSort='updated';ui.managementDirection='desc';
  multiPackage.latestPublishedAt='2026-10-23T00:00:00Z';
  ui.updateCatalog = [{...app(10, a.bundleName),latestPublishedAt:'2026-10-22T00:00:00Z'}, multiPackage];
  ui.updateCatalogReady = true; ui.pendingJobs = []; ui.installedLocalOnly = false;
  ui.updates = [{ bundleName: c.bundleName }];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(), job => job.id), ['b', 'c', 'a']);
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

test('pending policy restore and stopped bundles hide every automatic update action, then restore without changing receipts', async () => {
  const f = fixture(), ui = f.ui, bundle = local().bundleName;
  ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  const receipt = JSON.stringify(ui.installedJobs);
  ui.updatePolicyReady = false; ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(7), undefined); assert.equal(ui.updateFor(bundle), undefined);
  assert.equal(ui.hasInstalledUpdates(), false); assert.equal(ui.updatableInstalledJobs().length, 0);
  ui.updatePolicyReady = true; ui.checkInstalledUpdates();
  assert.equal(ui.hasInstalledUpdates(), true);
  f.disabled.add(bundle);
  assert.equal(ui.updateFor(bundle), undefined, 'a stale cached update map cannot bypass the saved policy');
  assert.equal(ui.hasInstalledUpdates(), false);
  await ui.startUpdate(ui.installedJobs[0], ui.updates[0]); assert.equal(f.enqueues.length, 0);
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  assert.equal(ui.updateForApp(7), undefined); assert.equal(ui.installedActionLabel(ui.installedJobs[0]), '打开');
  await ui.performInstalledAction(ui.installedJobs[0]); assert.equal(f.opened.bundleName, bundle);
  await ui.updateAllInstalled(); assert.equal(f.enqueues.length, 0);
  f.disabled.delete(bundle); ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(7).versionCode, 2); assert.equal(ui.installedActionLabel(ui.installedJobs[0]), '更新');
  assert.equal(ui.hasInstalledUpdates(), true);
  assert.equal(JSON.stringify(ui.installedJobs), receipt);
});

test('stopping one bundle preserves another package from the same repository without changing explicit time sorting', () => {
  const f = fixture(), ui = f.ui;
  const a = { ...local(), id: 'a', bundleName: 'com.example.a', appId: 12 };
  const b = { ...local(), id: 'b', bundleName: 'com.example.b', appId: 12 };
  ui.allInstalledJobs = () => [a, b];
  const multi = app(12, a.bundleName); multi.latestAssets = [multi.latestAsset, app(12, b.bundleName).latestAsset];
  ui.updateCatalog = [multi]; ui.updateCatalogReady = true; ui.pendingJobs = [];
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 2);
  f.disabled.add(a.bundleName); ui.checkInstalledUpdates();
  assert.equal(ui.updateFor(a.bundleName), undefined); assert.equal(ui.updateFor(b.bundleName).appId, 12);
  assert.deepEqual(Array.from(ui.managementInstalledJobs(false), job => job.id), ['a', 'b']);
});

test('a policy saved while the journal opens prevents both known and UNKNOWN installed updates from enqueueing', async () => {
  for (const actual of [1, -1]) {
    const f = fixture(), ui = f.ui; f.actual = actual;
    ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
    let release; f.storeWait = new Promise(done => release = done);
    const pending = ui.startUpdate(ui.installedJobs[0], { appId: 7, bundleName: local().bundleName, assetName: 'app.hap' });
    await new Promise(setImmediate); f.disabled.add(local().bundleName); release(); await pending;
    assert.equal(f.enqueues.length, 0); assert.equal(f.downloads.length, 0);
    assert.equal(ui.enqueuingAppIds.length, 0);
  }
});

test('confirmed external uninstall still permits a fresh Discover installation under the retained policy', async () => {
  const f = fixture(), ui = f.ui; f.actual = 0; f.disabled.add(local().bundleName);
  ui.updateCatalog = [app()]; ui.updateCatalogReady = true;
  await ui.installFromCatalog(app()); assert.equal(f.enqueues.length, 1);
});

test('bulk update rechecks saved policies each iteration and leaves an already accepted package running', async () => {
  const f = fixture(), ui = f.ui;
  const installed = ['a', 'b'].map((key, i) => ({ ...local(), id: key, bundleName: 'com.example.' + key, appId: i + 1 }));
  ui.allInstalledJobs = () => installed; ui.updateCatalog = installed.map((job, i) => app(i + 1, job.bundleName));
  ui.updateCatalogReady = true;
  let release; const queued = [];
  ui.startUpdate = async job => { queued.push(job.id); if (job.id === 'a') await new Promise(done => release = done); };
  const work = ui.updateAllInstalled(); await new Promise(setImmediate);
  f.disabled.add(installed[0].bundleName); f.disabled.add(installed[1].bundleName);
  release(); await work;
  assert.deepEqual(queued, ['a']); assert.equal(ui.bulkUpdating, false);
});


test('category strip uses the complete published catalog, not a searched page, and removes empty categories', () => {
  const f = fixture(), ui = f.ui; ui.activeQuery = 'query'; ui.apps = [{category: 'searched only'}];
  ui.updateCatalogReady = true; ui.updateCatalog = [{category: '工具'}, {category: '影音'}, {category: '工具'}, {category: '  '}];
  ui.syncDiscoveryCategories(); assert.deepEqual(Array.from(ui.discoveryCategories).sort(), ['工具', '影音'].sort());
  const same = ui.discoveryCategories; ui.syncDiscoveryCategories(); assert.equal(ui.discoveryCategories, same);
  ui.updateCatalog = [{category: '影音'}]; ui.syncDiscoveryCategories(); assert.deepEqual(Array.from(ui.discoveryCategories), ['影音']);
});
