// Exercise production Detail methods, including legacy-cache origin reconciliation.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const jobs = loadEts('jobs/InstallJob');
const ReleaseUpdate = require('./release_update_fixture.cjs').releaseUpdate();
const { CatalogInstallTarget } = loadEts('jobs/CatalogInstallTarget', {
  './InstallJob': jobs, './ReleaseUpdate': { ReleaseUpdate },
  '../data/CatalogPackageVariant': loadEts('data/CatalogPackageVariant')
});
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function deferred() {
  let resolve;
  const promise = new Promise(done => resolve = done);
  return { promise, resolve };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const f = { official: false, originKnown: true, deviceCode: 111112,
    probes: 0, persists: 0, wirelessProbes: 0, idle: Promise.resolve() };
  const registry = { isAppGallery: () => f.official, hasApplicationOrigin: () => f.originKnown,
    versionName: () => '1.111.0.112', signingIdentity: () => undefined,
    persist: async () => f.persists++ };
  const names = ['refreshInstalledVersion', 'confirmInstalledOrigin', 'readInstalledOrigin',
    'installedForApp', 'updateAvailable', 'selectedDowngrade', 'installButtonLabel'];
  const box = { ...jobs, CatalogInstallTarget, ReleaseUpdate, UpdatePolicy: { disabled: () => false }, InstalledAppRegistry: registry,
    LocalBundles: { isKnown: value => value >= 0, installedVersion: () => f.deviceCode,
      async liveInstalledState() {
        f.probes++;
        if (f.query) await f.query;
        if (f.error) throw Error('query unavailable');
        f.official = f.readOfficial ?? f.official;
        f.originKnown = true;
        return { versionCode: f.deviceCode, versionName: '1.111.0.112' };
      } },
    ForegroundIdle: { wait: () => f.idle }, getContext: () => ({}), isPending: () => false };
  vm.runInNewContext(ts.transpileModule('class Page { ' + names.map(method).join('\n') +
    ' }; globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  f.ui = Object.assign(new box.Page(), { updatePolicyReady: true, updatesPaused: false,
    app: { id: 42 }, selectedAsset: {
    name: 'MiHoYoLauncher.hap', bundleName: 'com.nrc.huawei', versionCode: 3002000 },
    installedVersion: 111112, installedUnknown: false, installedJobs: [], releases: [],
    explicitSelection: false, disposed: false, pageVisible: true,
    selectedBundleName() { return this.selectedAsset.bundleName; },
    currentInstallTask: () => undefined, selectedVersionLabel: () => '3.2.0',
    confirmInstalledViaDevice: async () => f.wirelessProbes++ });
  return f;
}

test('AppGallery collision cannot inherit a stale sideload receipt or offer the unrelated store update', () => {
  const f = fixture();
  f.official = true;
  f.ui.installedJobs = [{ bundleName: 'com.nrc.huawei', stage: jobs.InstallStage.INSTALLED,
    versionCode: 111112, mainAbility: 'OldLauncherAbility' }];
  f.ui.refreshInstalledVersion();
  assert.equal(f.ui.installedVersion, 0);
  assert.equal(f.ui.installedForApp(), undefined);
  assert.equal(f.ui.updateAvailable(), false);
  assert.equal(f.ui.selectedDowngrade(), false);
  assert.equal(f.ui.installButtonLabel(), '安装应用');
  assert.equal(f.probes, 0, 'a cached verified origin does not add a render-time system read');
});

test('genuine sideloaded apps keep their installed and update actions', () => {
  const f = fixture();
  f.ui.refreshInstalledVersion();
  assert.equal(f.ui.installedVersion, 111112);
  assert.equal(f.ui.updateAvailable(), true);
  assert.equal(f.ui.installButtonLabel(), '更新到 3.2.0');
  f.deviceCode = 3002000;
  f.ui.refreshInstalledVersion();
  assert.equal(f.ui.installButtonLabel(), '打开应用');
});

test('old caches reconcile origin asynchronously once, coalescing reads and persisting before publication', async () => {
  const f = fixture(), idle = deferred();
  f.originKnown = false; f.readOfficial = true; f.idle = idle.promise;
  f.ui.refreshInstalledVersion();
  const first = f.ui.originQueryFlight;
  f.ui.refreshInstalledVersion();
  assert.equal(f.ui.originQueryFlight, first);
  assert.equal(f.ui.installedVersion, 111112, 'the existing observation is available immediately');
  assert.equal(f.probes, 0, 'the read waits until the transition is idle');
  idle.resolve(); await first;
  assert.equal(f.probes, 1); assert.equal(f.persists, 1);
  assert.equal(f.ui.installedVersion, 0); assert.equal(f.ui.updateAvailable(), false);
  f.ui.refreshInstalledVersion(); await tick();
  assert.equal(f.probes, 1, 'a confirmed origin is reused on subsequent page refreshes');
});

test('a late origin read cannot change a different selected package or a hidden detail page', async () => {
  for (const hidden of [false, true]) {
    const f = fixture(), query = deferred();
    f.originKnown = false; f.readOfficial = true; f.query = query.promise;
    f.ui.refreshInstalledVersion(); const flight = f.ui.originQueryFlight; await tick();
    assert.equal(f.probes, 1);
    if (hidden) f.ui.pageVisible = false;
    else f.ui.selectedAsset = { ...f.ui.selectedAsset, bundleName: 'com.other.app' };
    f.ui.installedVersion = 88;
    query.resolve(); await flight;
    assert.equal(f.persists, 1, 'device evidence still survives the page change');
    assert.equal(f.ui.installedVersion, 88, 'the stale page result cannot overwrite the new state');
  }
});

test('failed origin queries retain the verified version and do not force a wireless prompt', async () => {
  const f = fixture(); f.originKnown = false; f.error = true;
  f.ui.refreshInstalledVersion(); await f.ui.originQueryFlight;
  assert.equal(f.ui.installedVersion, 111112);
  assert.equal(f.ui.installedUnknown, false);
  assert.equal(f.persists, 0); assert.equal(f.wirelessProbes, 0);
  assert.equal(f.ui.originQueryFlight, undefined);
});
