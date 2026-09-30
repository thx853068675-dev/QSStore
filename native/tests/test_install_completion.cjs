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
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, { exports, require: name => mocks[name] || {} });
  return exports;
}
const { InstallStage, InstallJob } = load('jobs/InstallJob');
function localBundles() {
  const f = { external: 0, cached: -1,
    self: { name: 'com.example.installer', versionCode: 2 } };
  const bundleManager = { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    getBundleInfoForSelfSync: () => f.self,
    getBundleInfoSync: () => { f.external++; throw { code: 201 }; } };
  f.LocalBundles = load('jobs/LocalBundles', { '@kit.AbilityKit': { bundleManager },
    './InstalledAppRegistry': { InstalledAppRegistry: { version: () => f.cached } } }).LocalBundles;
  return f;
}
test('self version is readable without bundle permission or wireless debugging', () => {
  const f = localBundles();
  assert.equal(f.LocalBundles.installedVersion('com.example.installer'), 2);
  assert.equal(f.external, 0);
  assert.equal(f.LocalBundles.installedVersion('com.example.other'), -1);
  assert.equal(f.external, 1);
});
test('self display name comes from the installed package and is not assigned to an older build', () => {
  const f = localBundles(); f.self.versionName = '0.4.48';
  assert.equal(f.LocalBundles.installedVersionName('com.example.installer', 2), '0.4.48');
  assert.equal(f.LocalBundles.installedVersionName('com.example.installer', 1), '');
  assert.equal(f.external, 0);
  assert.equal(f.LocalBundles.installedVersionName('com.example.other', 2), '');
});
function fixture() {
  const f = localBundles(); f.jobs = []; f.saved = []; f.probes = 0;
  f.remoteVersion = -1; f.running = new Set();
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private async reconcileInterruptedInstalls(');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const code = ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const sandbox = { InstallStage, LocalBundles: f.LocalBundles, getContext: () => ({}),
    JobScheduler: { isRunning: id => f.running.has(id) },
    JobStore: { open: async () => ({ listAll: async () => f.jobs,
      save: async job => f.saved.push(JSON.parse(JSON.stringify(job))) }) },
    HdcDeviceBridge: class { async installedVersion() {
      f.probes++; if (f.remoteVersion < 0) throw Error('offline');
      return f.remoteVersion;
    } } };
  vm.runInNewContext(code, sandbox); f.ui = new sandbox.Page();
  f.ui.loadJobs = async () => {};
  return f;
}
function job(stage = InstallStage.INSTALLING, name = 'com.example.installer') {
  const value = new InstallJob(); value.id = name; value.bundleName = name; value.versionCode = 2;
  value.stage = stage; value.stageHistory = [{ stage: InstallStage.INSTALLING, at: 1 }];
  return value;
}
test('restart confirms self update without installing again, including earlier waiting/error records', async () => {
  for (const stage of [InstallStage.INSTALLING, InstallStage.WAITING_DEVICE, InstallStage.RETRYABLE_ERROR]) {
    const f = fixture(); f.jobs = [job(stage)];
    await f.ui.reconcileInterruptedInstalls();
    assert.equal(f.saved[0].stage, InstallStage.INSTALLED); assert.equal(f.saved[0].lastError, '');
    assert.equal(f.probes, 0);
  }
});
test('an unconfirmed remote version stays pending and can be confirmed on a later foreground pass', async () => {
  const f = fixture(); f.jobs = [job(InstallStage.INSTALLING, 'com.example.other')];
  await f.ui.reconcileInterruptedInstalls();
  assert.equal(f.saved[0].stage, InstallStage.WAITING_DEVICE);
  f.self = { name: 'com.example.other', versionCode: 2 };
  await f.ui.reconcileInterruptedInstalls();
  assert.equal(f.saved[1].stage, InstallStage.INSTALLED);
});
test('reconciliation does not finish active tasks, jobs never installed, or a mismatched version', async () => {
  const f = fixture(); const active = job(); f.running.add(active.id);
  const untouched = job(InstallStage.WAITING_DEVICE, 'com.example.untouched'); untouched.stageHistory = [];
  f.jobs = [active, untouched]; await f.ui.reconcileInterruptedInstalls(); assert.equal(f.saved.length, 0);
  f.running.clear(); f.jobs = [active]; f.self.versionCode = 1;
  await f.ui.reconcileInterruptedInstalls(); assert.equal(f.saved[0].stage, InstallStage.RETRYABLE_ERROR);
});
test('reconciliation ignores a stale display version and confirms the actual installed version', async () => {
  const f = fixture(); f.cached = 1; f.remoteVersion = 2;
  f.jobs = [job(InstallStage.INSTALLING, 'com.example.other')];
  await f.ui.reconcileInterruptedInstalls();
  assert.equal(f.probes, 1);
  assert.equal(f.saved[0].stage, InstallStage.INSTALLED);
});
test('runtime confirms installed version locally and only uses HDC when the system cannot answer', async () => {
  const f = localBundles(); let probes = 0;
  const { NativeJobRuntime } = load('jobs/NativeJobRuntime', { './LocalBundles': { LocalBundles: f.LocalBundles } });
  const runtime = new NativeJobRuntime({}, {}, undefined, {
    installedVersion: async () => { probes++; return 3; }
  });
  assert.equal(await runtime.installedVersion('com.example.installer'), 2); assert.equal(probes, 0);
  assert.equal(await runtime.installedVersion('com.example.other'), 3); assert.equal(probes, 1);
  f.cached = 1;
  assert.equal(f.LocalBundles.installedVersion('com.example.other'), 1);
  assert.equal(await runtime.installedVersion('com.example.other'), 3);
  assert.equal(probes, 2, 'a stale display cache must not trigger a second installation');
});
