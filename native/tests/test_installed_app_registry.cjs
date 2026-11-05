const { publicConsentModule } = require('./load_ets.cjs');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  mocks = { './ForegroundIdle': { ForegroundIdle: { wait: async () => {} } }, ...mocks };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || publicConsentModule(name), console });
  return exports;
}
const bundle = 'com.tonghongxiang.quietstart';
const end = '__QINGQI_BUNDLE_LIST_END__\n';
const names = 'ID: 100:\n\tcom.tonghongxiang.hapstore\n\t' + bundle + '\n' + end;
test('signing identity preserves the system update time and never invents a missing timestamp', () => {
  const { InstalledAppRegistry } = load('jobs/InstalledAppRegistry');
  for (const value of [1700000000000, undefined, null, 'bad', -1]) {
    const row = { name: bundle, versionCode: 110003, updateTime: value,
      applicationInfo: { fingerprint: 'A'.repeat(64) } };
    const identity = InstalledAppRegistry.parseSigningIdentity(JSON.stringify(row), bundle);
    assert.equal(identity.updateTime, value === 1700000000000 ? value : 0);
  }
});
test('installation timestamps survive without certificate metadata and refreshing cannot move the estimation baseline', async () => {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  first.remember(bundle, 7);
  first.rememberLauncher(JSON.stringify({ name: bundle, versionCode: 7, updateTime: 1700000000000 }), bundle);
  assert.equal(first.signingIdentity(bundle), undefined);
  assert.equal(first.installationTime(bundle, 7), 1700000000000);
  first.remember(bundle, 7); await first.persist({});
  const restored = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry; await restored.load({});
  assert.equal(restored.installationTime(bundle, 7), 1700000000000);
  restored.remember(bundle, 8); const baseline = restored.installationTime(bundle, 8);
  restored.remember(bundle, 8);
  assert.equal(restored.installationTime(bundle, 8), baseline);
  assert.equal(restored.installationTime(bundle, 7), 0);
  restored.remember(bundle, 0);
  assert.equal(restored.installationTime(bundle, 8), 0);
});
test('a confirmed side-loaded app and its launcher survive process restart; uninstall clears them', async () => {
  const disk = new Map();
  const preferences = { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => { disk.set(key, value); },
    flush: async () => {}
  }) };
  const mocks = { '@kit.ArkData': { preferences } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  first.remember(bundle, 110003);
  first.rememberLauncher(JSON.stringify({ name: bundle, entryModuleName: 'entry',
    hapModuleInfos: [{ moduleName: 'entry', mainAbility: 'EntryAbility' }] }), bundle);
  await first.persist({});
  const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await restarted.load({});
  assert.equal(restarted.version(bundle), 110003);
  assert.equal(restarted.launcher(bundle).abilityName, 'EntryAbility');
  restarted.remember(bundle, 0);
  await restarted.persist({});
  const afterRemoval = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await afterRemoval.load({});
  assert.equal(afterRemoval.version(bundle), 0, 'confirmed uninstall must survive restart');
  assert.equal(afterRemoval.launcher(bundle), undefined);
});
test('a confirmed uninstall survives the live TTL and positive-cache expiry, until a real reinstall', async () => {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await first.load({}); first.remember(bundle, 0); await first.persist({});
  const rows = JSON.parse(disk.get('last-confirmed'));
  assert.equal(rows[0].version, 0);
  rows[0].at = Date.now() - 31 * 24 * 60 * 60 * 1000;
  disk.set('last-confirmed', JSON.stringify(rows));
  const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await restarted.load({}); assert.equal(restarted.version(bundle), 0);
  await restarted.persist({});
  assert.equal(JSON.parse(disk.get('last-confirmed'))[0].version, 0);
  restarted.remember(bundle, 120101); restarted.rememberSideloadedNames([bundle]);
  await restarted.persist({});
  const reinstalled = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await reinstalled.load({}); assert.equal(reinstalled.version(bundle), 120101);
  assert.equal(reinstalled.sideloadedApps()[0].bundleName, bundle);
});
test('a delayed startup cache read cannot resurrect a package already confirmed uninstalled', async () => {
  let releaseRead; const readReady = new Promise(resolve => { releaseRead = resolve; });
  const old = [{ bundleName: bundle, version: 110003, at: Date.now() - 1000,
    moduleName: 'entry', abilityName: 'EntryAbility', sideloaded: true }];
  const disk = new Map([['last-confirmed', JSON.stringify(old)]]);
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => { if (key === 'last-confirmed') await readReady; return disk.get(key) ?? fallback; },
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const registry = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  const loading = registry.load({}); registry.remember(bundle, 0);
  const saving = registry.persist({}); releaseRead(); await loading; await saving;
  assert.equal(registry.version(bundle), 0); assert.equal(registry.launcher(bundle), undefined);
  const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await restarted.load({}); assert.equal(restarted.version(bundle), 0);
  assert.equal(restarted.sideloadedApps().length, 0);
});
test('a month-old device observation is not presented as a current install', async () => {
  const old = [{ bundleName: bundle, version: 110003,
    at: Date.now() - 31 * 24 * 60 * 60 * 1000,
    moduleName: 'entry', abilityName: 'EntryAbility' }];
  const preferences = { getPreferences: async () => ({
    get: async () => JSON.stringify(old)
  }) };
  const registry = load('jobs/InstalledAppRegistry', {
    '@kit.ArkData': { preferences }
  }).InstalledAppRegistry;
  await registry.load({});
  assert.equal(registry.version(bundle), -1);
  assert.equal(registry.launcher(bundle), undefined);
});
test('a missing, null or nonnumeric saved version is unknown, not a confirmed uninstall', async () => {
  for (const version of [undefined, null, '', '0', -1]) {
    const row = { bundleName: bundle, version, at: Date.now() - 1000 };
    const registry = load('jobs/InstalledAppRegistry', { '@kit.ArkData': { preferences: {
      getPreferences: async () => ({ get: async (key, fallback) =>
        key === 'last-confirmed' ? JSON.stringify([row]) : fallback })
    } } }).InstalledAppRegistry;
    await registry.load({}); assert.equal(registry.version(bundle), -1);
  }
});
test('the detected version name survives restart and is never applied to a different build', async () => {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  first.remember(bundle, 120101);
  first.rememberLauncher(JSON.stringify({ name: bundle, versionCode: 120101,
    versionName: '1.2.1-beta' }), bundle);
  await first.persist({});
  const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await restarted.load({});
  assert.equal(restarted.versionName(bundle, 120101), '1.2.1-beta');
  assert.equal(restarted.versionName(bundle, 110003), '');
  restarted.remember(bundle, 120102);
  assert.equal(restarted.versionName(bundle, 120102), '');
  restarted.remember(bundle, 0);
  assert.equal(restarted.versionName(bundle, 120101), '');
});
function fixture() {
  const { InstalledAppRegistry: registry } = load('jobs/InstalledAppRegistry');
  const f = { calls: [], detail: JSON.stringify({ name: bundle, versionCode: 110003, versionName: '1.1.0' }), list: names };
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    './InstalledAppRegistry': { InstalledAppRegistry: registry }
  });
  f.bridge = new HdcDeviceBridge({ filesDir: '/sandbox' });
  f.bridge.connected = async () => { HdcDeviceBridge.linked = true; return true; };
  f.bridge.command = async (op, arg) => { f.calls.push([op, arg]); return op === 6 ? f.list : f.detail; };
  f.registry = registry; f.Bridge = HdcDeviceBridge; return f;
}
test('real 6.1 list format only proves presence; requested versions come from package details', async () => {
  const f = fixture(); const values = await f.bridge.installedBundleVersions([bundle, bundle]);
  assert.equal(values.get(bundle), 110003); assert.equal(f.registry.version(bundle), 110003);
  assert.equal(f.calls.length, 2); assert.equal(f.calls[0][0], 6); assert.equal(f.calls[1][0], 3);
});
test('manual rescan immediately detects an external version change and uninstall, even with fresh display cache', async () => {
  const f = fixture();
  await f.bridge.installedBundleVersions([bundle]);
  f.detail = JSON.stringify({ name: bundle, versionCode: 120101 });
  const updated = await f.bridge.installedBundleVersions([bundle]);
  assert.equal(updated.get(bundle), 120101);
  assert.equal(f.calls.filter(([op]) => op === 3).length, 2, 'a fresh display cache cannot skip live rescan');
  f.list = 'ID: 100:\ncom.tonghongxiang.hapstore\n' + end;
  const removed = await f.bridge.installedBundleVersions([bundle]);
  assert.equal(removed.has(bundle), false);
  assert.equal(f.registry.version(bundle), 0);
});
test('one malformed package does not repeat the full inventory or lose other live results', async () => {
  const f = fixture(), other = 'com.example.other';
  f.list = f.list.replace(end, other + '\n' + end);
  f.bridge.command = async (op, name) => {
    f.calls.push([op, name]);
    return op === 6 ? f.list : name === bundle ? 'invalid package details' :
      JSON.stringify({ name: other, versionCode: 42 });
  };
  const values = await f.bridge.installedBundleVersions([bundle, other]);
  assert.equal(values.has(bundle), true);
  assert.equal(values.get(other), 42);
  assert.equal(f.calls.filter(([op]) => op === 6).length, 1);
});
test('a broken link stops the remaining package queries without deleting cached installs', async () => {
  const f = fixture(), other = 'com.example.other';
  f.list = f.list.replace(end, other + '\n' + end); f.registry.remember(other, 99);
  f.detail = '[Fail] disconnected';
  const values = await f.bridge.installedBundleVersions([bundle, other]);
  assert.equal(f.calls.filter(([op]) => op === 3).length, 1);
  assert.equal(values.has(other), true);
  assert.equal(f.registry.version(other), 99);
});
test('inventory progress counts unique present and absent packages and protects the full scan', async () => {
  const f = fixture(); const progress = [];
  const absent = 'com.example.absent';
  const values = await f.bridge.installedBundleVersions([absent, bundle, bundle], (checked, total) => {
    assert.equal(f.Bridge.busy(), true, 'the scan lease covers gaps between native commands');
    progress.push([checked, total]);
  });
  assert.deepEqual(progress, [[0, 2], [1, 2], [2, 2]]);
  assert.equal(values.get(bundle), 110003);
  assert.equal(f.registry.version(absent), 0);
  assert.equal(f.calls.filter(([operation]) => operation === 3).length, 1);
  assert.equal(f.Bridge.busy(), false);
});
test('permission-denied system lookup reuses an HDC-confirmed side-loaded version across pages', async () => {
  const f = fixture(); await f.bridge.installedVersion(bundle);
  const { LocalBundles } = load('jobs/LocalBundles', {
    './InstalledAppRegistry': { InstalledAppRegistry: f.registry },
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
      getBundleInfoForSelfSync: () => ({ name: 'com.tonghongxiang.hapstore', versionCode: 1 }),
      getBundleInfoSync: () => { throw { code: 201 }; } } }
  });
  assert.equal(LocalBundles.installedVersion(bundle), 110003);
  assert.equal(LocalBundles.installedVersion('com.example.unknown'), -1);
});
test('transport errors and malformed dumps are never treated as an uninstall', async () => {
  const f = fixture(); f.detail = '[Fail] connection closed'; f.list = '[Fail] disconnected';
  await assert.rejects(f.bridge.installedVersion(bundle), /无法确认/);
  assert.equal(f.registry.version(bundle), -1);
  assert.equal(await f.bridge.installedBundleVersions([bundle]), undefined);
});
test('a missing version for a present bundle remains unknown, while verified absence is zero', async () => {
  const f = fixture(); f.detail = 'error: failed to get information and the parameters may be wrong.';
  const values = await f.bridge.installedBundleVersions([bundle]);
  assert.equal(values.has(bundle), true); assert.equal(f.registry.version(bundle), -1);
  assert.equal(await f.bridge.installedVersion('com.example.absent'), 0);
});
test('a mismatched bundle or invalid version is rejected', () => {
  const f = fixture();
  for (const data of [{ name: 'other.bundle', versionCode: 110003 }, { name: bundle, versionCode: 0 }, { name: bundle, versionCode: 'NaN' }]) {
    assert.throws(() => f.registry.parseVersion(JSON.stringify(data), bundle));
  }
});

test('a partial inventory cannot persist false uninstalls, even when cut between complete lines', async () => {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const registry = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  await registry.load({}); registry.remember(bundle, 110003); await registry.persist({});
  const Bridge = load('jobs/HdcDeviceBridge', { './InstalledAppRegistry': { InstalledAppRegistry: registry } }).HdcDeviceBridge;
  const bridge = new Bridge({}); bridge.connected = async () => true;
  for (const partial of ['ID: 100:\ncom.tonghongxiang.hapstore\n',
    'ID: 100:\ncom.tonghongxiang.hapstore\ncom.exa',
    'ID: 100:\ncom.tonghongxiang.hapstore\n__QINGQI_BUNDLE_LIST_END_',
    'ID: 100:\n[Fail] disconnected\n' + end]) {
    bridge.command = async () => partial;
    assert.equal(await bridge.installedBundleVersions([bundle]), undefined);
    assert.equal(registry.version(bundle), 110003);
    const restarted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
    await restarted.load({}); assert.equal(restarted.version(bundle), 110003);
  }
  assert.equal(registry.parseNames('ID: 100:\n' + end).size, 0);
  assert.equal(registry.parseNames('ID: 100:\ncom.atomicservice.6917587889453404644\n' + end)
    .has('com.atomicservice.6917587889453404644'), true);
});
test('6.1 bundle dump exposes the installed identity without treating malformed output as absence', async () => {
  const f = fixture();
  f.detail = bundle + ':\n' + JSON.stringify({ name: bundle, versionCode: 110003,
    appIdentifier: 'registered-app-id',
    applicationInfo: { fingerprint: 'ab'.repeat(32) } });
  const identity = await f.bridge.installedSigningIdentity(bundle);
  assert.equal(identity.versionCode, 110003);
  assert.equal(identity.fingerprint, 'AB'.repeat(32));
  assert.equal(identity.appIdentifier, 'registered-app-id');
  f.detail = '[Fail] connection closed';
  assert.equal(await f.bridge.installedSigningIdentity(bundle), undefined);
});
test('detected exact version finishes an old paused task without starting an installation', async () => {
  const { InstallStage, InstallJob } = load('jobs/InstallJob');
  const row = new InstallJob(); row.id = 'old'; row.appId = 1;
  row.bundleName = bundle; row.versionCode = 110003;
  row.stage = InstallStage.RETRYABLE_ERROR; row.lastError = '上次安装中断了';
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private async reconcileDetectedJobs(');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const saved = [];
  const sandbox = { InstallStage, getContext: () => ({}), isPending: s => s !== InstallStage.INSTALLED,
    ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate(),
    InstalledAppRegistry: { versionName: () => '' },
    JobScheduler: { isRunning: () => false },
    JobStore: { open: async () => ({ get: async () => row, save: async value => saved.push(value) }) } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page(); ui.installTasks = [{ job: row, running: false }]; ui.installedJobs = [];
  await ui.reconcileDetectedJobs(new Map([[bundle, 110002]])); assert.equal(saved.length, 0);
  await ui.reconcileDetectedJobs(new Map([[bundle, 110003]]));
  assert.equal(saved[0].stage, InstallStage.INSTALLED); assert.equal(saved[0].lastError, '');
  // 本地导入可能是同版本重装、修复内包，不能被首次扫描直接判为完成。
  saved.length = 0; row.appId = 0; row.sourceUrl = 'local';
  row.stage = InstallStage.WAITING_DEVICE;
  await ui.reconcileDetectedJobs(new Map([[bundle, 110003]]));
  assert.equal(saved.length, 0); assert.equal(row.stage, InstallStage.WAITING_DEVICE);
});
test('opening an external app resolves its real module and ability instead of using bundle only', async () => {
  const f = fixture(); const wants = [];
  f.detail = JSON.stringify({ name: bundle, versionCode: 110003, entryModuleName: 'entry',
    hapModuleInfos: [{ moduleName: 'entry', mainAbility: 'EntryAbility' }] });
  f.bridge.context = { startAbility: async want => wants.push(want) };
  await f.bridge.openApp(bundle);
  assert.equal(wants.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(wants[0])), {
    bundleName: bundle, moduleName: 'entry', abilityName: 'EntryAbility'
  });
  const queries = f.calls.length;
  await f.bridge.openApp(bundle); assert.equal(f.calls.length, queries);
});
test('known launch information works without wireless debugging; unknown entry is not guessed', async () => {
  const f = fixture(); const wants = [];
  f.bridge.context = { startAbility: async want => wants.push(want) };
  await f.bridge.openApp(bundle, 'entry', 'ActualMainAbility');
  assert.equal(wants[0].abilityName, 'ActualMainAbility'); assert.equal(f.calls.length, 0);
  await assert.rejects(f.bridge.openApp(bundle), /启动入口/);
  assert.equal(wants.length, 1);
});
test('Discover and Management use the same resolved launch path as Detail for an external install', async () => {
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const methods = ['openCatalogApp', 'openInstalled'].map(name => {
    const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const calls = [];
  const sandbox = {
    getContext: () => ({ startAbility: () => { throw Error('bundle-only launch is invalid'); } }),
    HdcDeviceBridge: class {
      async openApp(...args) { calls.push(args); }
    }, errorText: e => e.message
  };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page();
  const row = { bundleName: bundle, moduleName: '', mainAbility: '' };
  ui.installedJobFor = () => row;
  ui.openCatalogApp({ id: 1 });
  await new Promise(resolve => setImmediate(resolve));
  await ui.openInstalled(row);
  assert.deepEqual(calls, [[bundle, '', ''], [bundle, '', '']]);
  assert.equal(ui.jobsError, '');
});

test('HDC unsigned and unauthorized errors are rejected even inside an Info response', async () => {
  const f = fixture();
  f.bridge.command = async () => '[Info]App install path:x.hap msg:error: failed to install bundle. code:9568423 error: device is unauthorized. AppMod finish';
  const io = f.bridge;
  const src = fs.readFileSync(path.join(root, 'jobs/HdcDeviceBridge.ets'), 'utf8');
  const start = src.indexOf('  async install(signedHapPath');
  const helperStart = src.indexOf('  private async observedCommand');
  const method = src.slice(start, src.indexOf('\n  }', start) + 4) + '\n' +
    src.slice(helperStart, src.indexOf('\n  }', helperStart) + 4);
  const sandbox = { fileIo: { accessSync: () => true } };
  vm.runInNewContext(ts.transpileModule(`class Bridge { ${method} }; globalThis.Bridge = Bridge;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const bridge = new sandbox.Bridge(); bridge.context = { filesDir: '/sandbox' };
  bridge.connected = async () => true; bridge.command = io.command;
  await assert.rejects(bridge.install('/sandbox/app.hap'), /9568423/);
});

test('scanned signing identity survives restart and is invalidated by a new version, uninstall or incomplete signing evidence', async () => {
  const disk = new Map(), mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback, put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  const first = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry;
  first.remember(bundle, 110003);
  const output = JSON.stringify({ name: bundle, versionCode: 110003, updateTime: 1700000000000,
    applicationInfo: { fingerprint: 'A'.repeat(64) }, appIdentifier: 'stable' });
  first.rememberLauncher(output, bundle); await first.persist({});
  const restored = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry; await restored.load({});
  assert.equal(restored.signingIdentity(bundle).fingerprint, 'A'.repeat(64));
  assert.equal(restored.signingIdentity(bundle).updateTime, 1700000000000);
  restored.remember(bundle, 110004); assert.equal(restored.signingIdentity(bundle), undefined);
  restored.remember(bundle, 110003); restored.rememberLauncher(output, bundle);
  restored.rememberLauncher(JSON.stringify({ name: bundle, versionCode: 110003 }), bundle);
  assert.equal(restored.signingIdentity(bundle), undefined);
  restored.rememberLauncher(output, bundle); restored.remember(bundle, 0); await restored.persist({});
  const deleted = load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry; await deleted.load({});
  assert.equal(deleted.signingIdentity(bundle), undefined);
});

function originFixture() {
  const disk = new Map(), mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } };
  return { disk, mocks, registry: load('jobs/InstalledAppRegistry', mocks).InstalledAppRegistry };
}
const rockBundle = 'com.nrc.huawei';
function rockDump({ version = 111112, updateTime = Date.now() - 5000, distribution = 'app_gallery',
  provision = 'release', source = 'com.huawei.hmsapp.appgallery' } = {}) {
  return JSON.stringify({ name: rockBundle, versionCode: version, versionName: '1.111.0.112', updateTime,
    applicationInfo: { appDistributionType: distribution, appProvisionType: provision, installSource: source } });
}

test('official AppGallery source is version-bound and survives restart independently of catalog metadata', async () => {
  const f = originFixture(); f.registry.observe(rockDump(), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), true); assert.equal(f.registry.hasApplicationOrigin(rockBundle), true);
  await f.registry.persist({});
  const restarted = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry;
  await restarted.load({}); assert.equal(restarted.isAppGallery(rockBundle), true);
  assert.equal(restarted.hasApplicationOrigin(rockBundle), true);
  restarted.remember(rockBundle, 111113);
  assert.equal(restarted.isAppGallery(rockBundle), false, 'a different build cannot inherit prior source');
  assert.equal(restarted.hasApplicationOrigin(rockBundle), false);
  restarted.remember(rockBundle, 0); assert.equal(restarted.isAppGallery(rockBundle), false);
});

test('ordinary version observations preserve reliable origin, while a same-code replacement refreshes it', () => {
  const f = originFixture(), at = Date.now() - 10000;
  f.registry.observe(rockDump({ updateTime: at }), rockBundle);
  f.registry.remember(rockBundle, 111112);
  assert.equal(f.registry.isAppGallery(rockBundle), true);
  f.registry.rememberApplicationInfo(rockBundle, 111112, '1.111.0.112', '', '', '', at);
  assert.equal(f.registry.isAppGallery(rockBundle), true, 'an incomplete query is not contrary source evidence');
  f.registry.observe(rockDump({ updateTime: at + 1000, distribution: 'none', provision: 'debug', source: 'shell' }), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), false, 'side-loaded same-code build can rejoin matching');
  assert.equal(f.registry.hasApplicationOrigin(rockBundle), true);
  f.registry.observe(rockDump({ updateTime: at + 2000 }), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), true, 'official reinstall replaces side-load origin again');
});

test('changed installation timestamp without application metadata invalidates an old origin instead of carrying it forward', () => {
  const f = originFixture(), at = Date.now() - 10000;
  f.registry.observe(rockDump({ updateTime: at }), rockBundle);
  f.registry.observe(JSON.stringify({ name: rockBundle, versionCode: 111112, updateTime: at + 1000 }), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), false); assert.equal(f.registry.hasApplicationOrigin(rockBundle), false);
  f.registry.observe(rockDump({ updateTime: at + 2000 }), rockBundle);
  f.registry.rememberApplicationInfo(rockBundle, 111112, '1.111.0.112', '', '', '', at + 3000);
  assert.equal(f.registry.isAppGallery(rockBundle), false); assert.equal(f.registry.hasApplicationOrigin(rockBundle), false);
});

test('legacy unknown origin remains compatible with side loads; explicit install source is guarded by provision type', async () => {
  const f = originFixture();
  f.disk.set('last-confirmed', JSON.stringify([{ bundleName: rockBundle, version: 111112,
    at: Date.now() - 1000, installationUpdateTime: Date.now() - 1000 }]));
  await f.registry.load({}); assert.equal(f.registry.isAppGallery(rockBundle), false);
  assert.equal(f.registry.hasApplicationOrigin(rockBundle), false);
  f.registry.rememberApplicationInfo(rockBundle, 111112, '', '', 'release', 'com.huawei.appmarket');
  assert.equal(f.registry.isAppGallery(rockBundle), true);
  f.registry.rememberApplicationInfo(rockBundle, 111112, '', 'none', 'debug', 'com.huawei.appmarket');
  assert.equal(f.registry.isAppGallery(rockBundle), false, 'debug evidence overrides the last installer package');
  f.registry.rememberApplicationInfo(rockBundle, 111112, '', 'app_gallery', 'debug', 'com.huawei.hmsapp.appgallery');
  assert.equal(f.registry.isAppGallery(rockBundle), false, 'a real debug Profile overrides leftover distribution metadata');
  assert.equal(f.registry.hasApplicationOrigin(rockBundle), true);
  await f.registry.persist({});
  const debugRestart = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry; await debugRestart.load({});
  assert.equal(debugRestart.isAppGallery(rockBundle), false);
  assert.equal(debugRestart.hasApplicationOrigin(rockBundle), true);
  const saved = { bundleName: rockBundle, version: 111112, at: Date.now() - 1000,
    installationUpdateTime: 1700000000001, distributionVersion: 111112, distributionUpdateTime: 1700000000000,
    appDistributionType: 'app_gallery' };
  f.disk.set('last-confirmed', JSON.stringify([saved]));
  const restarted = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry; await restarted.load({});
  assert.equal(restarted.isAppGallery(rockBundle), false, 'a saved source for another installation is not trusted');
  assert.equal(restarted.hasApplicationOrigin(rockBundle), false);
});

test('replacement preflight obtains the real official app label only when it is missing', async () => {
  const f = originFixture(), calls = [];
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    './InstalledAppRegistry': { InstalledAppRegistry: f.registry }
  });
  const bridge = new HdcDeviceBridge({}); bridge.connected = async () => true;
  const official = JSON.parse(rockDump()); official.appIdentifier = 'TencentRockOfficial';
  bridge.command = async (operation, name) => {
    calls.push([operation, name]);
    return operation === 14 ? '洛克王国：世界\n' : JSON.stringify(official);
  };
  const identity = await bridge.installedSigningIdentity(rockBundle);
  assert.equal(identity.versionCode, 111112); assert.equal(identity.appIdentifier, 'TencentRockOfficial');
  assert.equal(f.registry.displayName(rockBundle), '洛克王国：世界');
  assert.deepEqual(calls, [[3, rockBundle], [14, rockBundle]]);
  await bridge.installedSigningIdentity(rockBundle);
  assert.equal(calls.filter(([operation]) => operation === 14).length, 1, 'the cached real label needs no extra lookup');
  await f.registry.persist({});
  const restored = load('jobs/InstalledAppRegistry', f.mocks).InstalledAppRegistry; await restored.load({});
  assert.equal(restored.displayName(rockBundle), '洛克王国：世界');
});

test('preflight label failure preserves verified identity and sideloads never issue the additional label query', async () => {
  for (const label of [undefined, '[Fail] label lookup denied', 'incorrect\nmultiline']) {
    const f = originFixture(), calls = [];
    const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
      './InstalledAppRegistry': { InstalledAppRegistry: f.registry }
    });
    const bridge = new HdcDeviceBridge({}); bridge.connected = async () => true;
    const official = JSON.parse(rockDump()); official.appIdentifier = 'TencentRockOfficial';
    bridge.command = async operation => {
      calls.push(operation);
      if (operation === 14) { if (label === undefined) throw Error('resource unavailable'); return label; }
      return JSON.stringify(official);
    };
    assert.equal((await bridge.installedSigningIdentity(rockBundle)).appIdentifier, 'TencentRockOfficial');
    assert.equal(f.registry.displayName(rockBundle), '');
    official.applicationInfo.appProvisionType = 'debug';
    assert.equal((await bridge.installedSigningIdentity(rockBundle)).versionCode, 111112);
    assert.deepEqual(calls, [3, 14, 3]);
  }
});

test('old source snapshots and installation times cannot replace a newer observation', () => {
  const f = originFixture(), at = Date.now() - 10000;
  f.registry.rememberApplicationInfo(rockBundle, 111113, 'new-build', 'none', 'debug', 'shell', at + 1000);
  assert.equal(f.registry.rememberApplicationInfo(rockBundle, 111112, 'old-build', 'app_gallery', 'release',
    'com.huawei.hmsapp.appgallery', at), false);
  assert.equal(f.registry.version(rockBundle), 111113); assert.equal(f.registry.isAppGallery(rockBundle), false);
  assert.equal(f.registry.installationTime(rockBundle, 111113), at + 1000);
  assert.throws(() => f.registry.observe(rockDump({ version: 111112, updateTime: at }), rockBundle), /更新的查询/);
  f.registry.rememberLauncher(rockDump({ version: 111113, updateTime: at }), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), false); assert.equal(f.registry.installationTime(rockBundle, 111113), at + 1000);
});

test('official label is invalidated after a same-bundle debug replacement, even with the same version code', () => {
  const f = originFixture(), at = Date.now() - 10000;
  f.registry.observe(rockDump({ updateTime: at }), rockBundle); f.registry.rememberDisplayName(rockBundle, '洛克王国：世界');
  f.registry.observe(rockDump({ updateTime: at + 1000, distribution: 'none', provision: 'debug', source: 'shell' }), rockBundle);
  assert.equal(f.registry.isAppGallery(rockBundle), false); assert.equal(f.registry.displayName(rockBundle), '');
  f.registry.rememberDisplayName(rockBundle, '米哈游启动器');
  f.registry.remember(rockBundle, 111113); assert.equal(f.registry.displayName(rockBundle), '');
});

test('a late signing preflight cannot approve an old identity or replace the newer observed source', async () => {
  const f = originFixture(); let reply, started;
  const entered = new Promise(resolve => started = resolve);
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', { './InstalledAppRegistry': { InstalledAppRegistry: f.registry } });
  const bridge = new HdcDeviceBridge({}); bridge.connected = async () => true;
  bridge.command = async () => { started(); return new Promise(resolve => reply = resolve); };
  const pending = bridge.installedSigningIdentity(rockBundle); await entered;
  const at = Date.now() - 1000;
  f.registry.rememberApplicationInfo(rockBundle, 111113, 'new-device-build', 'none', 'debug', 'shell', at);
  const old = JSON.parse(rockDump({ updateTime: at - 1000 })); old.appIdentifier = 'OldOfficialIdentity';
  reply(JSON.stringify(old));
  await assert.rejects(pending, /应用状态已变化/);
  assert.equal(f.registry.version(rockBundle), 111113); assert.equal(f.registry.isAppGallery(rockBundle), false);
});

test('an official label lookup cannot write its old name into a replacement installed during the lookup', async () => {
  const f = originFixture(); let reply, started;
  const entered = new Promise(resolve => started = resolve);
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', { './InstalledAppRegistry': { InstalledAppRegistry: f.registry } });
  const bridge = new HdcDeviceBridge({}); bridge.connected = async () => true;
  const at = Date.now() - 10000, old = JSON.parse(rockDump({ updateTime: at })); old.appIdentifier = 'OldOfficialIdentity';
  bridge.command = async operation => operation === 3 ? JSON.stringify(old) :
    (started(), new Promise(resolve => reply = resolve));
  const pending = bridge.installedSigningIdentity(rockBundle); await entered;
  f.registry.rememberApplicationInfo(rockBundle, 111113, 'new-device-build', 'none', 'debug', 'shell', at + 1000);
  f.registry.rememberDisplayName(rockBundle, '米哈游启动器'); reply('洛克王国：世界');
  await assert.rejects(pending, /应用状态已变化/);
  assert.equal(f.registry.displayName(rockBundle), '米哈游启动器'); assert.equal(f.registry.isAppGallery(rockBundle), false);
});
