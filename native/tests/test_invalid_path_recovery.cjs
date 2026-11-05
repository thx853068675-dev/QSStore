const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const jobs = loadEts('jobs/InstallJob');

function fixture() {
  const rows = [], changed = [], cancelled = new Set();
  const fields = { updated_at: 'updatedAt', cache_path: 'cachePath', signed_path: 'signedPath',
    last_error: 'lastError', stage_history: 'stageHistory' };
  class RdbPredicates {
    constructor() { this.matches = []; }
    equalTo(key, value) { this.matches.push([key, value]); return this; }
  }
  const { JobStore } = loadEts('jobs/JobStore', {
    './InstallJob': jobs,
    '@kit.ArkData': { relationalStore: { RdbPredicates } },
    './JobCancellation': { JobCancellation: { isCancelled: id => cancelled.has(id) } }
  });
  const db = { updateSync(values, predicates) {
    const row = rows.find(row => predicates.matches.every(([key, value]) => row[fields[key] || key] === value));
    if (!row) return 0;
    changed.push(row.id);
    for (const [key, value] of Object.entries(values)) {
      row[fields[key] || key] = key === 'stage_history' ? JSON.parse(value) : value;
    }
    return 1;
  } };
  const store = new JobStore(db);
  store.query = async (sql, args) => {
    assert.equal(sql, 'SELECT * FROM install_jobs WHERE stage = ? AND last_error = ?');
    assert.deepEqual(Array.from(args), [jobs.InstallStage.TERMINAL_ERROR, '安装工作目录无效']);
    const snapshots = rows.map(row => jobs.InstallJob.displayCopy(row));
    if (store.afterRead) store.afterRead();
    return snapshots;
  };
  const add = (id, overrides = {}) => {
    const row = jobs.InstallJob.create(id, 7, 'app.hap', 'https://example.com/app.hap', 'a'.repeat(64));
    Object.assign(row, { stage: jobs.InstallStage.TERMINAL_ERROR, lastError: '安装工作目录无效',
      updatedAt: 1234, stageHistory: [{ stage: jobs.InstallStage.QUEUED, at: 1000 },
        { stage: jobs.InstallStage.TERMINAL_ERROR, at: 1234 }] }, overrides);
    rows.push(row); return row;
  };
  return { rows, changed, cancelled, store, add };
}

test('an empty-path terminal failure from the previous planner becomes retryable without a new install request', async () => {
  const f = fixture(), row = f.add('old-empty-path');
  await f.store.recoverInvalidPathFailures();
  assert.equal(row.stage, jobs.InstallStage.RETRYABLE_ERROR);
  assert.equal(row.lastError, '安装准备已修复，左滑卡片继续安装');
  assert.equal(row.updatedAt, 1234); assert.equal(row.stageHistory[0].at, 1000);
  assert.equal(row.stageHistory.at(-1).stage, jobs.InstallStage.RETRYABLE_ERROR);
  assert.equal(row.cachePath, ''); assert.equal(row.signedPath, '');
  assert.deepEqual(f.changed, [row.id]);
  await f.store.recoverInvalidPathFailures();
  assert.deepEqual(f.changed, [row.id], 'startup repair is idempotent');
});

test('repair never restarts failed signing, local files, completed or cancelled installations', async () => {
  const f = fixture();
  for (const [id, overrides] of Object.entries({
    'other-error': { lastError: '签名失败' }, 'installed': { stage: jobs.InstallStage.INSTALLED },
    'private-source': { cachePath: '/sandbox/install-jobs/app.hap' },
    'signed-file': { signedPath: '/sandbox/install-jobs/app.signed.hap' },
    'profile': { profilePath: '/sandbox/profiles/app.p7b' }, 'hash': { profileSha256: 'profile' },
    'signature': { signedProfileSha256: 'signature' }, 'device': { deviceUdid: 'device' },
    'certificate': { signingCertId: 'certificate' }, 'transfer': { transferTaskId: 'transfer' },
    'staged': { stagedTicket: 'staged' }, 'known-app': { bundleName: 'com.example.app' },
    'version': { versionCode: 1 }, 'renewal': { renewalRequestedAt: 12 },
    'local': { appId: 0, sourceUrl: 'local:package' },
    'later-history': { stageHistory: [{ stage: jobs.InstallStage.DOWNLOADING, at: 1234 }] }
  })) f.add(id, overrides);
  f.add('cancelled'); f.cancelled.add('cancelled');
  await f.store.recoverInvalidPathFailures();
  assert.deepEqual(f.changed, []);
});

test('a state change after reading cannot be overwritten by startup path repair', async () => {
  const f = fixture(), row = f.add('restarted');
  f.store.afterRead = () => { row.updatedAt = 2000; row.stage = jobs.InstallStage.QUEUED; row.lastError = ''; };
  await f.store.recoverInvalidPathFailures();
  assert.deepEqual(f.changed, []); assert.equal(row.stage, jobs.InstallStage.QUEUED);
  assert.equal(row.lastError, ''); assert.equal(row.updatedAt, 2000);
});
