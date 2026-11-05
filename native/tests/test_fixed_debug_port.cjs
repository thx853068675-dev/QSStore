const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(enabled = true) {
  const f = { desired: { enabled, port: 45678 }, active: 5555, linked: true, busy: false,
    jobs: [], settings: [], probes: 0, applied: [], cleared: 0, resume: [], storage: new Map(), deferred: new Map(),
    timers: new Map(), random: [65535, 0, 55535], apply: async () => true };
  let timerId = 0;
  const network={available:true,signature:'wifi-1',subscribe:fn=>{f.network=(changed=true)=>{if(changed)network.signature+='x';fn();};return 1;},start:async()=>true};
  const exports = {};
  class Bridge {
    static busy() { return f.busy; }
    static connectedPort() { return f.linked ? f.active : 0; }
    static deviceLinked() { return f.linked; }
    async fixedPortSettings() { return f.desired; }
    async saveFixedPortSettings(settings) { f.desired = settings; f.settings.push(settings); }
    async connected() { f.probes++; return f.linked; }
    async clearFixedPort(allowed) {
      if (!allowed()) return false;
      f.cleared++; f.active = 0; f.linked = false; return true;
    }
    async fixPort(port, allowed) {
      if (!allowed()) return false;
      f.applied.push(port);
      if (await f.apply()) { f.active = port; return true; }
      return false;
    }
  }
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/FixedDebugPort.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports,
    setTimeout: callback => { const id = ++timerId; f.timers.set(id, callback); return id; },
    clearTimeout: id => f.timers.delete(id),
    AppStorage: { get: key => f.storage.get(key), setOrCreate: (key, value) => f.storage.set(key, value) },
    require: name => ({
      './DeviceNetwork': {DeviceNetwork:network},
      './HdcDeviceBridge': { HdcDeviceBridge: Bridge },
      './ForegroundIdle': { ForegroundIdle: { defer: (key, callback) => f.deferred.set(key, callback),
        cancel: key => f.deferred.delete(key) } },
      './JobScheduler': { JobScheduler: { runningJobIds: () => f.jobs } },
      './InstallJob': { InstallStage: { WAITING_DEVICE: 'waiting_device' } },
      './InstallCoordinator': { InstallCoordinator: { conditionReady: async (_context, stage) => f.resume.push(stage) } },
      '@kit.NetworkKit': { connection: { createNetConnection: () => ({
        on: (_name, callback) => { f.network = callback; }, register() {} }) } },
      '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({
        generateRandomSync: () => { const n = f.random.shift() ?? 123; return { data: new Uint8Array([n >> 8, n & 255]) }; }
      }) } }
    })[name] || {} });
  f.controller = exports.FixedDebugPort;
  f.run = async () => { const callbacks = [...f.deferred.values()]; f.deferred.clear(); callbacks.forEach(fn => fn()); await tick(); };
  f.retry = async () => { const callbacks = [...f.timers.values()]; f.timers.clear(); callbacks.forEach(fn => fn()); await f.run(); };
  return f;
}
function reconnectUI(f, file, succeeds) {
  const prompt = file === 'components/InstallPrompts';
  const name = prompt ? 'connect' : 'reconnect';
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets',
    (file.includes('/') ? file : 'pages/' + file) + '.ets'), 'utf8');
  const start = source.search(new RegExp(`^  private\\s+async\\s+${name}\\(`, 'm'));
  assert.notEqual(start, -1, file + ' connection method');
  const parsed = ts.createSourceFile('method.ts', `class Page {\n${source.slice(start)}`, ts.ScriptTarget.ES2020, true);
  const method = parsed.statements[0].members[0];
  assert.ok(ts.isMethodDeclaration(method));
  const calls = [];
  const box = {
    getContext: () => ({}), errorText: error => String(error),
    HdcDeviceBridge: class {
      async connect(port) {
        calls.push(['connect', port]);
        if (succeeds) { f.linked = true; f.active = port; }
        return succeeds;
      }
      connectionFailureMessage() { return 'closed'; }
    },
    FixedDebugPort: { wake: () => { calls.push(['wake']); f.controller.wake(); } },
    InstallReconnect: { clear: id => calls.push(['clear', id]) },
    InstallStage: { WAITING_DEVICE: 'waiting_device', INSTALLED: 'installed' },
    InstallCoordinator: { conditionReady: async () => calls.push(['resume']) },
    JobStore: { open: async () => ({ get: async () => undefined }) },
    promptAction: { showToast() {} }
  };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method.getText(parsed)} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page();
  Object.assign(ui, {
    reconnectPort: '54321', reconnectBusy: false, reconnectMessage: '', showReconnect: true,
    resumeJobId: '', reconnectJobId: 'job-1', activeInstallId: '', deviceCheckGeneration: 0,
    port: '54321', connecting: false, showing: true, jobId: 'job-1', message: '',
    animateOverlay: change => change(),
    completeRefreshConnection: () => calls.push(['refresh']),
    refreshCatalogInstallState: async () => calls.push(['catalog']),
    resumeInstall: async () => calls.push(['resumeInstall'])
  });
  return { ui, calls, run: () => ui[name]() };
}
test('random ports reject overflow without bias and accept both valid endpoints', () => {
  const f = fixture();
  assert.equal(f.controller.randomPort(), 10000);
  assert.equal(f.controller.randomPort(), 65535);
});
test('saved desired port applies only after opening settles and publishes verified readiness', async () => {
  const f = fixture(); f.controller.configure({}); await tick();
  assert.equal(f.applied.length, 0);
  assert.equal(f.controller.phase, 'waiting');
  await f.run();
  assert.deepEqual(f.applied, [45678]);
  assert.equal(f.controller.phase, 'ready');
  assert.deepEqual(f.resume, ['waiting_device']);
  f.controller.idle(); await f.run(); assert.equal(f.probes, 1);
});
test('active signing blocks a port restart and the idle event resumes the saved request', async () => {
  const f = fixture(); f.jobs = ['install']; f.controller.configure({}); await tick(); await f.run();
  assert.equal(f.controller.phase, 'busy'); assert.equal(f.applied.length, 0);
  f.jobs = []; f.controller.idle(); await f.run();
  assert.equal(f.controller.phase, 'ready'); assert.equal(f.applied.length, 1);
});
test('a background transition cancels scheduled maintenance and foreground retries it', async () => {
  const f = fixture(); f.controller.configure({}); await tick(); f.controller.onBackground(); await f.run();
  assert.equal(f.applied.length, 0);
  f.controller.onForeground(); await f.run(); assert.equal(f.applied.length, 1);
});
test('offline recovery is bounded, coalesces commands and restarts only on an external event', async () => {
  const f = fixture(); f.linked = false; f.controller.configure({}); await tick(); await f.run();
  await f.retry(); await f.retry(); await f.retry();
  assert.equal(f.probes, 3); assert.equal(f.controller.phase, 'waiting');
  f.controller.idle(); await f.run(); assert.equal(f.probes, 3);
  f.linked = true; f.active = 45678; f.network(); await f.run();
  assert.equal(f.controller.phase, 'ready'); assert.equal(f.applied.length, 0);
});
test('manual reconnect after exhausted retries restores the desired port without another foreground event', async () => {
  const f = fixture(); f.linked = false; f.controller.configure({}); await tick(); await f.run();
  await f.retry(); await f.retry();
  assert.equal(f.probes, 3); assert.equal(f.controller.phase, 'waiting');
  f.linked = true; f.active = 54321;
  f.controller.wake(); await f.run();
  assert.deepEqual(f.applied, [45678]);
  assert.equal(f.controller.phase, 'ready');
  assert.deepEqual(f.resume, ['waiting_device']);
});
for (const file of ['Index', 'Detail', 'components/InstallPrompts']) {
  test(file + ' successful manual connection restarts exhausted fixed port recovery', async () => {
    const f = fixture(); f.linked = false; f.controller.configure({}); await tick(); await f.run();
    await f.retry(); await f.retry();
    assert.equal(f.probes, 3); assert.equal(f.controller.phase, 'waiting');
    const connection = reconnectUI(f, file, true);
    await connection.run();
    const operations = connection.calls.map(row => row[0]);
    assert.deepEqual(connection.calls[0], ['connect', 54321]);
    assert.equal(operations.filter(operation => operation === 'wake').length, 1);
    assert.ok(operations.indexOf('wake') > operations.indexOf('connect'));
    assert.ok(operations.indexOf('wake') < operations.findIndex(operation =>
      ['refresh', 'catalog', 'resume', 'resumeInstall'].includes(operation)));
    assert.equal(connection.ui.showReconnect && connection.ui.showing, false);
    await f.run();
    assert.deepEqual(f.applied, [45678]);
    assert.equal(f.controller.phase, 'ready');
    assert.deepEqual(f.resume, ['waiting_device']);
  });
  test(file + ' failed manual connection leaves exhausted recovery waiting', async () => {
    const f = fixture(); f.linked = false; f.controller.configure({}); await tick(); await f.run();
    await f.retry(); await f.retry();
    const connection = reconnectUI(f, file, false);
    await connection.run(); await f.run();
    assert.deepEqual(connection.calls, [['connect', 54321]]);
    assert.equal(f.probes, 3); assert.equal(f.applied.length, 0);
    assert.equal(f.controller.phase, 'waiting');
    assert.equal(connection.ui.showReconnect && connection.ui.showing, true);
    assert.equal(file === 'components/InstallPrompts' ? connection.ui.message : connection.ui.reconnectMessage, 'closed');
  });
}
test('a transient setting failure retries without requiring another user click', async () => {
  const f = fixture(); let first = true;
  f.apply = async () => { if (first) { first = false; throw new Error('daemon restarting'); } return true; };
  f.controller.configure({}); await tick(); await f.run();
  assert.equal(f.controller.phase, 'recovering');
  await f.retry(); assert.equal(f.controller.phase, 'ready');
  assert.equal(f.applied.length, 2);
});
test('disabled maintenance keeps the saved port but never sends a daemon command', async () => {
  const f = fixture(false); f.controller.configure({}); await tick(); await f.run();
  await f.controller.set(false, 45678); f.controller.wake(); await f.run();
  assert.equal(f.applied.length, 0); assert.equal(f.controller.port, 45678);
  assert.equal(f.desired.enabled, false);
});

test('deactivation waits for signing to finish, closes the daemon and clears its durable pending flag', async () => {
  const f = fixture(); f.active = 45678; f.controller.configure({}); await tick(); await f.run();
  f.jobs = ['signing']; await f.controller.deactivate(); await f.run();
  assert.equal(f.controller.enabled, false); assert.equal(f.controller.resetPending, true);
  assert.equal(f.cleared, 0); assert.equal(f.desired.resetPending, true);
  f.jobs = []; f.controller.idle(); await f.run();
  assert.equal(f.cleared, 1); assert.equal(f.controller.phase, 'off');
  assert.equal(f.controller.resetPending, false); assert.equal(f.desired.resetPending, undefined);
});

test('duplicate physical network notifications and passive page checks cannot renew an exhausted retry budget',async()=>{
 const f=fixture();f.linked=false;f.controller.configure({});await tick();await f.run();await f.retry();await f.retry();assert.equal(f.probes,3);
 for(let i=0;i<30;i++){f.network(false);f.controller.wake(false);f.controller.onForeground();await f.run();await f.retry();}
 assert.equal(f.probes,3);assert.equal(f.timers.size,0);f.network(true);await f.run();assert.equal(f.probes,4);
});
test('foreground restoration and maintenance share the exact same recovery flight',async()=>{
 const f=fixture();let resolve;f.apply=()=>new Promise(done=>resolve=done);f.controller.configure({});await tick();await f.run();
 const one=f.controller.restore(),two=f.controller.restore();assert.equal(one,two);resolve(true);await one;assert.equal(f.applied.length,1);assert.equal(f.controller.phase,'ready');
});

test('automatic port recovery also has an elapsed-time budget, renewed by explicit user action',async()=>{
 const f=fixture();f.linked=false;f.controller.configure({});await tick();await f.run();f.controller.budgetUntil=Date.now()-1;
 await f.retry();f.controller.onForeground();await f.run();assert.equal(f.probes,1);
 f.controller.wake();await f.run();assert.equal(f.probes,2);
});
