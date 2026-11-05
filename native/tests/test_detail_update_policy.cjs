const { DeviceInstallTarget } = require('./load_ets.cjs').loadEts('jobs/DeviceInstallTarget');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
const names = ['restoreUpdatePolicy', 'syncUpdatePolicy', 'updateAvailable', 'installButtonLabel', 'installButtonEnabled', 'downloadSelected'];
const methods = names.map(name => {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.notEqual(start, -1, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}).join('\n');
const code = ts.transpileModule('class Detail {' + methods + '};globalThis.Page=Detail;', {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;
function fixture() {
  const f = { paused: new Set(), enqueued: [], notified: [], queued: 0 };
  const box = { MultiDeviceTargets:{snapshots:()=>['']}, MultiDeviceInstall:{enqueue:async(_store,job)=>[job]}, DeviceInstallTarget,
    getContext: () => ({ filesDir: '/sandbox' }), errorText: e => e.message, console: { warn() {} },
    InstallDeviceCompatibility: { confirm: async () => { if (f.deviceWait) await f.deviceWait; return f.deviceDecision !== false; },
      confirmedFingerprint: () => '' },
    UpdatePolicy: { restore: async () => { if (f.restoreWait) await f.restoreWait; if (f.failRestore) throw Error('read failed'); },
      disabled: bundle => f.paused.has(bundle) },
    ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate({ INSTALLED: 'installed' }),
    InstalledAppRegistry: { isAppGallery: () => false, versionName: () => '1.0.0', signingIdentity: () => undefined },
    InstallTaskState: { label: () => '下载中' }, isPending: stage => stage === 'downloading',
    InstallStage: { QUEUED: 'queued', INSTALLED: 'installed' },
    JobStore: { open: async () => { if (f.openWait) await f.openWait; return { save:async()=>{}, enqueue: async (...args) => {
      f.enqueued.push(args); return { id: 'queued', stage: 'queued' };
    } }; } }, InstallCoordinator: { recovered: () => f.queued++ }
  };
  vm.runInNewContext(code, box);
  f.installed = { bundleName: 'com.example.app', versionCode: 1, versionName: '1.0.0' };
  f.ui = Object.assign(new box.Page(), {
    installTargetCount:1,updatePolicyReady: true, updatesPaused: false, explicitSelection: false, disposed: false,
    app: { id: 7 }, selectedAsset: { name: 'app.hap', url: 'https://example.com/app.hap',
      bundleName: 'com.example.app', versionCode: 2, versionName: '2.0.0', sha256: 'a'.repeat(64), mirrorUrls: [] },
    installedJobs: [], installedVersion: 1, installedUnknown: false, releaseLoading: false,
    selectedBundleName() { return this.selectedAsset.bundleName; }, installedForApp: () => f.installed,
    currentInstallTask: () => f.task, selectedDowngrade: () => false,
    selectedVersionLabel: () => '2.0.0', notify: text => f.notified.push(text), syncInstallTask() {}
  });
  return f;
}
test('default detail hides a paused update while restore and explicit version selection stay available', async () => {
  const f = fixture(); assert.equal(f.ui.installButtonLabel(), '更新到 2.0.0');
  f.paused.add('com.example.app'); f.ui.syncUpdatePolicy();
  assert.equal(f.ui.updateAvailable(), false); assert.equal(f.ui.installButtonLabel(), '打开应用');
  f.ui.explicitSelection = true;
  assert.equal(f.ui.updateAvailable(), true, 'an explicit user-selected release can still be installed');
  await f.ui.downloadSelected(); assert.equal(f.enqueued.length, 1); assert.equal(f.queued, 1);
  assert.equal(f.paused.has('com.example.app'), true, 'manual installation must not silently restore automatic updates');
  f.ui.explicitSelection = false; f.paused.delete('com.example.app'); f.ui.syncUpdatePolicy();
  assert.equal(f.ui.installButtonLabel(), '更新到 2.0.0');
});
test('a stop during journal opening cannot enqueue a stale default update, including unknown installed state', async () => {
  for (const unknown of [false, true, 'no-receipt']) {
    const f = fixture(); f.ui.installedUnknown = Boolean(unknown); f.ui.installedVersion = unknown ? 0 : 1;
    if (unknown === 'no-receipt') f.installed = undefined;
    let finish; f.openWait = new Promise(done => finish = done);
    const pending = f.ui.downloadSelected(); await new Promise(setImmediate);
    f.paused.add('com.example.app'); finish(); await pending;
    assert.equal(f.enqueued.length, 0); assert.equal(f.queued, 0); assert.equal(f.ui.downloadBusy, false);
    assert.match(f.notified.at(-1), /已停更/);
    if (unknown === 'no-receipt') {
      f.ui.syncUpdatePolicy();
      assert.equal(f.ui.installButtonLabel(), '已停更');
      assert.equal(f.ui.installButtonEnabled(), false);
      f.ui.explicitSelection = true;
      assert.equal(f.ui.installButtonEnabled(), true);
      await f.ui.downloadSelected();
      assert.equal(f.enqueued.length, 1, 'explicit choice can install when local state is unknown');
    }
  }
});
test('confirmed uninstall permits a new installation and a different bundle keeps its own update policy', async () => {
  const f = fixture(); f.paused.add('com.example.app'); f.installed = undefined;
  f.ui.installedVersion = 0; f.ui.syncUpdatePolicy();
  assert.equal(f.ui.installButtonLabel(), '安装应用');
  await f.ui.downloadSelected(); assert.equal(f.enqueued.length, 1);
  f.installed = { bundleName: 'com.example.other', versionCode: 1 };
  f.ui.selectedAsset = { ...f.ui.selectedAsset, bundleName: 'com.example.other' };
  f.ui.installedVersion = 1; f.ui.syncUpdatePolicy();
  assert.equal(f.ui.updatesPaused, false); assert.equal(f.ui.installButtonLabel(), '更新到 2.0.0');
});
test('existing pending progress remains visible for a paused app', () => {
  const f = fixture(); f.paused.add('com.example.app'); f.ui.syncUpdatePolicy();
  f.task = { running: false, job: { stage: 'downloading' } };
  assert.equal(f.ui.installButtonLabel(), '下载中 · 继续');
  f.task.running = true; assert.equal(f.ui.installButtonLabel(), '下载中');
});
test('detail compatibility cancellation creates no task; continue still rechecks the current update policy', async () => {
  const f = fixture(); f.deviceDecision = false;
  await f.ui.downloadSelected();
  assert.equal(f.enqueued.length, 0); assert.equal(f.queued, 0); assert.equal(f.ui.downloadBusy, false);
  assert.equal(f.notified.includes('正在下载安装包'), false);
  f.deviceDecision = true; await f.ui.downloadSelected(); assert.equal(f.enqueued.length, 1);
  const paused = fixture(); let finish; paused.deviceWait = new Promise(done => finish = done);
  const pending = paused.ui.downloadSelected(); await new Promise(setImmediate);
  paused.paused.add('com.example.app'); finish(); await pending;
  assert.equal(paused.enqueued.length, 0, 'accepting compatibility must not bypass a newly paused bundle');
});
test('unreadable preferences suppress a default update until a successful retry without affecting explicit installation', async () => {
  const f = fixture(); f.failRestore = true; await f.ui.restoreUpdatePolicy();
  assert.equal(f.ui.updatePolicyReady, false); assert.equal(f.ui.installButtonLabel(), '打开应用');
  f.failRestore = false; await f.ui.restoreUpdatePolicy();
  assert.equal(f.ui.updatePolicyReady, true); assert.equal(f.ui.installButtonLabel(), '更新到 2.0.0');
  const disposed = fixture(); let finish; disposed.restoreWait = new Promise(done => finish = done);
  disposed.ui.updatePolicyReady = false; const pending = disposed.ui.restoreUpdatePolicy();
  disposed.ui.disposed = true; finish(); await pending; assert.equal(disposed.ui.updatePolicyReady, false);
});
