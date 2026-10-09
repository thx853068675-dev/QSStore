const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const { CatalogLookup } = loadEts('data/CatalogLookup');
const { InstallJob } = loadEts('jobs/InstallJob');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const app = (id, bundle = 'com.test.app' + id, code = id) => ({ id,
  latestAsset: { bundleName: bundle, versionCode: code, name: 'app.hap', url: 'https://example.com/app.hap' } });
function method(name) {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'));
  assert(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function page(names, mocks = {}) {
  const box = { ...mocks };
  vm.runInNewContext(ts.transpileModule('class Page {' + names.map(method).join('\n') +
    '}; globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  return new box.Page();
}

test('one thousand installed source lookups reuse one catalog projection, including repeated warm frames', () => {
  const rows = Array.from({ length: 1000 }, (_, i) => app(i + 1)); let projections = 0;
  const ui = page(['catalogLookup', 'catalogApp', 'catalogForJob', 'updateApps'], {
    CatalogLookup, ReleaseChannelRegistry: { apply: row => { projections++; return row; } }
  });
  Object.assign(ui, { apps: rows, updateCatalog: rows, updateCatalogReady: true, releaseChannelRevision: 1 });
  const first = ui.updateApps();
  for (let frame = 0; frame < 10; frame++) {
    for (const row of rows) {
      assert.equal(ui.catalogApp(row.id), row);
      assert.equal(ui.catalogForJob({ appId: row.id, bundleName: row.latestAsset.bundleName }), row);
    }
    assert.equal(ui.updateApps(), first);
  }
  assert.equal(projections, 1000, 'lookup cost must not multiply applications by catalog size');
  ui.releaseChannelRevision++;
  assert.notEqual(ui.updateApps(), first); assert.equal(projections, 2000);
  const fresh = rows.slice(); fresh[0] = app(1, 'com.test.app1', 2000); ui.updateCatalog = fresh;
  assert.equal(ui.catalogApp(1).latestAsset.versionCode, 2000);
  assert.equal(ui.catalogForJob({ appId: 1, bundleName: 'com.test.app1' }).latestAsset.versionCode, 2000);
});

test('offline association preserves ambiguity, partial catalog rules and recorded online provenance', () => {
  const first = app(1, 'com.shared.app'), other = app(2, 'com.shared.app');
  let lookup = new CatalogLookup([first, other], [], true, 0, row => row);
  assert.equal(lookup.source(0, 'com.shared.app'), undefined);
  assert.equal(lookup.source(1, 'com.shared.app'), first);
  assert.equal(lookup.source(999, 'com.shared.app'), undefined);
  assert.equal(lookup.source(1, ''), undefined);
  lookup = new CatalogLookup([first], [], false, 0, row => row);
  assert.equal(lookup.source(0, 'com.shared.app'), undefined);
  assert.equal(lookup.source(1, 'com.shared.app'), first);
  const pending = { id: 3, latestAssets: [] };
  lookup = new CatalogLookup([pending], [], true, 0, row => row);
  assert.equal(lookup.source(3, 'com.waiting.app'), pending);
});

test('multi-HAP and empty preview channels retain installed identity without inventing an install target', () => {
  const primary = app(1, 'com.main.app', 2), helper = app(2, 'com.helper.app', 9).latestAsset;
  const projected = { ...primary, latestAsset: undefined, latestAssets: [],
    knownAssets: [primary.latestAsset, helper, helper], previewChannel: true, channelUnavailable: true };
  const lookup = new CatalogLookup([primary], [], true, 2, () => projected);
  assert.equal(lookup.app(1).latestAsset, undefined);
  assert.equal(lookup.source(0, helper.bundleName), projected, 'duplicate variants from one repository are one source');
  assert.equal(lookup.source(1, primary.latestAsset.bundleName), projected);
});

test('visible newer metadata is shared by every lookup while channel revision rebuilds the projection', () => {
  const primary = [app(1, 'com.one.app', 2)], visible = [app(1, 'com.one.app', 3)];
  const lookup = new CatalogLookup(primary, visible, true, 1, row => ({ ...row, preview: true }));
  assert.equal(lookup.app(1).latestAsset.versionCode, 3);
  assert.equal(lookup.source(1, 'com.one.app').latestAsset.versionCode, 3);
  assert.equal(lookup.rows[0].latestAsset.versionCode, 3);
  assert(lookup.matches(primary, visible, true, 1));
  for (const args of [[primary.slice(), visible, true, 1], [primary, visible.slice(), true, 1],
    [primary, visible, false, 1], [primary, visible, true, 2]]) assert(!lookup.matches(...args));
});

test('display projection preserves every journal field without serializing material or changing execution identity', () => {
  const job = new InstallJob();
  for (const [key, value] of Object.entries(job)) {
    if (typeof value === 'string') job[key] = key;
    if (typeof value === 'number') job[key] = 77;
    if (typeof value === 'boolean') job[key] = true;
  }
  job.stageHistory = [{ stage: 'installed', at: 77 }]; job.mirrorUrls = ['https://example.com/app.hap'];
  const copy = InstallJob.displayCopy(job);
  assert.notEqual(copy, job); assert.equal(JSON.stringify(copy), JSON.stringify(job));
  assert.equal(copy.stageHistory, job.stageHistory); assert.equal(copy.mirrorUrls, job.mirrorUrls);
  copy.versionCode = 88; copy.versionName = '2.0';
  assert.equal(job.versionCode, 77); assert.equal(job.versionName, 'versionName');
});

test('bulk-update enabled state short circuits without merging all installed histories during render', () => {
  const ui = page(['hasInstalledUpdates']); let probes = 0;
  Object.assign(ui, { updates: Array.from({ length: 1000 }, (_, id) => ({ appId: id, bundleName: 'b' + id })),
    uninstallingBundle: 'b0', taskPending: () => { probes++; return false; },
    allInstalledJobs: () => { throw Error('render must not rebuild installed history'); } });
  assert(ui.hasInstalledUpdates()); assert.equal(probes, 1);
  ui.taskPending = () => true; assert(!ui.hasInstalledUpdates());
  ui.updates = []; assert(!ui.hasInstalledUpdates());
});

test('hidden management mutations coalesce without timers or list publication; return uses the latest snapshot', () => {
  const timers = [], published = [];
  const ui = page(['syncManagementRows'], { setTimeout: fn => { timers.push(fn); return timers.length; } });
  const data = label => ({ update: rows => published.push([label, rows]), totalCount: () => 1 });
  Object.assign(ui, { pageVisible: false, managementRowsTimer: -1, queueRows: data('queue'),
    onlineInstalledRows: data('online'), offlineInstalledRows: data('offline'), publishedRows: data('published'),
    managementQueueJobs: () => ['latest queue'], managementInstalledJobs: local => [local ? 'offline' : 'online'], myApps: ['new publication'] });
  for (let i = 0; i < 100; i++) ui.syncManagementRows();
  assert.equal(timers.length, 0); assert.equal(published.length, 0); assert(ui.managementRowsPending);
  ui.pageVisible = true; ui.syncManagementRows(); ui.syncManagementRows(); assert.equal(timers.length, 1);
  timers.shift()(); assert.equal(published.length, 4); assert(!ui.managementRowsPending);
  assert.deepEqual(published[0], ['queue', ['latest queue']]);
  assert.deepEqual(published.at(-1), ['published', ['new publication']]);
});

test('home lifecycle is read by small control components rather than the full catalog/root builders', () => {
  const state = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/theme/HomeVisibility.ets'), 'utf8');
  const controls = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/HomeControls.ets'), 'utf8');
  assert.match(state, /@Track visible/); assert.doesNotMatch(source, /@State private pageVisible/);
  assert.match(controls, /@ObjectLink homeVisibility/);
  assert.doesNotMatch(source.slice(source.indexOf('  @Builder\n  private discoverPage()')), /this\.pageVisible|this\.homeVisibility\.visible/);
});

test('an unchanged device inventory retains the mounted rows; real name, version, launcher and removal changes publish', () => {
  let rows = [{ bundleName: 'com.test.app', displayName: '测试', versionCode: 1,
    versionName: '1.0', moduleName: 'entry', abilityName: 'MainAbility' }];
  const ui = page(['syncDeviceInstalled'], { InstallJob, InstallStage: { INSTALLED: 'installed' },
    InstalledAppRegistry: { sideloadedApps: () => rows } });
  let current = [], writes = 0, iconChecks = 0;
  Object.defineProperty(ui, 'deviceInstalled', { get: () => current, set: next => { current = next; writes++; } });
  ui.syncDeviceIcons = () => iconChecks++;
  ui.syncDeviceInstalled(); assert.equal(writes, 1);
  for (let i = 0; i < 100; i++) ui.syncDeviceInstalled();
  assert.equal(writes, 1); assert.equal(iconChecks, 101);
  for (const change of [{ displayName: '新名字' }, { versionCode: 2, versionName: '2.0' }, { abilityName: 'NewAbility' }]) {
    rows = [{ ...rows[0], ...change }]; ui.syncDeviceInstalled();
  }
  assert.equal(writes, 4); assert.equal(current[0].mainAbility, 'NewAbility');
  rows = []; ui.syncDeviceInstalled(); assert.equal(writes, 5); assert.equal(current.length, 0);
});

test('a scan finishing after Home retains device evidence and waits for interaction; a hidden root publishes on its next return', async () => {
  let finishQuery, finishIdle;
  const query = new Promise(resolve => finishQuery = resolve), idle = new Promise(resolve => finishIdle = resolve);
  const registry = { sideloadedApps: () => [{ bundleName: 'com.new.app' }], version: name => name === 'com.old.app' ? 0 : 2,
    versionName: (_, version) => version > 0 ? '2.0' : '', observedAt: () => 77 };
  const ui = page(['scanDeviceInstalled', 'publishDeviceInventory'], {
    Index: { VERSION_TTL_MS: 60000 }, getContext: () => ({}), VersionCacheEntry: class {},
    InstalledAppRegistry: registry, ForegroundIdle: { wait: () => idle },
    HdcDeviceBridge: class { static deviceLinked() { return true; } sideloadedApps() { return query; } }
  });
  let publications = 0;
  Object.assign(ui, { pageVisible: false, deviceInventoryAt: 0, installedDisplay: new Map(), installedVersions: new Map(), installTasks: [],
    allInstalledJobs: () => [{ bundleName: 'com.old.app' }],
    commitCatalogVersions: display => { publications++; ui.installedDisplay = display; },
    syncDeviceInstalled() {}, loadSigningExpiries() {}, syncLocalIcons() {}, refreshCatalogInstallState() {} });
  const work = ui.scanDeviceInstalled(true); finishQuery(); await new Promise(setImmediate);
  assert(ui.deviceInventoryViewPending); assert.equal(publications, 0);
  finishIdle(); await work; assert.equal(publications, 0); assert(ui.deviceInventoryViewPending);
  ui.pageVisible = true; ui.publishDeviceInventory();
  assert.equal(publications, 1); assert(!ui.deviceInventoryViewPending);
  assert.equal(ui.installedDisplay.get('com.old.app').version, 0);
  assert.equal(ui.installedDisplay.get('com.new.app').version, 2);
  assert.equal(ui.installedDisplay.get('com.new.app').at, 77);
});
