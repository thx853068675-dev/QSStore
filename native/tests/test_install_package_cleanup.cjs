const { test } = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/JobStore.ets'), 'utf8');
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-package-cleanup-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { base, context: { filesDir: base + '/files' }, rows: [], receipts: [], saved: [], stopped: true, fail: '', linked: false };
  f.dir = f.context.filesDir + '/install-jobs'; fs.mkdirSync(f.dir, { recursive: true });
  f.file = (name, age = 3600000) => { const p = f.dir + '/' + name; fs.writeFileSync(p, 'package');
    const time = (Date.now() - age) / 1000; fs.utimesSync(p, time, time); return p; };
  const io = { accessSync: fs.existsSync, listFileSync: fs.readdirSync,
    lstatSync: p => { const s = fs.lstatSync(p); return { mtime: s.mtimeMs / 1000,
      isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() }; },
    unlinkSync: p => { if (f.fail === p) throw Error('EACCES'); fs.unlinkSync(p); } };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText, { exports, require: name => ({
      '@kit.CoreFileKit': { fileIo: io }, './InstallJob': { InstallStage: { INSTALLED: 'installed' } },
      './HdcDeviceBridge': { HdcDeviceBridge: class { static deviceLinked() { return f.linked; }
        async discardStaged() { return false; } } }
    }[name] || {}) });
  f.JobStore = exports.JobStore;
  f.store = new f.JobStore({ executeSql: async (sql, args) => {
    if (sql.startsWith('DELETE FROM cancelled_job_cleanup')) f.receipts = f.receipts.filter(j => j.id !== args[0]);
  } });
  f.store.listAll = async () => f.rows;
  f.store.cancelledFiles = async () => f.receipts;
  f.store.rememberCancelledFiles = async job => f.receipts.push({ ...job });
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
