const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, console });
  return exports;
}
const bundle = 'com.tonghongxiang.quietstart';
const names = 'ID: 100:\n\tcom.tonghongxiang.hapstore\n\t' + bundle + '\n';
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
  assert.equal(afterRemoval.version(bundle), -1);
  assert.equal(afterRemoval.launcher(bundle), undefined);
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
function fixture() {
  const { InstalledAppRegistry: registry } = load('jobs/InstalledAppRegistry');
  const f = { calls: [], detail: JSON.stringify({ name: bundle, versionCode: 110003, versionName: '1.1.0' }), list: names };
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    './InstalledAppRegistry': { InstalledAppRegistry: registry }
  });
  f.bridge = new HdcDeviceBridge({ filesDir: '/sandbox' });
  f.bridge.connected = async () => true;
  f.bridge.command = async (op, arg) => { f.calls.push([op, arg]); return op === 6 ? f.list : f.detail; };
  f.registry = registry; return f;
}
test('real 6.1 list format only proves presence; requested versions come from package details', async () => {
  const f = fixture(); const values = await f.bridge.installedBundleVersions([bundle, bundle]);
  assert.equal(values.get(bundle), 110003); assert.equal(f.registry.version(bundle), 110003);
  assert.equal(f.calls.length, 2); assert.equal(f.calls[0][0], 6); assert.equal(f.calls[1][0], 3);
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
    JobScheduler: { isRunning: () => false },
    JobStore: { open: async () => ({ get: async () => row, save: async value => saved.push(value) }) } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page(); ui.installTasks = [{ job: row, running: false }];
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
  const method = src.slice(start, src.indexOf('\n  }', start) + 4);
  const sandbox = { fileIo: { accessSync: () => true } };
  vm.runInNewContext(ts.transpileModule(`class Bridge { ${method} }; globalThis.Bridge = Bridge;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const bridge = new sandbox.Bridge(); bridge.context = { filesDir: '/sandbox' };
  bridge.connected = async () => true; bridge.command = io.command;
  await assert.rejects(bridge.install('/sandbox/app.hap'), /9568423/);
});
