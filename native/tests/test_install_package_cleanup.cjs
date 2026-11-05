const { test } = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/JobStore.ets'), 'utf8');
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-package-cleanup-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { base, context: { filesDir: base + '/files' }, rows: [], receipts: [], saved: [], stopped: true, fail: '', linked: false,
    running: new Set(), finishing: new Set(), updated: [], published: [], beforeJournal: undefined };
  f.dir = f.context.filesDir + '/install-jobs'; fs.mkdirSync(f.dir, { recursive: true });
  f.file = (name, age = 3600000) => { const p = f.dir + '/' + name; fs.writeFileSync(p, 'package');
    const time = (Date.now() - age) / 1000; fs.utimesSync(p, time, time); return p; };
  const io = { accessSync: fs.existsSync, listFileSync: fs.readdirSync,
    lstatSync: p => { const s = fs.lstatSync(p); return { mtime: s.mtimeMs / 1000,
      isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() }; },
    unlinkSync: p => { if (f.fail === p) throw Error('EACCES'); fs.unlinkSync(p); } };
  const exports = {};
  const columns = { id: 'id', stage: 'stage', updated_at: 'updatedAt', cache_path: 'cachePath',
    signed_path: 'signedPath', transfer_task_id: 'transferTaskId', staged_ticket: 'stagedTicket', stage_history: 'stageHistory' };
  class RdbPredicates {
    constructor(table) { assert.equal(table, 'install_jobs'); this.matches = []; }
    equalTo(key, value) { this.matches.push([key, value]); return this; }
  }
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText, { exports, require: name => ({
      '@kit.CoreFileKit': { fileIo: io }, '@kit.ArkData': { relationalStore: { RdbPredicates } },
      './InstallJob': { InstallStage: { INSTALLED: 'installed', TERMINAL_ERROR: 'terminal_error' }, StageMark: class {} },
      './JobCancellation': { JobCancellation: { isCancelled: () => false } },
      './InstallTaskState': { InstallTaskState: {
        snapshot: () => f.rows.map(job => ({ job, running: f.running.has(job.id), finishing: f.finishing.has(job.id) })),
        publish: job => f.published.push({ ...job })
      } },
      './HdcDeviceBridge': { HdcDeviceBridge: class { static deviceLinked() { return f.linked; }
        async discardStaged() { return false; } } }
    }[name] || {}) });
  f.JobStore = exports.JobStore;
  f.store = new f.JobStore({ querySqlSync: (_sql, args) => {
    const rows = f.receipts.filter(receipt => receipt.id === args[0]); let index = -1;
    return { goToNextRow: () => ++index < rows.length, getColumnIndex: () => 0,
      getString: () => JSON.stringify(rows[index]), close() {} };
  }, executeSql: async (sql, args) => {
    if (sql.startsWith('DELETE FROM cancelled_job_cleanup')) f.receipts = f.receipts.filter(j =>
      j.id !== args[0] || (args.length > 1 && JSON.stringify(j) !== args[1]));
  }, updateSync: (values, predicates) => {
    if (f.beforeUpdate) f.beforeUpdate();
    const row = f.rows.find(job => predicates.matches.every(([key, value]) => (job[columns[key]] ?? '') === value));
    if (!row) return 0;
    f.updated.push({ ...row });
    for (const [key, value] of Object.entries(values)) row[columns[key]] = key === 'stage_history' ? JSON.parse(value) : value;
    return 1;
  } });
  f.store.listAll = async () => f.rows;
  f.store.cancelledFiles = async (id = '') => f.receipts.filter(row => !id || row.id === id);
  f.store.rememberCancelledFiles = async (job, preserveExisting = false) => {
    if (!preserveExisting || !f.receipts.some(row => row.id === job.id)) {
      f.receipts = f.receipts.filter(receipt => receipt.id !== job.id).concat([{ ...job }]);
    }
    if (f.beforeJournal) await f.beforeJournal(job);
  };
  f.store.save = async job => f.saved.push({ ...job });
  f.store.stopTransfer = async () => f.stopped;
  f.job = (id, stage = 'installed') => ({ id, stage, updatedAt: Date.now(), cachePath: f.dir + '/' + id + '.hap',
    signedPath: f.dir + '/' + id + '.signed.hap', transferTaskId: '', profilePath: f.context.filesDir + '/signing-profiles/test.p7b',
    bundleName: 'com.example.' + id, authorizationExpiresAt: 1900000000, versionCode: 12, stageHistory: [{ stage: 'installed', at: 123 }] });
  return f;
}
test('fresh confirmed packages and extracted modules are deleted while install evidence and Profiles are retained', async t => {
  const f = fixture(t), job = f.job('done'); f.rows = [job];
  for (const name of ['done.hap', 'done.signed.hap', 'done.hap.part', 'done.hap.package.app',
    'done.hap.package.app.module-0.hap', '.done.signed.hap.qingqi-123-456.hap']) f.file(name, 0);
  fs.mkdirSync(path.dirname(job.profilePath)); fs.writeFileSync(job.profilePath, 'authorization');
  const identity = f.context.filesDir + '/identity.pem'; fs.writeFileSync(identity, 'key');
  await f.store.pruneCompleted(f.context);
  assert.equal(fs.readdirSync(f.dir).length, 0); assert.equal(f.receipts.length, 0);
  assert.equal(job.cachePath, ''); assert.equal(job.signedPath, ''); assert.equal(job.stage, 'installed');
  assert.equal(job.authorizationExpiresAt, 1900000000); assert.equal(job.profilePath.endsWith('test.p7b'), true);
  assert.equal(job.versionCode, 12); assert.equal(job.stageHistory[0].at, 123);
  assert.ok(fs.existsSync(job.profilePath)); assert.ok(fs.existsSync(identity));
});
test('incomplete tasks retain package bytes, including packages shared with a completed task', async t => {
  const f = fixture(t), done = f.job('shared'), pending = { ...done, id: 'retry', stage: 'waiting_device' };
  f.file('shared.hap'); f.file('shared.signed.hap'); f.file('shared.hap.package.hap'); f.rows = [done, pending];
  await f.store.pruneCompleted(f.context); assert.equal(pending.cachePath, f.dir + '/shared.hap');
  assert.equal(fs.readdirSync(f.dir).length, 3); assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0);
  f.rows = [done]; await f.store.cleanupOrphanedPackages(f.context); assert.equal(fs.readdirSync(f.dir).length, 0);
});
test('imports and renewal acquisition pin shared packages until their task has been saved', async t => {
  const f = fixture(t), job = f.job('pinned'); f.rows = [job]; f.file('pinned.hap'); f.file('pinned.signed.hap');
  const a = f.JobStore.reservePackage(job.cachePath), b = f.JobStore.reservePackage(job.cachePath);
  await f.store.pruneCompleted(f.context); assert.equal(f.saved.length, 0);
  a(); a(); await f.store.pruneCompleted(f.context); assert.equal(f.saved.length, 0);
  b(); await f.store.pruneCompleted(f.context); assert.equal(fs.readdirSync(f.dir).length, 0);
});
test('startup orphan sweep removes abandoned packages and partials, protecting references, fresh files and unrelated data', async t => {
  const f = fixture(t); f.file('orphan.hap'); f.file('orphan.signed.app'); f.file('orphan.zip.part');
  const fresh = f.file('fresh.hap', 0), future = f.file('future.hap', -600000);
  const unknown = f.file('identity.json'); const kept = f.file('pending.app'); f.file('pending.app.module-0.hap');
  f.rows = [{ cachePath: kept, signedPath: '', stage: 'retryable_error' }];
  const original = f.base + '/user-original.hap'; fs.writeFileSync(original, 'user');
  fs.symlinkSync(original, f.dir + '/linked.hap'); fs.mkdirSync(f.dir + '/directory.hap');
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 3);
  for (const p of [fresh, future, unknown, kept, original, f.dir + '/linked.hap', f.dir + '/directory.hap']) assert.ok(fs.existsSync(p));
});
test('a system download that cannot be stopped retains its cleanup receipt and cannot be mistaken for an orphan', async t => {
  const f = fixture(t), job = f.job('agent'); job.transferTaskId = 'running';
  f.file('agent.hap'); f.file('agent.hap.part'); f.rows = [job]; f.stopped = false;
  await f.store.pruneCompleted(f.context); assert.equal(f.receipts.length, 1);
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0); assert.equal(fs.readdirSync(f.dir).length, 2);
  f.stopped = true; await f.store.cleanupCancelled(f.context); assert.equal(fs.readdirSync(f.dir).length, 0);
});
test('partial cleanup failure keeps its durable receipt and resumes later', async t => {
  const f = fixture(t), job = f.job('failure'); f.rows = [job]; f.file('failure.hap'); f.file('failure.signed.hap');
  f.fail = job.signedPath; await f.store.pruneCompleted(f.context);
  assert.equal(f.receipts.length, 1); assert.equal(fs.readdirSync(f.dir).length, 1);
  f.fail = ''; await f.store.cleanupCancelled(f.context); assert.equal(f.receipts.length, 0);
  assert.equal(fs.readdirSync(f.dir).length, 0);
});
test('only signed bytes remaining after a prior interrupted cleanup are also released', async t => {
  const f = fixture(t), job = f.job('signedonly'); f.file('signedonly.signed.hap'); job.cachePath = ''; f.rows = [job];
  await f.store.pruneCompleted(f.context); assert.equal(fs.readdirSync(f.dir).length, 0);
});
test('orphan cleanup refuses symlink roots and unreadable ownership journals', async t => {
  const f = fixture(t); f.file('orphan.hap'); f.store.listAll = async () => { throw Error('broken journal'); };
  await assert.rejects(f.store.cleanupOrphanedPackages(f.context), /broken journal/);
  assert.ok(fs.existsSync(f.dir + '/orphan.hap'));
  const target = f.base + '/other'; fs.mkdirSync(target); fs.renameSync(f.dir + '/orphan.hap', target + '/orphan.hap');
  fs.rmdirSync(f.dir); fs.symlinkSync(target, f.dir);
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0); assert.ok(fs.existsSync(target + '/orphan.hap'));
});

function supersededFixture(t, nextStage = 'installed') {
  const f = fixture(t), old = f.job('obsolete', 'terminal_error'), next = f.job('new', nextStage);
  old.bundleName = next.bundleName = 'com.example.sameapp';
  old.stageHistory = [{ stage: 'queued', at: 100 }, { stage: 'terminal_error', at: 150 }];
  next.stageHistory = [{ stage: 'queued', at: 200 }];
  old.updatedAt = Date.now(); next.updatedAt = 250;
  old.lastError = 'invalid package'; old.attempt = 2;
  f.paths = [old.cachePath, old.signedPath];
  f.file('obsolete.hap'); f.file('obsolete.signed.hap');
  if (nextStage === 'installed') { next.cachePath = ''; next.signedPath = ''; }
  f.rows = [old, next];
  return { f, old, next };
}

test('superseded terminal failure releases large old packages after later success while preserving error and signing history', async t => {
  const { f, old } = supersededFixture(t);
  fs.truncateSync(old.cachePath, 616 * 1024 * 1024);
  fs.mkdirSync(path.dirname(old.profilePath)); fs.writeFileSync(old.profilePath, 'profile');
  const identity = f.context.filesDir + '/key.pem'; fs.writeFileSync(identity, 'private key');
  const history = JSON.stringify(old.stageHistory), timestamp = old.updatedAt;
  await f.store.pruneSupersededFailures(f.context);
  assert.ok(f.paths.every(file => !fs.existsSync(file)));
  assert.equal(old.cachePath, ''); assert.equal(old.signedPath, ''); assert.equal(f.receipts.length, 0);
  assert.equal(old.stage, 'terminal_error'); assert.equal(old.lastError, 'invalid package'); assert.equal(old.attempt, 2);
  assert.equal(JSON.stringify(old.stageHistory), history); assert.equal(old.updatedAt, timestamp,
    'eviction must not become a newer user request');
  assert.ok(fs.existsSync(old.profilePath)); assert.ok(fs.existsSync(identity));
  assert.equal(old.authorizationExpiresAt, 1900000000);
});

test('later paused installation replaces only the obsolete failure, retaining the current package and retryable task', async t => {
  const { f, old, next } = supersededFixture(t, 'waiting_device');
  f.file('new.hap'); f.file('new.signed.hap');
  const current = JSON.stringify(next);
  await f.store.pruneSupersededFailures(f.context);
  assert.ok(f.paths.every(file => !fs.existsSync(file)));
  assert.equal(old.cachePath, ''); assert.equal(JSON.stringify(next), current);
  assert.ok(fs.existsSync(next.cachePath)); assert.ok(fs.existsSync(next.signedPath));
});

test('the latest terminal failure and retryable pauses are retained; cache-save timestamps cannot supersede them', async t => {
  const { f, old, next } = supersededFixture(t);
  next.stageHistory = [{ stage: 'queued', at: 50 }]; next.updatedAt = Date.now() + 1000;
  await f.store.pruneSupersededFailures(f.context); assert.ok(f.paths.every(fs.existsSync));
  next.stageHistory = [{ stage: 'queued', at: 200 }];
  old.renewalRequestedAt = 300;
  await f.store.pruneSupersededFailures(f.context); assert.ok(f.paths.every(fs.existsSync));
  old.renewalRequestedAt = 0; old.stage = 'waiting_network';
  await f.store.pruneSupersededFailures(f.context); assert.ok(f.paths.every(fs.existsSync));
  old.stage = 'terminal_error'; next.bundleName = 'com.example.different';
  await f.store.pruneSupersededFailures(f.context); assert.ok(f.paths.every(fs.existsSync));
  assert.equal(f.updated.length, 0); assert.equal(f.receipts.length, 0);
});

test('superseded failure cleanup respects shared current packages, running work, finishing work and import pins', async t => {
  const { f, old, next } = supersededFixture(t, 'downloading');
  next.cachePath = old.cachePath; next.signedPath = old.signedPath;
  f.running.add(old.id); await f.store.pruneSupersededFailures(f.context);
  f.running.delete(old.id); f.finishing.add(old.id); await f.store.pruneSupersededFailures(f.context);
  f.finishing.delete(old.id); const release = f.JobStore.reservePackage(old.cachePath);
  await f.store.pruneSupersededFailures(f.context); assert.equal(f.updated.length, 0);
  release(); await f.store.pruneSupersededFailures(f.context);
  assert.equal(old.cachePath, ''); assert.equal(f.updated.length, 1);
  assert.ok(fs.existsSync(next.cachePath)); assert.ok(fs.existsSync(next.signedPath));
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0);
});

test('a still-active system writer is protected by its durable cleanup receipt until removal succeeds', async t => {
  const { f, old } = supersededFixture(t);
  old.transferTaskId = 'still-downloading'; f.stopped = false;
  f.file('obsolete.hap.part');
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(old.cachePath, ''); assert.equal(f.receipts.length, 1);
  assert.ok(f.paths.every(fs.existsSync)); assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0);
  f.stopped = true; await f.store.cleanupCancelled(f.context);
  assert.equal(f.receipts.length, 0); assert.equal(fs.readdirSync(f.dir).length, 0);
});

test('journal interruption and partial unlink failures remain recoverable without losing old error history', async t => {
  const { f, old } = supersededFixture(t);
  const history = JSON.stringify(old.stageHistory);
  f.beforeUpdate = () => { throw Error('interrupted before conditional update'); };
  await assert.rejects(f.store.pruneSupersededFailures(f.context), /interrupted/);
  assert.equal(f.receipts.length, 1); assert.ok(f.paths.every(fs.existsSync));
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0);
  f.beforeUpdate = undefined; f.fail = old.signedPath;
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(old.cachePath, ''); assert.equal(f.receipts.length, 1); assert.equal(fs.readdirSync(f.dir).length, 1);
  assert.equal(await f.store.cleanupOrphanedPackages(f.context), 0);
  f.fail = ''; await f.store.cleanupCancelled(f.context);
  assert.equal(f.receipts.length, 0); assert.equal(fs.readdirSync(f.dir).length, 0);
  assert.equal(old.lastError, 'invalid package'); assert.equal(JSON.stringify(old.stageHistory), history);
});

test('a retry started while journaling is not overwritten or cleaned by an obsolete failure snapshot', async t => {
  const { f, old } = supersededFixture(t);
  f.beforeJournal = async () => { f.running.add(old.id); };
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(f.updated.length, 0); assert.equal(f.receipts.length, 0);
  assert.ok(f.paths.every(fs.existsSync)); assert.equal(old.stage, 'terminal_error');
  f.running.clear(); f.beforeJournal = undefined;
  f.beforeUpdate = () => {
    f.rows = f.rows.map(row => row.id === old.id ? { ...row, stage: 'downloading', updatedAt: row.updatedAt + 1 } : row);
  };
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(f.updated.length, 0); assert.equal(f.receipts.length, 0);
  assert.equal(f.rows[0].stage, 'downloading'); assert.ok(f.paths.every(fs.existsSync));
});

test('superseded eviction never replaces another cleanup receipt or removes a transfer shared by a current task', async t => {
  const { f, old, next } = supersededFixture(t, 'waiting_network');
  const different = { ...old, cachePath: f.file('earlier-cleanup.hap') };
  f.receipts = [different];
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(f.updated.length, 0); assert.equal(f.receipts[0], different); assert.ok(f.paths.every(fs.existsSync));
  f.receipts = []; old.transferTaskId = next.transferTaskId = 'shared-system-transfer';
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(f.updated.length, 0); assert.equal(f.receipts.length, 0); assert.ok(f.paths.every(fs.existsSync));
});

test('pruning an empty-history legacy success cannot make it supersede a later failure during startup or Settings cleanup', async t => {
  const { f, old, next } = supersededFixture(t, 'terminal_error');
  old.stage = 'installed'; old.stageHistory = []; old.updatedAt = 100;
  next.stageHistory = []; next.updatedAt = 200;
  f.file('new.hap'); f.file('new.signed.hap');
  // Use production save/markStage: its timestamp update is exactly what previously
  // promoted an old completed receipt above the user's current failed request.
  f.store.save = f.JobStore.prototype.save.bind(f.store);
  await f.store.pruneCompleted(f.context);
  assert.equal(old.updatedAt, 100, 'maintenance must retain the original request timestamp');
  assert.equal(old.stageHistory[0].at, 100, 'the original ordering fallback was migrated before save()');
  await f.store.pruneSupersededFailures(f.context);
  assert.equal(f.updated.filter(row => row.id === next.id).length, 0); assert.equal(next.stage, 'terminal_error');
  assert.ok(fs.existsSync(next.cachePath)); assert.ok(fs.existsSync(next.signedPath));
  await f.store.pruneCompleted(f.context); await f.store.pruneSupersededFailures(f.context);
  assert.ok(fs.existsSync(next.cachePath)); assert.equal(old.stageHistory[0].at, 100,
    'repeated startup/cache cleanup retains the same user-request ordering');
});

test('empty-history completed renewals preserve renewal request ordering across cache eviction', async t => {
  const { f, old, next } = supersededFixture(t, 'terminal_error');
  old.stage = 'installed'; old.stageHistory = []; old.updatedAt = 100; old.renewalRequestedAt = 250;
  next.stageHistory = []; next.updatedAt = 300;
  f.file('new.hap'); f.file('new.signed.hap');
  f.store.save = f.JobStore.prototype.save.bind(f.store);
  await f.store.pruneCompleted(f.context); await f.store.pruneSupersededFailures(f.context);
  assert.equal(old.renewalRequestedAt, 250); assert.equal(old.stageHistory[0].at, 100);
  assert.equal(f.updated.filter(row => row.id === next.id).length, 0); assert.ok(fs.existsSync(next.cachePath)); assert.ok(fs.existsSync(next.signedPath));
});

function useDatabaseCleanupReceipt(f, job) {
  const state = { payload: JSON.stringify(job, null, 2), deleted: 0, beforeDelete: undefined };
  f.store.cancelledFiles = f.JobStore.prototype.cancelledFiles.bind(f.store);
  const query = (_sql, args) => {
    const rows = state.payload !== undefined && (!args.length || args[0] === job.id) ? [state.payload] : [];
    let index = -1;
    return { goToNextRow: () => ++index < rows.length, getColumnIndex: key => {
      assert.equal(key, 'payload'); return 0;
    }, getString: () => rows[index], close() {} };
  };
  f.store.db.querySql = async (...args) => query(...args);
  f.store.db.querySqlSync = query;
  f.store.db.executeSql = async (sql, args) => {
    assert.equal(sql, 'DELETE FROM cancelled_job_cleanup WHERE id = ? AND payload = ?');
    if (state.beforeDelete) await state.beforeDelete();
    if (args[0] === job.id && args[1] === state.payload) { state.payload = undefined; state.deleted++; }
  };
  return state;
}

test('a replacement same-ID receipt written during transfer cancellation keeps its reused paths and writer', async t => {
  const f = fixture(t), old = f.job('same-id');
  f.file('same-id.hap'); f.file('same-id.signed.hap');
  old.transferTaskId = 'old-transfer';
  const state = useDatabaseCleanupReceipt(f, old);
  const replacement = { ...old, transferTaskId: 'new-transfer', updatedAt: old.updatedAt + 1 };
  f.store.stopTransfer = async (_, observed) => {
    assert.equal(observed.transferTaskId, 'old-transfer');
    await Promise.resolve(); state.payload = JSON.stringify(replacement); return true;
  };
  await f.store.cleanupCancelled(f.context);
  assert.equal(state.payload, JSON.stringify(replacement)); assert.equal(state.deleted, 0);
  assert.ok(fs.existsSync(old.cachePath)); assert.ok(fs.existsSync(old.signedPath));
});

test('a replacement receipt written during the ownership query cannot be removed or have its shared file unlinked', async t => {
  const f = fixture(t), old = f.job('ownership-race');
  f.file('ownership-race.hap'); f.file('ownership-race.signed.hap');
  const state = useDatabaseCleanupReceipt(f, old);
  const replacement = { ...old, signedPath: f.file('new-cleanup.signed.hap'), transferTaskId: 'new-writer' };
  f.store.listAll = async () => {
    await Promise.resolve(); state.payload = JSON.stringify(replacement); return [];
  };
  await f.store.cleanupCancelled(f.context);
  assert.equal(state.payload, JSON.stringify(replacement)); assert.equal(state.deleted, 0);
  assert.ok(fs.existsSync(old.cachePath)); assert.ok(fs.existsSync(old.signedPath));
  assert.ok(fs.existsSync(replacement.signedPath));
});

test('final receipt deletion compares the exact originally read payload even when the parsed object changes', async t => {
  const f = fixture(t), old = f.job('immutable-payload');
  f.file('immutable-payload.hap'); f.file('immutable-payload.signed.hap');
  const state = useDatabaseCleanupReceipt(f, old);
  f.store.stopTransfer = async (_, observed) => { await Promise.resolve(); observed.lastError = 'mutable observer'; return true; };
  await f.store.cleanupCancelled(f.context);
  assert.equal(state.deleted, 1); assert.equal(state.payload, undefined);
  assert.ok(!fs.existsSync(old.cachePath)); assert.ok(!fs.existsSync(old.signedPath));
});

test('a new cancellation arriving at the final database await survives the old cleanup DELETE', async t => {
  const f = fixture(t), old = f.job('delete-race');
  f.file('delete-race.hap'); f.file('delete-race.signed.hap');
  const state = useDatabaseCleanupReceipt(f, old);
  const replacement = { ...old, transferTaskId: 'replacement-transfer', updatedAt: old.updatedAt + 1 };
  state.beforeDelete = async () => {
    await Promise.resolve(); state.payload = JSON.stringify(replacement);
    fs.writeFileSync(old.cachePath, 'new writer');
  };
  await f.store.cleanupCancelled(f.context);
  assert.equal(state.deleted, 0); assert.equal(state.payload, JSON.stringify(replacement));
  assert.equal(fs.readFileSync(old.cachePath, 'utf8'), 'new writer');
});
