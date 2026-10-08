const { loadEts } = require('./load_ets.cjs');
const { CatalogLookup } = loadEts('data/CatalogLookup');
const { InstallJob } = loadEts('jobs/InstallJob');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, console });
  return exports;
}
const end = '__QINGQI_BUNDLE_LIST_END__\n';
const own = 'com.tonghongxiang.hapstore', external = 'com.example.external';
function fixture() {
  const disk = new Map(), calls = [], starts = [];
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const registry = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  mocks['./InstalledAppRegistry'] = { InstalledAppRegistry: registry };
  const Bridge = load('jobs/HdcDeviceBridge', mocks).HdcDeviceBridge;
  const f = { mocks, disk, calls, registry, names: [own, external], all: [own, external, 'com.huawei.settings'], bad: new Set() };
  const context = { startAbility: async want => starts.push(want) };
  f.bridge = new Bridge(context); f.starts = starts;
  f.bridge.connected = async () => { Bridge.linked = true; return true; };
  f.bridge.command = async (op, name) => {
    calls.push([op, name]);
    if (op === 13) return f.invalid ?? 'ID: 100:\n' + f.names.join('\n') + '\n' + end;
    if (op === 6) return f.partialAll ?? 'ID: 100:\n' + f.all.join('\n') + '\n' + end;
    if (op === 14) return name === external ? '离线阅读器' : '轻启·安装器';
    if (f.bad.has(name)) return 'malformed bundle details';
    return JSON.stringify({ name, updateTime: f.updateTime ?? 0, versionCode: f.version ?? 42, versionName: '1.2.3', entryModuleName: 'entry',
      hapModuleInfos: [{ moduleName: 'entry', mainAbility: 'MainAbility' }],
      applicationInfo: { debug: false, appProvisionType: 'debug', iconResource: { id: 16777222, moduleName: 'entry' } } });
  };
  return f;
}
test('inventory discovers unlisted externally sideloaded release builds, without querying system bundles', async () => {
  const f = fixture(); const rows = await f.bridge.sideloadedApps();
  assert.deepEqual(Array.from(rows, row => row.bundleName), [own, external]);
  const app = rows.find(row => row.bundleName === external);
  assert.equal(app.displayName, '离线阅读器'); assert.equal(app.versionName, '1.2.3');
  assert.equal(app.abilityName, 'MainAbility');
  assert.equal(f.registry.iconResource(external).id, 16777222);
  assert.equal(f.calls.filter(([op]) => op === 13).length, 1);
  assert.equal(f.calls.some(([op, name]) => op === 3 && name === 'com.huawei.settings'), false);
  await f.bridge.sideloadedApps();
  assert.equal(f.calls.filter(([op]) => op === 14).length, 2, 'unchanged app labels are not reread');
});
test('device names, versions and launchers persist; an externally installed app opens offline after restart', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  const restarted = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry;
  await restarted.load({});
  assert.equal(restarted.sideloadedApps().find(row => row.bundleName === external).displayName, '离线阅读器');
  assert.equal(restarted.iconResource(external).moduleName, 'entry');
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    './InstalledAppRegistry': { InstalledAppRegistry: restarted }
  });
  const bridge = new HdcDeviceBridge({ startAbility: async want => f.starts.push(want) });
  bridge.connected = async () => { throw Error('offline'); };
  await bridge.openApp(external);
  assert.equal(f.starts[0].abilityName, 'MainAbility'); assert.equal(f.starts[0].bundleName, external);
});
test('malformed or truncated inventories preserve cached side loads; a valid empty list is accepted', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  for (const output of ['', 'ID: 100:\ncom.exam', 'ID: 100:\n[Fail]', 'error: permission denied']) {
    f.invalid = output; await assert.rejects(() => f.bridge.sideloadedApps());
    assert.equal(f.registry.sideloadedApps().length, 2);
  }
  f.invalid = 'ID: 100:\n' + end;
  assert.equal((await f.bridge.sideloadedApps()).length, 0);
});
test('individual package failures retain its last version; a complete existence list confirms removal', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  f.bad.add(external); f.version = 43;
  const partial = await f.bridge.sideloadedApps();
  assert.equal(partial.find(row => row.bundleName === external).versionCode, 42);
  assert.equal(partial.find(row => row.bundleName === own).versionCode, 43);
  f.names = [own]; f.all = [own, 'com.huawei.settings'];
  assert.equal((await f.bridge.sideloadedApps([external])).length, 1);
  assert.equal(f.registry.version(external), 0); assert.equal(f.registry.launcher(external), undefined);
});

const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
function method(name) {
  const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
  assert(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function pageFixture(registry) {
  const box = { CatalogLookup, InstallJob, InstallStage: { INSTALLED: 'installed' }, ReleaseChannelRegistry: { apply: app => app },
    InstalledSigningExpiry: load('jobs/InstalledSigningExpiry', {}).InstalledSigningExpiry,
    InstalledAppRegistry: registry ?? { version: () => -1, observedAt: () => 0, versionName: () => '', displayName: () => '', installationTime: () => 0 } };
  box.AppDisplayName = load('data/AppDisplayName', {
    '../jobs/InstalledAppRegistry': { InstalledAppRegistry: box.InstalledAppRegistry }
  }).AppDisplayName;
  const members = ['catalogLookup', 'allInstalledJobs', 'recentInstalledJobs', 'currentInstalledView', 'displayInstalledVersion',
    'managementInstalledJobs', 'renewalDeadline', 'updateApps', 'installedAssets', 'latestAssets', 'catalogForJob', 'jobTitle'];
  vm.runInNewContext(ts.transpileModule(`class Page { ${members.map(method).join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page();
  Object.assign(ui, { installedJobs: [], storeInstalled: [], deviceInstalled: [], pendingJobs: [],
    updateFor: () => undefined, signingExpiries: new Map(), signingExpiryEstimates: new Map(),
    installedDisplay: new Map(), apps: [], updateCatalog: [], updateCatalogReady: true, installedLocalOnly: false });
  return ui;
}
function job(bundleName, id = bundleName) {
  return { id, bundleName, appId: 0, versionCode: 42, versionName: '1.2.3', sourceUrl: 'device',
    stage: 'installed', stageHistory: [], updatedAt: 1800000000000 };
}

test('both installed groups rank updates first, then earliest exact or estimated expiry, preserving ties', () => {
  for (const localOnly of [false, true]) {
    const ui = pageFixture();
    const rows = ['latest', 'expired', 'estimate', 'update-late', 'update-soon', 'same-day']
      .map(name => job('com.example.' + name, name));
    ui.installedJobs = rows;
    ui.updateCatalog = localOnly ? [] : [{ id: 1, latestAssets: rows.map(row => ({ bundleName: row.bundleName })) }];
    ui.updateFor = bundle => bundle.includes('update-') ? { bundleName: bundle } : undefined;
    const end = 1800000000;
    ui.signingExpiries = new Map([
      [rows[0].bundleName, end + 300], [rows[1].bundleName, end - 1],
      [rows[3].bundleName, end + 200], [rows[4].bundleName, end + 100],
      [rows[5].bundleName, end + 300]
    ]);
    // An estimate is ordered by the displayed date, but never replaces a verified date.
    ui.signingExpiryEstimates = new Map([[rows[2].bundleName, end + 10], [rows[3].bundleName, end - 100]]);
    assert.deepEqual(Array.from(ui.managementInstalledJobs(localOnly), row => row.id),
      ['update-soon', 'update-late', 'expired', 'estimate', 'latest', 'same-day']);
    assert.deepEqual(Array.from(ui.installedJobs, row => row.id), rows.map(row => row.id),
      'sorting must not rewrite install history');
    ui.signingExpiryEstimates.set(rows[2].bundleName, end + 500);
    ui.updateFor = () => undefined;
    assert.deepEqual(Array.from(ui.managementInstalledJobs(localOnly), row => row.id),
      ['expired', 'update-soon', 'update-late', 'latest', 'same-day', 'estimate'],
      'refreshed expiry and update state immediately changes the order');
  }
});

test('pending expiry reads sort using the same durable install-time fallback shown in the label', () => {
  const ui = pageFixture();
  const a = job('com.example.newer', 'newer'), b = job('com.example.older', 'older');
  a.installedUpdateTime = 1800000000000; b.installedUpdateTime = 1700000000000;
  ui.installedJobs = [a, b];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(true), row => row.id), ['older', 'newer']);
  ui.signingExpiryEstimates.set(a.bundleName, 1600000000);
  assert.deepEqual(Array.from(ui.managementInstalledJobs(true), row => row.id), ['newer', 'older']);
});

test('freshly confirmed local reinstall beats the page snapshot, while newer uninstall still wins', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  const page = pageFixture(f.registry); page.installedJobs = [job(external)];
  page.installedDisplay.set(external, { version: 0, at: Date.now() - 1000 });
  assert.equal(page.displayInstalledVersion(external), 42);
  assert.equal(page.managementInstalledJobs(true).length, 1);
  page.installedDisplay.set(external, { version: 0, at: f.registry.observedAt(external) + 1 });
  assert.equal(page.managementInstalledJobs(true).length, 0);
});

test('a truncated sideload inventory preserves the previous offline group', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  f.invalid = 'ID: 100:\n' + own + '\n';
  await assert.rejects(f.bridge.sideloadedApps(), /完整/);
  assert.equal(f.registry.sideloadedApps().some(row => row.bundleName === external), true);
});
test('uninstall refresh and process restart never revive old local installation history', async () => {
  const f = fixture(); await f.bridge.sideloadedApps();
  const before = pageFixture(f.registry); before.installedJobs = [job(external, 'old-local-install')];
  assert.equal(before.managementInstalledJobs(true).length, 1);
  f.names = [own]; f.all = [own, 'com.huawei.settings'];
  await f.bridge.sideloadedApps([external]);
  assert.equal(before.managementInstalledJobs(true).length, 0);
  const restartedRegistry = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry;
  await restartedRegistry.load({});
  const restartedPage = pageFixture(restartedRegistry);
  restartedPage.installedJobs = [job(external, 'old-local-install')];
  assert.equal(restartedPage.managementInstalledJobs(true).length, 0,
    'restoring job history must not turn an uninstalled app back into an installed app');
  assert.equal(restartedPage.installedJobs.length, 1, 'history remains intact');
  f.mocks['./InstalledAppRegistry'] = { InstalledAppRegistry: restartedRegistry };
  const Bridge = load('jobs/HdcDeviceBridge', f.mocks).HdcDeviceBridge;
  const bridge = new Bridge({}); bridge.connected = async () => { Bridge.linked = true; return true; };
  bridge.command = f.bridge.command; f.names = [own, external]; f.all.push(external); f.version = 43;
  await bridge.sideloadedApps();
  assert.equal(restartedPage.managementInstalledJobs(true).length, 1);
  assert.equal(restartedPage.managementInstalledJobs(true)[0].versionCode, 43);
});
test('one bundle appears and counts once across sources; locally installed published apps join the store group', () => {
  const ui = pageFixture(); ui.updateCatalog = [{ id: 1, displayName: '商店应用', latestAssets: [{ bundleName: external }] }];
  ui.installedJobs = [job(external, 'history')];
  ui.storeInstalled = [job(external, 'store')];
  ui.deviceInstalled = [job(external, 'device'), job(own)];
  assert.equal(ui.allInstalledJobs().length, 2);
  assert.equal(ui.managementInstalledJobs(false).length, 1);
  assert.equal(ui.managementInstalledJobs(true).length, 1);
  assert.equal(ui.managementInstalledJobs(false)[0].id, 'history');
  ui.pendingJobs = [{ appId: 0, catalogBundleName: external, bundleName: '' }];
  assert.equal(ui.managementInstalledJobs(false).length, 0);
  assert.equal(ui.managementInstalledJobs(true).length, 1);
});
test('Melotopia ordinary and HiCar are distinct bundles, but uninstalled old variants and duplicate history are hidden', () => {
  const ui = pageFixture(); const regular = 'cn.chenlvin.melotopia.hm', car = 'cn.migu.music';
  ui.updateCatalog = [{ id: 27, displayName: 'Melotopia', latestAssets: [
    { bundleName: regular, name: '1.15.3-101539.hap' }, { bundleName: car, name: 'HiCar-1.15.3-101539.hap' }] }];
  ui.installedJobs = [job(regular, 'new'), job(regular, 'old'), job(car)];
  ui.storeInstalled = [job(regular), job(car)];
  ui.installedDisplay.set(regular, { version: 101539, versionName: '1.15.3' });
  ui.installedDisplay.set(car, { version: 0 });
  assert.equal(ui.managementInstalledJobs(false).length, 1);
  assert.equal(ui.managementInstalledJobs(false)[0].versionCode, 101539);
  ui.installedDisplay.set(car, { version: 1000101539, versionName: '1.15.3' });
  assert.deepEqual(Array.from(ui.managementInstalledJobs(false), row => ui.jobTitle(row)), ['Melotopia', 'Melotopia · HiCar']);
  assert.equal(ui.installedJobs.length, 3, 'display merging must not rewrite history');
});

test('same-version reinstall refreshes the real edited label when the system update time changes', async () => {
  const f = fixture(); f.updateTime = Date.now() - 30000; await f.bridge.sideloadedApps();
  const labelReads = f.calls.filter(([op]) => op === 14).length;
  f.updateTime += 1000; await f.bridge.sideloadedApps();
  assert.equal(f.calls.filter(([op]) => op === 14).length, labelReads + 2);
  await f.bridge.sideloadedApps();
  assert.equal(f.calls.filter(([op]) => op === 14).length, labelReads + 2, 'unchanged metadata keeps its cached labels');
});

test('an information-page read saves the device label even before the full inventory has run', async () => {
  const f = fixture(); const result = await f.bridge.installedDetails(external);
  assert.equal(result.displayName, '离线阅读器');
  const restarted = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry; await restarted.load({});
  assert.equal(restarted.displayName(external), '离线阅读器');
});
