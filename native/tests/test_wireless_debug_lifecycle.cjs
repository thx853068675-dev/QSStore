const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve };
}
function fixture() {
  const f = { jobs: [], rows: [], running: [], linked: true, busy: false, releases: 0,
    restores: [], resumed: [], storage: new Map(), reads: () => Promise.resolve(f.jobs) };
  const Bridge = class {
    static busy() { return f.busy; }
    static deviceLinked() { return f.linked; }
    static setIdleHandler(callback) { f.idle = callback; }
    static async releaseWhenIdle(allowed) {
      if (!f.busy && allowed()) { f.linked = false; f.releases++; return true; } return false;
    }
    restoreSavedLink(allowed) {
      const work = deferred(); f.restores.push({ allowed, ...work });
      return work.promise.then(linked => { if (linked) f.linked = true; return linked; });
    }
  };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/WirelessDebugLifecycle.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, AppStorage: {
    get: key => f.storage.get(key), setOrCreate: (key, value) => f.storage.set(key, value) },
    require: name => ({
      './ForegroundIdle': { ForegroundIdle: { defer: (_key, fn) => fn(), cancel() {} } },
      './HdcDeviceBridge': { HdcDeviceBridge: Bridge },
      './JobStore': { JobStore: { open: async () => ({ listAll: () => f.reads() }) } },
      './JobScheduler': { JobScheduler: { runningJobIds: () => f.running } },
      './InstallTaskState': { InstallTaskState: {
        snapshot: () => f.rows, subscribe: callback => { f.changed = callback; return 1; } } },
      './InstallJob': { InstallStage: { WAITING_DEVICE: 'waiting_device' } },
      './RecoveryPlanner': { isPending: stage => stage !== 'installed' && stage !== 'terminal_error' },
      './InstallCoordinator': { InstallCoordinator: {
        conditionReady: async (_, stage) => { f.resumed.push(stage); } } }
    })[name] || {} });
  f.lifecycle = exports.WirelessDebugLifecycle; f.lifecycle.configure({}); return f;
}
test('background with no tasks releases the idle device link', async () => {
  const f = fixture(); f.lifecycle.onBackground(); await tick();
  assert.equal(f.releases, 1); assert.equal(f.linked, false);
});
test('a foreground return cancels a late background database check', async () => {
  const f = fixture(), read = deferred(); f.reads = () => read.promise;
  f.lifecycle.onBackground(); await tick(); f.lifecycle.onForeground();
  read.resolve([]); f.restores[0].resolve(true); await tick();
  assert.equal(f.releases, 0); assert.equal(f.storage.get('wirelessLinkRevision'), 1);
});
test('running work and durable pending tasks protect the link in background', async () => {
  const f = fixture(); f.running = ['task']; f.lifecycle.onBackground(); await tick();
  assert.equal(f.releases, 0);
  f.running = []; f.jobs = [{ stage: 'queued' }]; f.changed(); await tick();
  assert.equal(f.releases, 0);
  f.jobs = []; f.changed(); await tick(); assert.equal(f.releases, 1);
});
test('a scan/native operation keeps the link until its idle signal', async () => {
  const f = fixture(); f.busy = true; f.lifecycle.onBackground(); await tick();
  assert.equal(f.releases, 0);
  f.busy = false; f.idle(); await tick(); assert.equal(f.releases, 1);
});
test('foreground reconnect coalesces events and wakes device-paused tasks only on success', async () => {
  const f = fixture(); f.lifecycle.onForeground(); f.lifecycle.onForeground();
  assert.equal(f.restores.length, 1); assert.equal(f.storage.get('wirelessDebugRestoring'), true);
  assert.equal(f.restores[0].allowed(), true);
  f.restores[0].resolve(true); await tick();
  assert.equal(f.storage.get('wirelessDebugRestoring'), false);
  assert.deepEqual(f.resumed, ['waiting_device']); assert.equal(f.storage.get('wirelessLinkRevision'), 1);
  f.lifecycle.onForeground(); f.restores[1].resolve(false); await tick();
  assert.equal(f.resumed.length, 1); assert.equal(f.storage.get('wirelessLinkRevision'), 1);
});
test('a connection completing after background does not publish a stale foreground success', async () => {
  const f = fixture(); f.linked = false; f.lifecycle.onForeground(); f.lifecycle.onBackground();
  assert.equal(f.restores[0].allowed(), false);
  f.restores[0].resolve(true); await tick(); await tick();
  assert.equal(f.storage.get('wirelessLinkRevision'), undefined);
  assert.equal(f.resumed.length, 0); assert.equal(f.releases, 1);
});
test('rapid background and foreground transitions schedule one fresh restore after the stale one', async () => {
  const f = fixture(); f.linked = false; f.lifecycle.onForeground(); f.lifecycle.onBackground();
  f.lifecycle.onForeground(); f.restores[0].resolve(false); await tick();
  assert.equal(f.restores.length, 2); assert.equal(f.restores[1].allowed(), true);
  f.restores[1].resolve(true); await tick();
  assert.equal(f.storage.get('wirelessLinkRevision'), 1); assert.equal(f.resumed.length, 1);
});
