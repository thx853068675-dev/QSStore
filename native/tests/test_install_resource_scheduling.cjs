const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { loadEts } = require('./load_ets.cjs');
const jobs = loadEts('jobs/InstallJob');
const recovery = loadEts('jobs/RecoveryPlanner', { './InstallJob': jobs });
const targets = loadEts('jobs/DeviceInstallTarget');
const scheduling = loadEts('jobs/InstallScheduling', { './DeviceInstallTarget': targets });
const resources = loadEts('jobs/InstallResourceQueue');
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
async function until(check) {
  for (let i = 0; i < 100; i++) { if (check()) return; await tick(); }
  assert.fail('pipeline did not reach the expected phase');
}
function fixture(t, globals = {}) {
  const cancelled = new Set(), held = new Set(), waiting = new Map(), rows = new Map();
  const gates = [], work = [], events = [], installed = new Map(), hooks = {};
  const cancellation = { assertActive(id) { if (cancelled.has(id)) throw Error('安装任务已取消'); },
    isCancelled: id => cancelled.has(id), clear: id => cancelled.delete(id) };
  const state = { setRunning() {}, setWaiting: (id, value) => value ? waiting.set(id, value) : waiting.delete(id) };
  const store = { get: async id => rows.get(id), save: async job => rows.set(job.id, job),
    recordFailure: async (job, kind, message) => { job.stage = recovery.stageForFailure(kind); job.lastError = message; },
    cancel: async job => { cancelled.add(job.id); rows.delete(job.id); },
    cleanupCancelled: async () => {}, stopTransfer: async () => {} };
  const { JobScheduler: S } = loadEts('jobs/JobScheduler', {
    './InstallResourceQueue': resources, './InstallScheduling': scheduling,
    './JobCancellation': { JobCancellation: cancellation }, './JobStore': { JobStore: { setExecutionGuard() {} } },
    './InstallTaskState': { InstallTaskState: state }, './InstallReconnect': { InstallReconnect: { clear() {} } },
    './InstallConfirmation': { InstallConfirmation: { clear() {} } },
    './BackgroundInstallTask': { BackgroundInstallTask: { acquire: async id => held.add(id), release: async id => held.delete(id) } }
  }, { setTimeout, clearTimeout, ...globals });
  const { JobRunner: Runner } = loadEts('jobs/JobRunner', {
    './InstallJob': jobs, './RecoveryPlanner': recovery, './JobScheduler': { JobScheduler: S },
    './InstallScheduling': scheduling, './JobCancellation': { JobCancellation: cancellation }
  }, { setTimeout, clearTimeout });
  function make(id, local = false, device = 'local', version = 1, bundle = 'test.' + id) {
    const udid = createHash('sha256').update(device).digest('hex');
    const target = Object.assign(new targets.DeviceInstallTarget(), { key: udid,
      udid, host: '192.168.1.9', port: 54321, name: device });
    const job = Object.assign(new jobs.InstallJob(), { id, sourceUrl: local ? 'local' : 'https://example.invalid/' + id + '.hap',
      installTarget: device === 'local' ? '' : targets.DeviceInstallTarget.snapshot(target),
      appId: local ? 0 : 1, catalogVersionCode: version, stageHistory: [{ at: rows.size + 1, stage: 'queued' }] });
    rows.set(id, job);
    const key = device + ':' + bundle;
    const phase = async name => { events.push(name + ':' + id); await hooks[name]?.(job); };
    const runtime = { authorizationLane: () => 'account',
      planPaths: async () => ({ cachePath: '/cache/' + id, signedPath: '/signed/' + id }),
      inspectEvidence: async () => new jobs.RecoveryEvidence(),
      downloadAndVerify: () => phase('download'),
      inspectPackage: async () => ({ bundleName: bundle, versionCode: version, versionName: String(version), moduleName: 'entry', mainAbility: 'EntryAbility' }),
      ensureProfile: () => phase('profile'), sign: () => phase('sign'), verifySignature: () => phase('verify'),
      ensureDevice: async () => true, installedVersion: async () => installed.get(key) || 0,
      install: async job => { await phase('install'); installed.set(key, version); },
      confirmRenewal: async () => true, confirmReplacement: async () => true,
      preflight: async (job, verified) => verified && (installed.get(key) || 0) > job.versionCode ? 'newer_installed' : '' };
    const runner = new Runner(store, runtime);
    return { job, runtime, run() { const promise = runner.run(id); work.push(promise); promise.catch(() => {}); return promise; } };
  }
  function gate() { const value = deferred(); gates.push(value); return value; }
  t.after(async () => { gates.forEach(g => g.resolve()); await Promise.allSettled(work); await tick(); });
  return { S, store, hooks, events, waiting, held, make, gate, installed, rows };
}

test('same-device local install completes while the store download remains blocked; both sources retain FIFO', async t => {
  const f = fixture(t), download = f.gate();
  f.hooks.download = job => job.id === 'store1' ? download.promise : undefined;
  const a = f.make('store1'), b = f.make('store2'), c = f.make('local1', true), d = f.make('local2', true);
  const first = a.run(); await until(() => f.events.includes('download:store1'));
  const second = b.run();
  await c.run(); await d.run();
  assert.equal(c.job.stage, jobs.InstallStage.INSTALLED);
  assert.equal(d.job.stage, jobs.InstallStage.INSTALLED);
  assert(!f.events.includes('download:store2'));
  assert(!f.events.includes('install:store1'));
  download.resolve(); await Promise.all([first, second]);
  assert.deepEqual(f.events.filter(e => e.startsWith('install:')), ['install:local1', 'install:local2', 'install:store1', 'install:store2']);
  assert.equal(f.S.resources.lanes.size, 0); assert.equal(f.held.size, 0);
});

test('three store target flows and two busy download slots cannot consume the local signing/install capacity', async t => {
  const f = fixture(t), gate = f.gate(); let active = 0, peak = 0;
  f.hooks.download = async job => { if (job.sourceUrl === 'local') return; peak = Math.max(peak, ++active); await gate.promise; active--; };
  const stores = ['a', 'b', 'c'].map(id => f.make(id, false, id).run());
  await until(() => f.waiting.get('c') === '等待下载资源');
  const local = f.make('local', true); await local.run();
  assert.equal(local.job.stage, jobs.InstallStage.INSTALLED); assert.equal(peak, 2);
  gate.resolve(); await Promise.all(stores); assert.equal(peak, 2);
});

test('ready local signing takes the next permit, without interrupting current signing or starving store work', async t => {
  const f = fixture(t), gate = f.gate();
  f.hooks.sign = job => job.id === 'active' ? gate.promise : undefined;
  const active = f.make('active', false, 'a').run(); await until(() => f.events.includes('sign:active'));
  const store = f.make('store', false, 'b').run(); await until(() => f.waiting.get('store') === '等待签名');
  const local = f.make('local', true).run(); await until(() => f.waiting.get('local') === '等待签名');
  assert.deepEqual(f.events.filter(e => e.startsWith('sign:')), ['sign:active']);
  gate.resolve(); await Promise.all([active, store, local]);
  assert.deepEqual(f.events.filter(e => e.startsWith('sign:')), ['sign:active', 'sign:local', 'sign:store']);
});

test('system installation is serialized per target but different targets run concurrently', async t => {
  const f = fixture(t), gate = f.gate(); let active = 0, peak = 0;
  f.hooks.install = async () => { peak = Math.max(peak, ++active); await gate.promise; active--; };
  const first = f.make('store').run(); await until(() => f.events.includes('install:store'));
  const second = f.make('local', true).run();
  const peer = f.make('peer', false, 'b').run(); await until(() => f.events.includes('install:peer'));
  assert(!f.events.includes('install:local')); assert.equal(f.waiting.get('local'), '等待设备空闲'); assert.equal(peak, 2);
  gate.resolve(); await Promise.all([first, second, peer]); assert.equal(peak, 2);
});

test('global system-install cap remains three when local and store flows target six devices', async t => {
  const f = fixture(t), gate = f.gate(); let active = 0, peak = 0;
  f.hooks.install = async () => { peak = Math.max(peak, ++active); await gate.promise; active--; };
  const work = Array.from({ length: 6 }, (_, i) => f.make('task' + i, i > 2, 'device' + i).run());
  await until(() => f.events.filter(e => e.startsWith('install:')).length === 3 && f.waiting.size === 3);
  assert.equal(peak, 3); gate.resolve(); await Promise.all(work); assert.equal(peak, 3);
});

test('a cancelled resource waiter exits immediately and never reaches the device', async t => {
  const f = fixture(t), gate = f.gate();
  f.hooks.sign = job => job.id === 'active' ? gate.promise : undefined;
  const active = f.make('active').run(); await until(() => f.events.includes('sign:active'));
  const local = f.make('cancelled', true), waiting = local.run();
  await until(() => f.waiting.get('cancelled') === '等待签名');
  await f.S.cancel({}, f.store, local.job); await assert.rejects(waiting, /取消/); await tick();
  assert.equal(f.S.isRunning('cancelled'), false); assert.equal(f.held.has('cancelled'), false);
  assert.equal(f.waiting.has('cancelled'), false); gate.resolve(); await active;
  assert(!f.events.includes('install:cancelled'));
});

test('cancelling an already submitted system install retains its target permit until the real call finishes', async t => {
  const f = fixture(t), gate = f.gate();
  f.hooks.install = job => job.id === 'active' ? gate.promise : undefined;
  const current = f.make('active'), pending = current.run(); await until(() => f.events.includes('install:active'));
  await f.S.cancel({}, f.store, current.job); await assert.rejects(pending, /取消/);
  const local = f.make('local', true), next = local.run();
  await until(() => f.waiting.get('local') === '等待设备空闲');
  assert(f.S.isRunning('active')); assert(!f.events.includes('install:local'));
  gate.resolve(); await next; assert.equal(local.job.stage, jobs.InstallStage.INSTALLED);
});

test('timed-out active install retains target and background ownership until the operation returns', async t => {
  const f = fixture(t), gate = f.gate();
  f.S.DOWNLOAD_TIMEOUT_MS = 10; f.S.INSTALL_TIMEOUT_MS = 10;
  f.hooks.install = job => job.id === 'active' ? gate.promise : undefined;
  const current = f.make('active'), pending = current.run(); await assert.rejects(pending, /超时/);
  f.S.DOWNLOAD_TIMEOUT_MS = 720000; f.S.INSTALL_TIMEOUT_MS = 360000;
  const local = f.make('local', true), next = local.run();
  await until(() => f.waiting.get('local') === '等待设备空闲');
  assert(f.S.stillFinishing('active')); assert(f.held.has('active')); assert(!f.events.includes('install:local'));
  gate.resolve(); await next; await tick(); assert.equal(f.held.size, 0);
});

test('a later newer local package prevents the earlier downloading store package from downgrading it', async t => {
  const f = fixture(t), gate = f.gate();
  f.hooks.download = job => job.sourceUrl !== 'local' ? gate.promise : undefined;
  const old = f.make('old', false, 'local', 1, 'test.shared'), newer = f.make('new', true, 'local', 2, 'test.shared');
  const pending = old.run(); await until(() => f.events.includes('download:old')); await newer.run(); gate.resolve(); await pending;
  assert.equal(old.job.stage, jobs.InstallStage.SKIPPED); assert(!f.events.includes('install:old'));
  assert.equal(f.installed.get('local:test.shared'), 2);
});

test('device state is rechecked after waiting for the installation permit, not only before signing', async t => {
  const f = fixture(t), gate = f.gate();
  f.hooks.install = job => job.id === 'new' ? gate.promise : undefined;
  const newer = f.make('new', true, 'local', 2, 'test.shared'), old = f.make('old', false, 'local', 1, 'test.shared');
  const first = newer.run(); await until(() => f.events.includes('install:new'));
  const second = old.run(); await until(() => f.waiting.get('old') === '等待设备空闲');
  gate.resolve(); await Promise.all([first, second]); assert.equal(old.job.stage, jobs.InstallStage.SKIPPED);
  assert(!f.events.includes('install:old'));
});

test('restored signed artifacts skip preparation and duplicate job submissions never execute twice', async t => {
  const f = fixture(t), gate = f.gate(), a = f.make('restored', true);
  Object.assign(a.job, { bundleName: 'test.restored', versionCode: 1, cachePath: '/cache/restored', signedPath: '/signed/restored' });
  a.runtime.inspectEvidence = async () => Object.assign(new jobs.RecoveryEvidence(), {
    verifiedCache: true, validProfile: true, verifiedSignature: true, deviceConnected: true });
  f.hooks.install = () => gate.promise;
  const one = a.run(); await until(() => f.events.includes('install:restored'));
  await assert.rejects(a.run(), /正在执行/); gate.resolve(); await one;
  assert.deepEqual(f.events, ['install:restored']);
});

test('ready store work receives a permit after at most two local turns; cancellation and release are idempotent', async () => {
  const q = new resources.InstallResourceQueue(), order = [];
  const release = await q.acquire('sign', 'active', false, 1);
  const run = (id, local) => q.acquire('sign', id, local, 1).then(done => { order.push(id); done(); done(); });
  const work = [run('store', false), run('local1', true), run('local2', true), run('local3', true)];
  const cancelled = q.acquire('sign', 'cancelled', true, 1); q.cancel('cancelled'); q.cancel('cancelled');
  await assert.rejects(cancelled, /取消/); release(); await Promise.all(work);
  assert.deepEqual(order, ['local1', 'local2', 'store', 'local3']); assert.equal(q.lanes.size, 0);
});

test('resource waiting does not consume execution timeout and restarts the budget only when granted', async t => {
  let now = 0, serial = 0; const timers = new Map();
  const f = fixture(t, { Date: { now: () => now }, setTimeout: cb => { timers.set(++serial, cb); return serial; },
    clearTimeout: id => timers.delete(id) });
  f.S.DOWNLOAD_TIMEOUT_MS = 1000; f.S.INSTALL_TIMEOUT_MS = 1000;
  const gate = f.gate(), localGate = f.gate();
  f.hooks.install = job => job.id === 'active' ? gate.promise : localGate.promise;
  const active = f.make('active').run(); await until(() => f.events.includes('install:active'));
  const local = f.make('local', true).run(); await until(() => f.waiting.has('local'));
  for (let i = 0; i < 3; i++) {
    now += 1000; const callbacks = Array.from(timers.values()); timers.clear(); callbacks.forEach(fn => fn());
  }
  await assert.rejects(active, /超时/); assert.equal(f.S.stillFinishing('local'), false);
  gate.resolve(); await until(() => f.events.includes('install:local'));
  now += 1000; const callbacks = Array.from(timers.values()); timers.clear(); callbacks.forEach(fn => fn());
  assert.equal(f.S.stillFinishing('local'), false);
  localGate.resolve(); await local;
});

test('resource wait labels are shared, retain progress and stop the indeterminate UI clock', () => {
  let clock = 0, next = 0;
  const { InstallTaskState: state } = loadEts('jobs/InstallTaskState', {
    './InstallJob': jobs, './RecoveryPlanner': recovery,
    './InstallReconnect': { InstallReconnect: { visible: () => false, clear() {} } },
    './InstallCertificateSlots': { InstallCertificateSlots: { visible: () => false, clear() {} } }
  }, { setInterval: () => { clock++; return ++next; }, clearInterval: () => clock-- });
  const job = Object.assign(new jobs.InstallJob(), { id: 'waiting', stage: jobs.InstallStage.PROFILE_READY });
  state.publish(job); const subscription = state.subscribe(() => {}); state.setRunning(job.id, true);
  assert.equal(clock, 1); const before = state.snapshot()[0];
  state.setWaiting(job.id, '等待签名');
  const waiting = state.snapshot()[0]; assert.notEqual(waiting, before); assert.equal(waiting.waitingFor, '等待签名');
  assert.equal(state.label(waiting), '等待签名'); assert.equal(state.compactLabel(waiting), '排队');
  assert.equal(clock, 0); assert.equal(waiting.percent, before.percent);
  state.setWaiting(job.id, ''); assert.equal(clock, 1);
  state.setRunning(job.id, false); state.unsubscribe(subscription); assert.equal(clock, 0);
});
