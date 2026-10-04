// Real SQLite exercises the production journal schema, migrations and persistence.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets/jobs');
function load(name, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {} });
  return exports;
}
function fixture(t, legacy) {
  const files = new Set();
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  const source = fs.readFileSync(path.join(root, 'JobStore.ets'), 'utf8');
  const schema = source.match(/const JOB_SCHEMA = `([\s\S]*?)`;/)[1];
  if (legacy) {
    db.exec(schema.replace(/^  (renewal_|authorization_expires_at|installed_update_time|installed_fingerprint).*\n/gm, ''));
    db.prepare(`INSERT INTO install_jobs
      (id, app_id, asset_name, source_url, expected_sha256, bundle_name, version_code,
       stage, cache_path, signed_path, transfer_task_id, attempt, last_error, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run('legacy:pending', 0, 'old.hap', 'local', 'd'.repeat(64), 'com.example.old', 5,
        'queued', '/sandbox/old.hap', '/sandbox/old.signed.hap', '', 0, '', 1700000000000);
  }
  const adapter = {
    executeSql: async (sql, args = []) => db.prepare(sql).run(...args),
    querySql: async (sql, args = []) => {
      const statement = db.prepare(sql), rows = statement.all(...args);
      const columns = statement.columns().map(c => c.name); let index = -1;
      return { goToNextRow: () => ++index < rows.length,
        getColumnIndex: name => columns.indexOf(name),
        getString: column => String(rows[index][columns[column]]),
        getLong: column => Number(rows[index][columns[column]]), close() {} };
    }
  };
  const jobs = load('InstallJob');
  const { JobStore } = load('JobStore', {
    './InstallJob': jobs, './RecoveryPlanner': load('RecoveryPlanner', { './InstallJob': jobs }),
    '@kit.ArkData': { relationalStore: { getRdbStore: async () => adapter, SecurityLevel: { S1: 1 } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: p => files.has(p) } },
    './JobCancellation': { JobCancellation: { isCancelled: () => false } },
    './InstallTaskState': { InstallTaskState: { publish() {} } }
  });
  return { db, JobStore, jobs, files, context: { filesDir: '/sandbox' } };
}
for (const legacy of [true, false]) test('renewal journal persists all authorization proofs; legacy schema=' + legacy, async t => {
  const f = fixture(t, legacy);
  const store = await f.JobStore.initialize(f.context);
  await f.JobStore.initialize(f.context); // migrations must be idempotent
  if (legacy) {
    const old = await store.get('legacy:pending');
    assert.equal(old.bundleName, 'com.example.old'); assert.equal(old.cachePath, '/sandbox/old.hap');
    assert.equal(old.renewalRequestedAt, 0); assert.equal(old.renewalInstallBaseline, 0);
  }
  const job = f.jobs.InstallJob.create('local:renew', 0, 'app.hap', 'local', 'a'.repeat(64));
  Object.assign(job, { bundleName: 'com.example.app', versionCode: 7,
    renewalRequestedAt: 1800000000000, renewalPreparedAt: 1800000000000,
    renewalPreviousExpiry: 1800000000, renewalExpiresAt: 1900000000,
    renewalInstallBaseline: 1790000000000, authorizationExpiresAt: 1899999999,
    installedUpdateTime: 1800000001000, installedFingerprint: 'A'.repeat(64), reinstallRequired: true,
    profilePath: '/sandbox/renew.p7b', profileSha256: 'b'.repeat(64) });
  await store.save(job);
  const restored = await store.get(job.id);
  for (const key of ['renewalRequestedAt', 'renewalPreparedAt', 'renewalPreviousExpiry',
    'renewalExpiresAt', 'renewalInstallBaseline', 'authorizationExpiresAt', 'installedUpdateTime', 'installedFingerprint', 'reinstallRequired', 'profilePath', 'profileSha256']) {
    assert.equal(restored[key], job[key], key);
  }
  const ordinary = f.jobs.InstallJob.create('local:ordinary', 0, 'normal.hap', 'local', 'c'.repeat(64));
  await store.save(ordinary);
  assert.equal((await store.get(ordinary.id)).renewalRequestedAt, 0);
  restored.stage = f.jobs.InstallStage.WAITING_CONFIRMATION; await store.save(restored);
  await assert.rejects(store.approveDataLoss(restored.id,
    { versionCode: 8, fingerprint: 'A'.repeat(64), appIdentifier: 'app' }), /应用版本已变化/);
  assert.equal((await store.get(restored.id)).allowDataLoss, false);
  await store.approveDataLoss(restored.id,{versionCode:7,fingerprint:'A'.repeat(64),appIdentifier:'app'});
  const approved=await store.get(restored.id);assert.equal(approved.allowDataLoss,true);
  assert.equal(approved.approvedInstalledFingerprint,'A'.repeat(64));
});

test('store renewal is atomic, deduplicated, durable, and safely reuses the original cached bytes', async t => {
  const f = fixture(t, false), store = await f.JobStore.initialize(f.context);
  const original = f.jobs.InstallJob.create('online:old', 42, 'main.hap', 'https://x/main.hap', 'a'.repeat(64));
  Object.assign(original, { bundleName: 'com.example.app', versionCode: 7, versionName: '1.0',
    stage: f.jobs.InstallStage.INSTALLED, cachePath: '/sandbox/install-jobs/main.hap',
    signedPath: '/sandbox/install-jobs/main.signed.hap', profilePath: '/sandbox/original.p7b',
    allowDataLoss: true, approvedInstalledVersion: 7, signingCertId: '123' });
  f.files.add(original.cachePath); await store.save(original);
  const args = [42, 'main.hap', original.sourceUrl, [], original.bundleName, 7, '1.0'];
  const [a, b] = await Promise.all([store.enqueueRenewal(...args), store.enqueueRenewal(...args)]);
  assert.equal(a.id, b.id); assert.equal(a.renewalRequestedAt, b.renewalRequestedAt);
  assert.equal((await store.listAll()).length, 2);
  const restored = await store.get(a.id);
  assert.equal(restored.stage, f.jobs.InstallStage.QUEUED); assert.ok(restored.renewalRequestedAt > 0);
  assert.equal(restored.reinstallRequired, true); assert.equal(restored.renewalPreparedAt, 0);
  assert.equal(restored.profilePath, original.profilePath); assert.equal(restored.signedProfileSha256, '');
  assert.equal(restored.cachePath, original.cachePath); assert.notEqual(restored.signedPath, original.signedPath);
  assert.equal(restored.allowDataLoss, false); assert.equal(restored.approvedInstalledVersion, 0);
  restored.stage = f.jobs.InstallStage.WAITING_DEVICE; restored.renewalPreparedAt = restored.renewalRequestedAt;
  await store.save(restored);
  assert.equal((await store.enqueueRenewal(...args)).renewalPreparedAt, restored.renewalRequestedAt);
  assert.equal((await store.get(original.id)).signedPath, original.signedPath, 'original journal is intact');
});
test('ordinary in-flight install is retained when renewal is requested', async t => {
  const f = fixture(t, false), store = await f.JobStore.initialize(f.context);
  const job = f.jobs.InstallJob.create('normal', 42, 'main.hap', 'https://x/main.hap', '');
  job.catalogBundleName = 'com.example.app'; job.stage = f.jobs.InstallStage.DOWNLOADING;
  await store.save(job);
  await assert.rejects(store.enqueueRenewal(42, 'main.hap', job.sourceUrl, [], job.catalogBundleName, 7, '1.0'), /已有安装任务/);
  assert.equal((await store.listAll()).length, 1); assert.equal((await store.get(job.id)).stage, job.stage);
});
test('explicit renewal after an old terminal failure creates a new attempt and preserves signing evidence', async t => {
  const f=fixture(t,false),store=await f.JobStore.initialize(f.context);
  const old=f.jobs.InstallJob.create('renew:42:com.example.app:7',42,'main.hap','https://x/main.hap','');
  Object.assign(old,{bundleName:'com.example.app',versionCode:7,renewalRequestedAt:1800000000000,
    stage:f.jobs.InstallStage.TERMINAL_ERROR,lastError:'incompatible identity',profilePath:'/sandbox/failed.p7b'});
  await store.save(old);
  const retry=await store.enqueueRenewal(42,'main.hap',old.sourceUrl,[],old.bundleName,7,'1.0');
  assert.notEqual(retry.id,old.id);assert.ok(retry.renewalRequestedAt>old.renewalRequestedAt);
  assert.equal(retry.stage,f.jobs.InstallStage.QUEUED);
  assert.equal((await store.get(old.id)).lastError,old.lastError);
  retry.stage=f.jobs.InstallStage.INSTALLED;
  Object.assign(retry,{authorizationExpiresAt:1900000000,installedUpdateTime:1800000000100,
    installedFingerprint:'A'.repeat(64),profilePath:'/sandbox/success.p7b'});await store.save(retry);
  const next=await store.enqueueRenewal(42,'main.hap',old.sourceUrl,[],old.bundleName,7,'1.0');
  assert.notEqual(next.id,retry.id);
  const retained=await store.get(retry.id);
  assert.equal(retained.authorizationExpiresAt,1900000000);
  assert.equal(retained.installedFingerprint,'A'.repeat(64));
  assert.equal((await store.listAll()).length,3);
});
test('a missing account is persisted before a store renewal is exposed to the queue observer', async t => {
  const f=fixture(t,false),store=await f.JobStore.initialize(f.context);
  const job=await store.enqueueRenewal(42,'main.hap','https://x/main.hap',[],'com.example.app',7,'1.0',false);
  assert.equal(job.stage,f.jobs.InstallStage.WAITING_ACCOUNT);
  const restored=await store.get(job.id);assert.equal(restored.stage,job.stage);
  assert.equal(restored.lastError,'请先登录开发者账号');assert.ok(restored.renewalRequestedAt>0);
});
