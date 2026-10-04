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
  const { InstallJob, InstallStage, RecoveryEvidence } = load('InstallJob');
  f.job = new InstallJob(); Object.assign(f.job, { id: 'job', bundleName: 'com.example.test',
    versionCode: 2, cachePath: '/private/cache.hap', signedPath: '/private/signed.hap' });
  const store = { get: async () => f.job, save: async () => {},
    recordFailure: async (job, _kind, msg) => { job.stage = InstallStage.RETRYABLE_ERROR; job.lastError = msg; } };
  const runtime = { inspectEvidence: async () => Object.assign(new RecoveryEvidence(), {
    verifiedCache: true, validProfile: true, verifiedSignature: true, deviceConnected: true }),
    installedVersion: async () => f.installedAt && f.now - f.installedAt >= visibleAfter ? 2 : 1,
    install: async () => { f.installs++; f.installedAt = f.now; } };
  f.runtime = runtime;
  f.runner = new (load('JobRunner').JobRunner)(store, runtime); f.stages = InstallStage; return f;
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
