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
    remote:false,nativeBusy:false,timers:new Map(), restores: [], resumed: [], storage: new Map(), reads: () => Promise.resolve(f.jobs) };
  const Bridge = class {
    static busy() { return f.busy; }
    static deviceLinked() { return f.linked; }
    static cancelDiscovery(){}
    static hasSessions(){return f.linked||f.remote;}
    static releasePending=false;
    static setIdleHandler(callback) { f.idle = callback; }
    static async releaseWhenIdle(allowed) {
      if(f.nativeBusy){Bridge.releasePending=true;return false;}
      if(!f.busy&&allowed()){Bridge.releasePending=false;if(f.linked||f.remote)f.releases++;f.linked=false;f.remote=false;return true;}return false;
    }
    async savedPort(){return 54321;}
    restoreSavedLink(allowed) {
      const work = deferred(); f.restores.push({ allowed, ...work });
      return work.promise.then(linked => { if (linked) f.linked = true; return linked; });
    }
  };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/WirelessDebugLifecycle.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, setTimeout:fn=>{const id=f.timers.size+1;f.timers.set(id,fn);return id;},clearTimeout:id=>f.timers.delete(id),AppStorage: {
    get: key => f.storage.get(key), setOrCreate: (key, value) => f.storage.set(key, value) },
    require: name => ({
      './DeviceNetwork':{DeviceNetwork:{signature:'wifi-1',subscribe:()=>1}},
      './FixedDebugPort': { FixedDebugPort: { configure() {}, idle() {}, onForeground() {}, onBackground() {} } },
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
test('foreground return prevents background release and cancels a queued busy-release retry',async()=>{
 const f=fixture();f.nativeBusy=true;f.lifecycle.onBackground();await tick();assert.equal(f.timers.size,1);
 f.lifecycle.onForeground();assert.equal(f.timers.size,0);await tick();f.nativeBusy=false;f.restores[0].resolve(true);await tick();assert.equal(f.releases,0);
});
test('running work protects the link; paused jobs alone do not keep it forever',async()=>{
 const f=fixture();f.running=['task'];f.lifecycle.onBackground();await tick();assert.equal(f.releases,0);
 f.running=[];f.jobs=[{stage:'waiting_account'}];f.changed();await tick();assert.equal(f.releases,1);
});
test('a scan/native operation keeps the link until its idle signal', async () => {
  const f = fixture(); f.busy = true; f.lifecycle.onBackground(); await tick();
  assert.equal(f.releases, 0);
  f.busy = false; f.idle(); await tick(); assert.equal(f.releases, 1);
});
test('foreground reconnect coalesces events and wakes device-paused tasks only on success', async () => {
  const f = fixture(); f.lifecycle.onForeground(); f.lifecycle.onForeground();await tick();
  assert.equal(f.restores.length, 1); assert.equal(f.storage.get('wirelessDebugRestoring'), true);
  assert.equal(f.restores[0].allowed(), true);
  f.restores[0].resolve(true); await tick();
  assert.equal(f.storage.get('wirelessDebugRestoring'), false);
  assert.deepEqual(f.resumed, ['waiting_device']); assert.equal(f.storage.get('wirelessLinkRevision'), 1);
  f.lifecycle.onForeground();await tick(); f.restores[1].resolve(false); await tick();
  assert.equal(f.resumed.length, 1); assert.equal(f.storage.get('wirelessLinkRevision'), 1);
});
test('a connection completing after background does not publish a stale foreground success', async () => {
  const f = fixture(); f.linked = false; f.lifecycle.onForeground();await tick(); f.lifecycle.onBackground();
  assert.equal(f.restores[0].allowed(), false);
  f.restores[0].resolve(true); await tick(); await tick();
  assert.equal(f.storage.get('wirelessLinkRevision'), undefined);
  assert.equal(f.resumed.length, 0); assert.equal(f.releases, 1);
});
test('rapid background and foreground transitions schedule one fresh restore after the stale one', async () => {
  const f = fixture(); f.linked = false; f.lifecycle.onForeground();await tick(); f.lifecycle.onBackground();
  f.lifecycle.onForeground(); f.restores[0].resolve(false); await tick();
  assert.equal(f.restores.length, 2); assert.equal(f.restores[1].allowed(), true);
  f.restores[1].resolve(true); await tick();
  assert.equal(f.storage.get('wirelessLinkRevision'), 1); assert.equal(f.resumed.length, 1);
});

test('remote-only idle sessions are also released after background',async()=>{
 const f=fixture();f.linked=false;f.remote=true;f.lifecycle.onBackground();await tick();assert.equal(f.releases,1);assert.equal(f.remote,false);
});
test('native lock contention retains connection state and schedules bounded release retries',async()=>{
 const f=fixture();f.nativeBusy=true;f.lifecycle.onBackground();await tick();assert.equal(f.linked,true);assert.equal(f.timers.size,1);
 f.nativeBusy=false;const fn=[...f.timers.values()][0];f.timers.clear();fn();await tick();assert.equal(f.releases,1);assert.equal(f.timers.size,0);
});

test('permanent native contention stops after the bounded retry sequence and a later idle event can finish release',async()=>{
 const f=fixture();f.nativeBusy=true;f.lifecycle.onBackground();await tick();
 for(let i=0;i<8;i++){const callbacks=[...f.timers.values()];f.timers.clear();callbacks.forEach(fn=>fn());await tick();}
 assert.equal(f.timers.size,0);assert.equal(f.releases,0);assert.equal(f.linked,true);
 f.nativeBusy=false;f.idle();await tick();assert.equal(f.releases,1);
});

test('failed saved-port restoration has one physical-network budget across repeated foreground events',async()=>{
 const f=fixture();f.linked=false;
 for(let i=0;i<3;i++){f.lifecycle.onForeground();await tick();f.restores[i].resolve(false);await tick();}
 for(let i=0;i<10;i++){f.lifecycle.onForeground();await tick();}
 assert.equal(f.restores.length,3);
 f.linked=true;f.lifecycle.onForeground();await tick();assert.equal(f.restores.length,4);f.restores[3].resolve(true);await tick();
});
