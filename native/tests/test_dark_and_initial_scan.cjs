const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, console });
  return exports;
}
function page(file, names, globals) {
  const source = fs.readFileSync(path.join(root, 'pages', file + '.ets'), 'utf8');
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const sandbox = { ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  return new sandbox.Page();
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const f = { snapshot: false, snapshots: 0, probes: [], reconciles: [] };
  const ui = page('Index', ['animateOverlay', 'updateInstallScanPrompt', 'openInstallScan',
    'confirmCatalogVersionsViaDevice', 'runCatalogVersionProbes', 'waitForRefreshConnection', 'completeRefreshConnection', 'reconcileCatalogInstallState'], {
    Curve: { EaseOut: 'ease-out' },
    getContext: () => ({}),
    InstalledAppRegistry: {
      hasCatalogSnapshot: () => f.snapshot,
      async markCatalogSnapshot() { f.snapshot = true; f.snapshots++; }
    },
    HdcDeviceBridge: class {
      static deviceLinked() { return true; }
      async installedBundleVersions(names) {
        const work = deferred(); f.probes.push({ names: [...names], ...work });
        return work.promise;
      }
    }
  });
  Object.assign(ui, { apps: [{ id: 1, latestAsset: { bundleName: 'com.example.one' } }],
    getUIContext: () => ({ animateTo: (_options, change) => change() }),
    installedJobs: [], forgetInstalledVersions() {}, installedVersions: new Map(), catalogProbeNames: [], catalogProbeBusy: false, catalogProbePending: [],
    updateCatalogReady: true, accountChecked: true, signedIn: true,
    initialScanDismissed: false, showReconnect: false, showSubmit: false, showAppConfig: false,
    activeJobId: '', pendingJobs: [], reconnectBusy: false,
    syncDetectedInstalled() {}, checkInstalledUpdates() {},
    updateApps() { return this.apps; },
    installedVersionOf(id) { return this.installedVersions.get(id) ?? -1; },
    async reconcileDetectedJobs(versions) { f.reconciles.push(versions); }
  });
  f.ui = ui; return f;
}
test('first unresolved startup offers a skippable scan, rather than declaring apps uninstalled', () => {
  const f = fixture(), ui = f.ui;
  ui.accountChecked = false; ui.updateInstallScanPrompt();
  assert.equal(ui.showReconnect, false);
  ui.accountChecked = true; ui.updateInstallScanPrompt();
  assert.equal(ui.needsInstallScan, true);
  assert.equal(ui.showReconnect, true);
  assert.equal(ui.resumeJobId, '');
  ui.showReconnect = false; ui.updateInstallScanPrompt();
  assert.equal(ui.showReconnect, false);
  ui.openInstallScan(); assert.equal(ui.showReconnect, true);
});
test('known system state and a previous completed snapshot avoid automatic connection prompts', () => {
  const f = fixture(), ui = f.ui;
  for (const version of [0, 110003]) {
    ui.installedVersions.set(1, version); ui.updateInstallScanPrompt();
    assert.equal(ui.needsInstallScan, false);
    assert.equal(ui.showReconnect, false);
  }
  ui.installedVersions.clear(); f.snapshot = true;
  ui.updateInstallScanPrompt(); assert.equal(ui.showReconnect, false);
  assert.equal(ui.needsInstallScan, true);
});
test('an active install or another sheet is not interrupted by startup identification', () => {
  const f = fixture(), ui = f.ui;
  ui.pendingJobs = [{}]; ui.updateInstallScanPrompt(); assert.equal(ui.showReconnect, false);
  ui.pendingJobs = []; ui.showSubmit = true;
  ui.updateInstallScanPrompt(); assert.equal(ui.showReconnect, false);
});
test('a successful inventory distinguishes side loads, missing apps and partial version failures', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps.push({ id: 2, latestAsset: { bundleName: 'com.example.two' } });
  const run = ui.confirmCatalogVersionsViaDevice(['com.example.one', 'com.example.two']);
  f.probes[0].resolve(new Map([['com.example.one', 110003]])); await run;
  assert.equal(ui.installedVersions.get(1), 110003);
  assert.equal(ui.installedVersions.get(2), 0);
  assert.equal(ui.needsInstallScan, false);
  assert.equal(f.snapshots, 1);
  const failed = fixture();
  const partial = failed.ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  failed.probes[0].resolve(new Map([['com.example.one', 0]])); await partial;
  assert.equal(failed.ui.installedVersionOf(1), -1);
  assert.equal(failed.snapshots, 0);
});
test('catalog arriving during a scan is coalesced instead of losing the later apps', async () => {
  const f = fixture(), ui = f.ui;
  const run = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  ui.apps.push({ id: 2, latestAsset: { bundleName: 'com.example.two' } });
  const joined = ui.confirmCatalogVersionsViaDevice(['com.example.two']);
  assert.equal(joined, run, 'all callers share the full scan completion');
  f.probes[0].resolve(new Map([['com.example.one', 1]]));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.probes[1].names, ['com.example.two']);
  f.probes[1].resolve(new Map([['com.example.two', 2]])); await run;
  assert.equal(ui.installedVersions.get(1), 1);
  assert.equal(ui.installedVersions.get(2), 2);
  assert.equal(f.snapshot, true);
});
test('failed wireless reads preserve confirmed state and do not mark first scan complete', async () => {
  const f = fixture(), ui = f.ui;
  ui.installedVersions.set(1, 110003);
  const run = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  f.probes[0].reject(Error('offline')); await run;
  assert.equal(ui.installedVersions.get(1), 110003);
  assert.equal(f.snapshots, 0);
});
test('cached display state cannot turn a partial live inventory into a completed scan', async () => {
  const f = fixture(), ui = f.ui;
  ui.installedVersions.set(1, 110003);
  const run = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  f.probes[0].resolve(new Map([['com.example.one', 0]])); await run;
  assert.equal(ui.installedVersions.get(1), 110003, 'keep the offline display state');
  assert.equal(f.snapshots, 0, 'a failed version read is not proof of a complete scan');
});
test('scan completion and side-loaded versions survive a process restart independently', async () => {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await first.load({}); assert.equal(first.hasCatalogSnapshot(), false);
  first.remember('com.example.one', 110003); await first.persist({});
  await first.markCatalogSnapshot({});
  const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await restarted.load({}); assert.equal(restarted.hasCatalogSnapshot(), true);
  assert.equal(restarted.version('com.example.one'), 110003);
});
test('malformed zero system metadata remains unknown, rather than proving an uninstall', () => {
  const { LocalBundles } = load('jobs/LocalBundles', {
    './InstalledAppRegistry': { InstalledAppRegistry: { version: () => -1 } },
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
      getBundleInfoForSelfSync: () => ({ name: 'com.example.installer', versionCode: 1 }),
      getBundleInfoSync: () => ({ versionCode: 0 }) } }
  });
  assert.equal(LocalBundles.installedVersion('com.example.one'), -1);
});
test('pages can retain independent light and dark palettes without global state contamination', () => {
  const { Palette } = load('theme/Palette');
  const light = Palette.forMode(false), dark = Palette.forMode(true);
  assert.notEqual(light.text, dark.text); assert.notEqual(light.bg, dark.bg);
  assert.equal(Palette.forMode(false), light); assert.equal(Palette.forMode(true), dark);
  assert.equal(light.text, '#17213A'); assert.equal(dark.text, '#EAF0F7');
});
test('an old icon color request cannot put a light hero background into a dark page', async () => {
  const requests = [];
  const ui = page('Detail', ['refreshHeroColor'], {
    ColorTint: { heroBackground: (_icon, dark) => {
      const work = deferred(); requests.push({ dark, ...work }); return work.promise;
    } }
  });
  ui.appIcon = {}; ui.darkMode = false; ui.refreshHeroColor();
  ui.darkMode = true; ui.refreshHeroColor();
  requests[1].resolve('#152030'); await new Promise(resolve => setImmediate(resolve));
  requests[0].resolve('#eaf0ff'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.heroColor, '#152030');
});

test('an inventory already in flight covers repeated requests for the same packages', async () => {
  const f = fixture(), ui = f.ui;
  const work = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  const joined = ui.confirmCatalogVersionsViaDevice(['com.example.one', 'com.example.one']);
  assert.equal(joined, work);
  f.probes[0].resolve(new Map([['com.example.one', 1]])); await work;
  assert.equal(f.probes.length, 1);
  assert.equal(ui.installedVersions.get(1), 1);
});

test('packages arriving while a snapshot is being saved are included in scan completion', async () => {
  const f = fixture(), ui = f.ui, save = deferred();
  const registry = { hasCatalogSnapshot: () => false, markCatalogSnapshot: () => save.promise };
  // Reuse the production drain with a delayed snapshot adapter.
  const drain = page('Index', ['runCatalogVersionProbes'], {
    getContext: () => ({}), InstalledAppRegistry: registry,
    HdcDeviceBridge: class {
      static deviceLinked() { return true; } installedBundleVersions(names) {
      const work = deferred(); f.probes.push({ names: [...names], ...work }); return work.promise;
    } }
  });
  ui.runCatalogVersionProbes = drain.runCatalogVersionProbes;
  const work = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  f.probes[0].resolve(new Map([['com.example.one', 1]]));
  await new Promise(resolve => setImmediate(resolve));
  ui.apps.push({ id: 2, latestAsset: { bundleName: 'com.example.two' } });
  const joined = ui.confirmCatalogVersionsViaDevice(['com.example.two']);
  assert.equal(joined, work);
  save.resolve(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.catalogProbeBusy, true);
  assert.deepEqual(f.probes[1].names, ['com.example.two']);
  f.probes[1].resolve(new Map([['com.example.two', 2]])); await work;
  assert.equal(ui.installedVersions.get(2), 2);
});

test('a failed earlier batch cannot be hidden by a successful later batch', async () => {
  const f = fixture(), ui = f.ui;
  ui.installedVersions.set(1, 100);
  const work = ui.confirmCatalogVersionsViaDevice(['com.example.one']);
  ui.apps.push({ id: 2, latestAsset: { bundleName: 'com.example.two' } });
  ui.confirmCatalogVersionsViaDevice(['com.example.two']);
  f.probes[0].resolve(new Map([['com.example.one', 0]]));
  await new Promise(resolve => setImmediate(resolve));
  f.probes[1].resolve(new Map([['com.example.two', 2]])); await work;
  assert.equal(f.snapshots, 0);
  assert.equal(ui.installedVersions.get(1), 100);
});

test('automatic identity changes update My locally and wake certificate-paused installs without a restart', async () => {
  const work = deferred(), wakes = [];
  const ui = page('Index', ['onSigningIdentityChanged', 'applyCertificateDetail'], {
    getContext: () => ({}),
    SigningIdentityRecovery: { load: () => work.promise },
    InstallCoordinator: { conditionReady: async (_context, stage) => wakes.push(stage) },
    InstallStage: { WAITING_ACCOUNT: 'waiting-account' }
  });
  Object.assign(ui, { signedIn: true, account: { userId: '42' }, signingIdentityRevision: 1,
    certReady: false, identityBusy: false, identityMessage: '待申请' });
  const run = ui.onSigningIdentityChanged();
  work.resolve({ certId: '100', certName: 'paired', certExpiry: 0 }); await run;
  assert.equal(ui.certReady, true);
  assert.equal(ui.certId, '100'); assert.equal(ui.certLabel, 'paired');
  assert.equal(ui.identityMessage, '');
  assert.deepEqual(wakes, ['waiting-account']);
});

test('a late identity read cannot restore certificate state after signing out or switching users', async () => {
  const work = deferred();
  const ui = page('Index', ['onSigningIdentityChanged'], {
    getContext: () => ({}), SigningIdentityRecovery: { load: () => work.promise }
  });
  Object.assign(ui, { signedIn: true, account: { userId: '42' }, signingIdentityRevision: 1, certReady: false });
  const run = ui.onSigningIdentityChanged();
  ui.account = { userId: 'other' };
  work.resolve({ certId: '100' }); await run;
  assert.equal(ui.certReady, false);
});
