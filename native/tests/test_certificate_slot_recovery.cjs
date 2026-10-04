const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function loader(mocks = {}) {
  const modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {}; modules.set(name, exports);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInNewContext(code, { exports, console, require: dep => {
      const target = dep.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(name), dep)) : dep;
      return mocks[target] || (dep.startsWith('.') ? load(target) : {});
    } }); return exports;
  }
  return load;
}
test('only explicit cert/add quota errors enter certificate management; Profile, login and network failures retain their type', () => {
  const load = loader(), { ServiceFailure } = load('data/ServiceFailure'), { FailureKind } = load('jobs/InstallJob');
  const { certificateQuotaFailure: classify } = load('data/CertificateQuota');
  for (const message of ['certificate number exceeds limit', '该证书类型的数量已达上限', 'debug certificate quota exceeded']) {
    const result = classify(new ServiceFailure(FailureKind.INTERNAL, 'AGC 拒绝请求：' + message, 999));
    assert.equal(result.failureKind, FailureKind.CERTIFICATE_LIMIT); assert.equal(result.status, 999);
  }
  for (const message of ['sign ide test provision number exceeds limit', 'Profile quota exceeded',
    '登录已过期', 'AGC 权限不足', 'AGC 暂时无法完成请求（HTTP 429）', 'certificate parsing failed']) {
    const error = new ServiceFailure(FailureKind.INTERNAL, message, 999);
    assert.equal(classify(error), error);
  }
  const network = Error('certificate number exceeds limit'); assert.equal(classify(network), network);
});
test('the real cert/add transport classifies the server quota while other AGC endpoints stay untouched', async () => {
  const calls = [], http = { RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' },
    createHttp: () => ({ request: async url => { calls.push(url); return { responseCode: 200,
      result: JSON.stringify({ ret: { code: 999, msg: 'certificate number exceeds limit' } }) }; }, destroy() {} }) };
  const load = loader({ '@kit.NetworkKit': { http }, 'data/AccountService': { AccountService: {} } });
  const { AgcClient } = load('data/AgcClient'), { FailureKind } = load('jobs/InstallJob');
  const client = new AgcClient({});
  await assert.rejects(client.createCertificate('-----BEGIN CERTIFICATE REQUEST-----\nfixture', 'test'),
    e => e.failureKind === FailureKind.CERTIFICATE_LIMIT);
  await assert.rejects(client.certificates(), e => e.failureKind === FailureKind.INTERNAL);
  assert.equal(calls.length, 2);
});
function fixture() {
  const f = { account: { userId: 'A', teamId: 'T' }, calls: [], rows: [
    { id: '1', certName: 'hokit', certType: 1, expireTime: 4102444800 },
    { id: '2', certName: 'old', certType: 1, expireTime: 1 },
    { id: '3', certType: 2 } ] };
  const load = loader({
    'data/AccountService': { AccountService: { current: async () => f.account } },
    'data/AgcClient': { AgcClient: class {
      async certificates() { f.calls.push('list'); if (f.listError) throw f.listError; return f.rows; }
      async deleteCertificates(ids) { f.calls.push('delete:' + ids.join(','));
        if (!f.rejectDelete) f.rows = f.rows.filter(row => !ids.includes(row.id));
        if (f.onDelete) f.onDelete(); if (f.deleteError) throw f.deleteError; }
    } },
    'data/SigningIdentity': { SigningIdentityRecovery: {
      load: async () => undefined, expirySeconds: value => Number(value || 0),
      prepareCertificateDeletion: async () => { f.calls.push('prepare'); if (f.onPrepare) await f.onPrepare(); },
      beginCertificateDeletion: async () => f.calls.push('begin'),
      finishCertificateDeletion: async () => f.calls.push('finish'),
      cancelCertificateDeletion: async () => f.calls.push('cancel')
    } },
    'jobs/JobStore': { JobStore: { open: async () => f.store } },
    'jobs/JobScheduler': { JobScheduler: { runInstall: (_id, task) => task() } },
    'jobs/InstallCoordinator': { InstallCoordinator: { run: async (_ctx, id) => {
      f.calls.push('run:' + id); return f.runFunction ? f.runFunction(id) : f.job;
    } } }
  });
  const { InstallJob, InstallStage } = load('jobs/InstallJob'); f.stages = InstallStage;
  f.load = load;
  f.store = { get: async () => f.job, save: async () => f.calls.push('save'),
    recordFailure: async (job, kind, message) => { job.stage = load('jobs/RecoveryPlanner').stageForFailure(kind); job.lastError = message; } };
  f.job = Object.assign(new InstallJob(), { id: 'original', stage: InstallStage.WAITING_CERTIFICATE,
    cachePath: '/retained/source.hap', signedPath: '/retained/signed.hap', sourceUrl: 'local',
    profilePath: '/retained/profile.p7b', signingCertId: '', allowDataLoss: true });
  f.service = load('jobs/CertificateSlotRecovery').CertificateSlotRecovery;
  f.resume = cert => f.service.deleteAndResume({}, 'original', 'A', 'T', cert);
  return f;
}
test('first-time users without a signing identity can list valid and expired debug certificates, excluding release certs', async () => {
  const f = fixture(), rows = await f.service.list({}, 'A', 'T');
  assert.deepEqual(Array.from(rows, row => row.id), ['1', '2']); assert.equal(rows[0].inUse, false);
  assert.deepEqual(f.calls, ['list']);
});
test('confirmed deletion resumes the same job retaining the original package, Profile and consent', async () => {
  const f = fixture(); await f.resume('1');
  assert.deepEqual(f.calls, ['list', 'prepare', 'begin', 'delete:1', 'finish', 'save', 'run:original']);
  assert.equal(f.job.stage, f.stages.QUEUED); assert.equal(f.job.cachePath, '/retained/source.hap');
  assert.equal(f.job.profilePath, '/retained/profile.p7b'); assert.equal(f.job.allowDataLoss, true);
});
test('a confirmed rejection preserves the wait and never starts installation', async () => {
  const f = fixture(); f.rejectDelete = true; f.deleteError = Error('denied');
  await assert.rejects(f.resume('1'), /denied/);
  assert.ok(f.calls.includes('cancel')); assert.ok(!f.calls.includes('save'));
  assert.equal(f.job.stage, f.stages.WAITING_CERTIFICATE);
});
test('a lost deletion response is reconciled, and a successful deletion resumes without a second delete', async () => {
  const f = fixture(); f.deleteError = Error('network lost'); await f.resume('1');
  assert.equal(f.calls.filter(c => c.startsWith('delete:')).length, 1);
  assert.ok(f.calls.includes('finish')); assert.ok(f.calls.includes('run:original'));
});
test('an uncertain deletion keeps the tombstone and never resumes or rolls it back', async () => {
  const f = fixture(); f.deleteError = Error('network lost'); f.onDelete = () => { f.listError = Error('offline'); };
  await assert.rejects(f.resume('1'), /暂时无法确认/);
  assert.ok(!f.calls.includes('cancel')); assert.ok(!f.calls.includes('finish')); assert.ok(!f.calls.includes('save'));
});
test('account changes before deletion and cancellation during deletion cannot resume a stale task', async () => {
  const a = fixture(); a.onPrepare = () => { a.account = { userId: 'B', teamId: 'T' }; };
  await assert.rejects(a.resume('1'), /账号已改变/); assert.ok(!a.calls.some(c => c.startsWith('delete:')));
  const b = fixture(); b.onDelete = () => { b.job = undefined; };
  await assert.rejects(b.resume('1'), /任务已取消/); assert.ok(!b.calls.includes('save'));
});
test('externally deleted certificates resume without deleting another row or preparing a new key', async () => {
  const f = fixture(); await f.resume('missing');
  assert.deepEqual(f.calls, ['list', 'save', 'run:original']); assert.equal(f.rows.length, 3);
});
test('route changes cannot submit a second certificate deletion or race a resume for the same job', async () => {
  const f = fixture(); let release;
  f.onPrepare = () => new Promise(resolve => { release = resolve; });
  const first = f.resume('1');
  await new Promise(setImmediate);
  await assert.rejects(f.resume('2'), /正在处理中/);
  await assert.rejects(f.service.resume({}, 'original', 'A', 'T'), /正在处理中/);
  release(); await first;
  assert.equal(f.calls.filter(c => c.startsWith('delete:')).length, 1);
});
test('the production install runner pauses for quota and completes the original cached install after certificate deletion', async () => {
  const f = fixture(), { JobRunner } = f.load('jobs/JobRunner'), { FailureKind, RecoveryEvidence } = f.load('jobs/InstallJob');
  const { ServiceFailure } = f.load('data/ServiceFailure');
  let preparations = 0, downloads = 0, signatures = 0, installs = 0, installed = 0;
  Object.assign(f.job, { bundleName: 'test.bundle', versionCode: 2 });
  const runtime = { inspectEvidence: async () => Object.assign(new RecoveryEvidence(), { verifiedCache: true }),
    downloadAndVerify: async () => downloads++,
    ensureProfile: async () => { if (++preparations === 1) throw new ServiceFailure(FailureKind.CERTIFICATE_LIMIT, 'quota', 999); },
    sign: async () => signatures++, verifySignature: async () => {}, ensureDevice: async () => true,
    install: async () => { installs++; installed = 2; }, installedVersion: async () => installed };
  const runner = new JobRunner(f.store, runtime); f.runFunction = id => runner.run(id);
  await runner.run('original'); assert.equal(f.job.stage, f.stages.WAITING_CERTIFICATE);
  assert.equal(installs, 0); assert.equal(signatures, 0);
  await f.resume('1'); assert.equal(f.job.stage, f.stages.INSTALLED);
  assert.equal(downloads, 0); assert.equal(preparations, 2); assert.equal(signatures, 1); assert.equal(installs, 1);
  assert.equal(f.job.id, 'original'); assert.equal(f.job.cachePath, '/retained/source.hap');
});
test('the certificate prompt follows route ownership across navigation gaps and can close and reopen the retained wait', () => {
  const load = loader(), { InstallCertificateSlots: bus } = load('jobs/InstallCertificateSlots'), events = [];
  const index = bus.subscribe(id => events.push(['index', id])), detail = bus.subscribe(id => events.push(['detail', id]));
  bus.activate(index); bus.deactivate(index); bus.request('job', '["A","T"]'); bus.activate(detail);
  assert.equal(events.at(-1)[0], 'detail'); assert.equal(events.at(-1)[1], 'job');
  assert.equal(bus.scope('job'), '["A","T"]');
  bus.clear('other'); assert.equal(bus.isRequested('job'), true);
  bus.clear('job'); assert.equal(bus.isRequested('job'), false);
  bus.request('job'); assert.equal(events.at(-1)[1], 'job');
  bus.unsubscribe(detail); assert.equal(bus.isOwner(detail), false); bus.activate(index);
  assert.equal(events.at(-1)[0], 'index'); assert.equal(events.at(-1)[1], 'job');
});
