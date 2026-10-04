const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets/jobs');
function fixture(visibleAfter) {
  const f = { now: 100000, installedAt: 0, installs: 0, waits: [] }, modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {}; modules.set(name, exports);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInNewContext(code, { exports, Date: class extends Date { static now() { return f.now; } },
      setTimeout: (fn, ms) => { f.waits.push(ms); f.now += ms; fn(); return 1; },
      require: name => name === './JobScheduler' ? { JobScheduler: { runInstall: (_id, fn) => fn() } } :
        name === './JobCancellation' ? { JobCancellation: { assertActive: () => {}, isCancelled: () => false } } :
        name.startsWith('.') ? load(name.slice(2)) : {} });
    return exports;
  }
  const { InstallJob, InstallStage, RecoveryEvidence, FailureKind } = load('InstallJob');
  f.job = new InstallJob(); Object.assign(f.job, { id: 'job', bundleName: 'com.example.test',
    versionCode: 2, cachePath: '/private/cache.hap', signedPath: '/private/signed.hap' });
  const store = { get: async () => f.job, save: async () => {},
    recordFailure: async (job, _kind, msg) => { job.stage = InstallStage.RETRYABLE_ERROR; job.lastError = msg; } };
  const runtime = { inspectEvidence: async () => Object.assign(new RecoveryEvidence(), {
    verifiedCache: true, validProfile: true, verifiedSignature: true, deviceConnected: true }),
    installedVersion: async () => f.installedAt && f.now - f.installedAt >= visibleAfter ? 2 : 1,
    install: async () => { f.installs++; f.installedAt = f.now; } };
  f.runtime = runtime;
  const { JobRunner, JobFailure } = load('JobRunner');
  f.runner = new JobRunner(store, runtime); f.stages = InstallStage;
  f.JobFailure = JobFailure; f.kinds = FailureKind; return f;
}
test('an installation that becomes visible after 250 ms finishes without waiting 1.5 s or installing again', async () => {
  const f = fixture(250); await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.INSTALLED); assert.equal(f.installs, 1);
  assert.deepEqual(f.waits, [250]);
});
test('slow confirmation backs off, respects its total bound, and does not reinstall', async () => {
  const f = fixture(Infinity); await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.RETRYABLE_ERROR); assert.equal(f.installs, 1);
  assert.deepEqual(f.waits.slice(0, 4), [250, 500, 1000, 1500]);
  assert.equal(f.now - f.installedAt, 15000);
});
test('same-version renewal waits for authorization replacement instead of completing on version alone', async () => {
  const f = fixture(0);
  f.job.renewalRequestedAt = 100; f.job.reinstallRequired = true;
  f.runtime.installedVersion = async () => f.job.versionCode;
  let checks = 0;
  f.runtime.confirmRenewal = async () => ++checks === 3;
  await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.INSTALLED); assert.equal(f.installs, 1);
  assert.equal(checks, 3); assert.deepEqual(f.waits, [250, 500]);
});
test('same-version renewal stays resumable when replacement cannot be confirmed', async () => {
  const f = fixture(0);
  f.job.renewalRequestedAt = 100; f.job.reinstallRequired = true;
  f.runtime.installedVersion = async () => f.job.versionCode;
  f.runtime.confirmRenewal = async () => false;
  await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.RETRYABLE_ERROR); assert.equal(f.installs, 1);
  assert.equal(f.job.reinstallRequired, true); assert.match(f.job.lastError, /尚未确认授权替换/);
});

test('a transient post-install query failure retries only the result and finishes without resubmission', async () => {
  const f = fixture(0), original = f.runtime.installedVersion; let failures = 0;
  f.runtime.installedVersion = async () => {
    if (f.installedAt && failures++ < 2) throw Error('Response channel closed');
    return original();
  };
  await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.INSTALLED); assert.equal(f.installs, 1);
  assert.deepEqual(f.waits, [250, 500]);
});
test('persistent result-query failures stop after bounded retries and preserve their diagnostic', async () => {
  const f = fixture(0), original = f.runtime.installedVersion; let queries = 0;
  f.runtime.installedVersion = async () => {
    if (f.installedAt) { queries++; throw Error('Response channel closed'); }
    return original();
  };
  await f.runner.run('job');
  assert.equal(f.job.stage, f.stages.RETRYABLE_ERROR); assert.equal(f.installs, 1);
  assert.equal(queries, 3); assert.deepEqual(f.waits, [250, 500]);
  assert.match(f.job.lastError, /Response channel closed/);
});

test('explicit disconnection, account, package and internal failures do not enter the read-only retry loop', async () => {
  for (const kind of ['DEVICE', 'ACCOUNT', 'INVALID_PACKAGE', 'INTERNAL']) {
    const f = fixture(0), original = f.runtime.installedVersion; let queries = 0;
    assert.ok(f.kinds[kind], kind);
    f.runtime.installedVersion = async () => {
      if (f.installedAt) { queries++; throw new f.JobFailure(f.kinds[kind], 'explicit ' + kind); }
      return original();
    };
    await f.runner.run('job');
    assert.equal(f.installs, 1); assert.equal(queries, 1); assert.deepEqual(f.waits, []);
    assert.equal(f.job.lastError, 'explicit ' + kind);
  }
});
test('a slow failed query consumes the same confirmation deadline and cannot obtain extra retries', async () => {
  const f = fixture(0), original = f.runtime.installedVersion; let queries = 0;
  f.runtime.installedVersion = async () => {
    if (f.installedAt) { queries++; f.now += 15000; throw Error('HDC command timed out'); }
    return original();
  };
  await f.runner.run('job');
  assert.equal(f.installs, 1); assert.equal(queries, 1); assert.deepEqual(f.waits, []);
  assert.match(f.job.lastError, /HDC command timed out/);
});
