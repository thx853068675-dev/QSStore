const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets/jobs');

function load(name, mocks = {}, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: key => mocks[key] || {},
    console: { info() {}, warn() {} }, setTimeout, clearTimeout, ...globals });
  return exports;
}

function backgroundFixture() {
  const f = { starts: 0, stops: 0, requests: [], handlers: new Map(), reject: false };
  const kit = {
    on: (event, callback) => f.handlers.set(event, callback),
    startBackgroundRunning: async (_ctx, modes, agent) => {
      f.starts++; assert.equal(modes.join(), 'dataTransfer'); assert.equal(agent, 'return-to-installer');
      if (f.reject) throw Error('permission or notification unavailable');
      return { continuousTaskId: 42 };
    },
    stopBackgroundRunning: async () => { f.stops++; }
  };
  f.guard = load('BackgroundInstallTask', {
    '@kit.BackgroundTasksKit': { backgroundTaskManager: kit },
    '@kit.AbilityKit': { wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 2 },
      getWantAgent: async config => { f.requests.push(config); return 'return-to-installer'; } } }
  }).BackgroundInstallTask;
  f.guard.configure({ abilityInfo: { bundleName: 'actual.installer.bundle', name: 'EntryAbility' } });
  return f;
}

test('concurrent work shares one background task; only the last release stops it', async () => {
  const f = backgroundFixture();
  await Promise.all([f.guard.acquire('download'), f.guard.acquire('install')]);
  assert.equal(f.starts, 1);
  assert.equal(f.requests[0].wants[0].bundleName, 'actual.installer.bundle');
  await f.guard.release('download'); assert.equal(f.stops, 0);
  await f.guard.release('install'); assert.equal(f.stops, 1);
});

test('failed background eligibility does not prevent foreground work and can recover next time', async () => {
  const f = backgroundFixture(); f.reject = true;
  await f.guard.acquire('first'); await f.guard.release('first');
  assert.equal(f.stops, 0);
  f.reject = false;
  await f.guard.acquire('second'); await f.guard.release('second');
  assert.equal(f.starts, 2); assert.equal(f.stops, 1);
});

test('system cancellation is respected; foreground recovery only restarts real outstanding work', async () => {
  const f = backgroundFixture(); await f.guard.acquire('job');
  f.handlers.get('continuousTaskCancel')({ id: 42, reason: 1 });
  assert.equal(f.starts, 1);
  f.guard.onForeground(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.starts, 2);
  await f.guard.release('job');
  f.guard.onForeground(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.starts, 2);
});

function schedulerFixture(globals = {}) {
  const f = { acquired: [], released: [], cancelled: false };
  f.scheduler = load('JobScheduler', {
    './BackgroundInstallTask': { BackgroundInstallTask: {
      acquire: async id => { f.acquired.push(id); }, release: async id => { f.released.push(id); } } },
    './JobCancellation': { JobCancellation: {
      assertActive() { if (f.cancelled) throw Error('cancelled'); },
      isCancelled: () => f.cancelled, clear: () => {} } },
    './InstallTaskState': { InstallTaskState: { setRunning() {} } }
  }, globals).JobScheduler;
  return f;
}

test('a timed-out worker retains background execution until its actual completion', async () => {
  const f = schedulerFixture(); let finish;
  const gate = new Promise(resolve => { finish = resolve; });
  await assert.rejects(f.scheduler.runExclusive('slow', () => gate, 5), /超时/);
  assert.deepEqual(f.acquired, ['slow']); assert.deepEqual(f.released, []);
  assert.equal(f.scheduler.isRunning('slow'), true);
  finish(); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.released, ['slow']); assert.equal(f.scheduler.isRunning('slow'), false);
});

test('synchronous failure releases its background task and execution lock', async () => {
  const f = schedulerFixture();
  await assert.rejects(f.scheduler.runExclusive('error', () => { throw Error('worker error'); }), /worker error/);
  assert.deepEqual(f.released, ['error']); assert.equal(f.scheduler.isRunning('error'), false);
});

test('a frozen process does not consume the device response budget upon foreground return', async () => {
  let now = 0, id = 0; const callbacks = new Map();
  const f = schedulerFixture({ Date: { now: () => now },
    setTimeout: cb => { callbacks.set(++id, cb); return id; }, clearTimeout: timer => callbacks.delete(timer) });
  let finish;
  const work = f.scheduler.runExclusive('frozen', () => new Promise(resolve => { finish = resolve; }), 10000);
  await new Promise(resolve => setImmediate(resolve));
  now = 300000;
  const tick = callbacks.values().next().value; callbacks.clear(); tick();
  assert.equal(f.scheduler.stillFinishing('frozen'), false);
  finish('completed'); assert.equal(await work, 'completed');
  assert.deepEqual(f.released, ['frozen']);
});
