const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { loadEts } = require('./load_ets.cjs');
const { InstallJob, InstallStage } = loadEts('jobs/InstallJob');
const { releaseDisplayVersion } = loadEts('data/DisplayVersion');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }

function fixture(t, options = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-download-library-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { context: { filesDir: base + '/files' }, public: base + '/Download/轻启·安装器', copies: 0, hashReads: [], copyGate: undefined,
    badCopy: false, failMetadata: false, title: '测试应用' };
  f.work = f.context.filesDir + '/install-jobs'; fs.mkdirSync(f.work, { recursive: true });
  const io = {
    accessSync: fs.existsSync, mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive }),
    lstatSync: fs.lstatSync, lstat: fs.promises.lstat,
    readText: p => fs.promises.readFile(p, 'utf8'), listFile: fs.promises.readdir,
    listFileSync: fs.readdirSync, unlinkSync: p => {
      if (f.failUnlink === p) throw Error('file busy');
      if (f.unlinkHook) f.unlinkHook(p);
      fs.unlinkSync(p);
    },
    copyFile: async (a, b) => {
      f.copies++; if (f.copyStarted) f.copyStarted.resolve(); if (f.copyGate) await f.copyGate.promise;
      if (typeof b === 'number') fs.writeSync(b, await fs.promises.readFile(a));
      else await fs.promises.copyFile(a, b);
      if (f.badCopy) {
        if (typeof b === 'number') { fs.ftruncateSync(b, 0); fs.writeSync(b, Buffer.from('changed'), 0, 7, 0); }
        else fs.writeFileSync(b, 'changed');
      }
    },
    renameSync: (a, b) => {
      if ((f.failMetadata || f.failReceipt === b) && b.endsWith('.json')) throw Error('disk full');
      fs.renameSync(a, b);
    },
    OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4, NOFOLLOW: 8 },
    openSync: (p, flags) => ({ fd: fs.openSync(p, flags & 8 ?
      fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW : 'w') }),
    closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
    writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes))
  };
  f.io = io;
  let publicModule = { DownloadDirectoryLocation: class {}, PublicDownloadDirectory: { ensure: async () => {
    if (f.failPublic) throw Error('public download access denied');
    if (!fs.existsSync(f.public)) fs.mkdirSync(f.public, { recursive: true });
    return { path: f.public, uri: 'file://docs' + f.public, displayPath: f.publicDisplay ?? '下载/轻启·安装器',
      knownPaths: f.knownPublicPaths ?? [f.public] };
  } } };
  if (options.realPublicHelper) {
    f.publicRoot = path.dirname(f.public); f.grantedApp = f.public; f.public += '/download';
    f.saves = 0; f.publicCreates = []; f.publicAccess = [];
    fs.mkdirSync(f.grantedApp, { recursive: true }); // This existing directory is supplied by the operating system.
    const uriOf = p => 'file://docs' + p.split('/').map(encodeURIComponent).join('/');
    io.AccessModeType = { READ_WRITE: 6 };
    io.access = async (p, mode) => {
      f.publicAccess.push([p, mode]);
      if (p === f.publicRoot && mode === 6) throw Error('parent permission denied');
      try { await fs.promises.access(p, mode ?? fs.constants.F_OK); return true; }
      catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    };
    io.mkdir = async p => {
      f.publicCreates.push(p);
      if (p === f.publicRoot || !p.startsWith(f.grantedApp + '/')) throw Error('parent permission denied');
      return fs.promises.mkdir(p); // No guessed parents or recursive helper mkdir.
    };
    publicModule = loadEts('jobs/PublicDownloadDirectory', { '@kit.CoreFileKit': {
      fileIo: io, fileUri: { FileUri: class {
        constructor(uri) { const parsed = new URL(uri); this.path = decodeURIComponent(parsed.pathname); this.host = parsed.host; }
        isRemoteUri() { return this.host !== 'docs'; }
      } }, picker: { DocumentPickerMode: { DOWNLOAD: 'DOWNLOAD' }, DocumentViewPicker: class {
        constructor(ctx) { assert.equal(ctx, f.context); }
        async save(value) { f.saves++; assert.deepEqual(JSON.parse(JSON.stringify(value)), { pickerMode: 'DOWNLOAD' }); return [uriOf(f.grantedApp)]; }
        select() { assert.fail('public downloads must not open another folder picker'); }
      } }
    } });
  }
  f.load = () => loadEts('jobs/DownloadLibrary', {
    '@kit.CoreFileKit': { fileIo: io, hash: { hash: async p => {
      f.hashReads.push(p);
      if (f.hashHook) await f.hashHook(p);
      return digest(await fs.promises.readFile(p));
    } } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '../data/DisplayVersion': { releaseDisplayVersion },
    './ReleaseUpdate': { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate() },
    './InstalledAppRegistry': { InstalledAppRegistry: { displayName: () => f.title } },
    './InstallJob': { InstallJob, InstallStage },
    './PublicDownloadDirectory': publicModule
  }).DownloadLibrary;
  f.library = f.load();
  f.store = () => {
    const rows = [], receipts = [], saved = [], running = new Set();
    const columns = { id: 'id', stage: 'stage', updated_at: 'updatedAt', cache_path: 'cachePath',
      signed_path: 'signedPath', transfer_task_id: 'transferTaskId', staged_ticket: 'stagedTicket' };
    class RdbPredicates {
      constructor() { this.matches = []; }
      equalTo(key, value) { this.matches.push([key, value]); return this; }
    }
    const { JobStore } = loadEts('jobs/JobStore', {
      '@kit.CoreFileKit': { fileIo: io }, './DownloadLibrary': { DownloadLibrary: f.library },
      '@kit.ArkData': { relationalStore: { RdbPredicates } },
      './InstallJob': { InstallJob, InstallStage, StageMark: class {} },
      './DownloadPreferences': { DownloadPreferences: {
        load: async () => { if (f.failPreference) throw Error('settings unavailable'); return f.autoClean === true; },
        enabledSince: async () => f.enabledSince ?? 1000
      } },
      './ReleaseUpdate': { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate() },
      './JobCancellation': { JobCancellation: { isCancelled: () => Boolean(f.cancelled) } },
      './InstallTaskState': { InstallTaskState: { snapshot: () => rows.map(job => ({ job, running: running.has(job.id) })), publish() {} } }
    });
    const store = new JobStore({ executeSql: async (sql, args) => {
      if (sql.startsWith('DELETE FROM cancelled_job_cleanup')) {
        const at = receipts.findIndex(job => job.id === args[0]); if (at !== -1) receipts.splice(at, 1);
      }
    }, querySqlSync: (sql, args) => {
      const keys = ['id', 'stage', 'updatedAt', 'cachePath', 'signedPath', 'transferTaskId', 'stagedTicket'];
      const matches = sql.startsWith('SELECT id FROM install_jobs') ?
        rows.filter(job => keys.every((key, index) => (job[key] ?? '') === args[index])) : receipts.filter(job => job.id === args[0]);
      let at = -1;
      return { goToNextRow: () => ++at < matches.length, getColumnIndex: () => 0,
        getString: () => JSON.stringify(matches[at]), close() {} };
    }, updateSync: (values, predicates) => {
      if (f.updateHook) f.updateHook();
      if (f.failUpdate) throw Error('journal write interrupted');
      const row = rows.find(job => predicates.matches.every(([key, value]) => (job[columns[key]] ?? '') === value));
      if (!row) return 0;
      for (const [key, value] of Object.entries(values)) {
        if (key === 'stage_history') row.stageHistory = JSON.parse(value);
        else row[columns[key]] = value;
      }
      saved.push({ ...row }); return 1;
    } });
    store.listAll = async () => rows.map(job => InstallJob.displayCopy(job));
    store.cancelledFiles = async (id = '') => receipts.filter(job => !id || job.id === id);
    store.rememberCancelledFiles = async (job, preserveExisting) => {
      if (!preserveExisting || !receipts.some(value => value.id === job.id)) receipts.push({ ...job });
      if (f.journalHook) await f.journalHook();
    };
    store.save = async job => saved.push({ ...job });
    store.stopTransfer = async () => true;
    return { store, rows, receipts, saved, running, JobStore };
  };
  f.job = (name = 'app-1.2.3.hap', bytes = Buffer.from('original:' + name)) => {
    const sha = digest(bytes), cachePath = f.work + '/' + sha + '.hap';
    fs.writeFileSync(cachePath, bytes); fs.writeFileSync(cachePath + '.signed.hap', 'signed');
    return Object.assign(new InstallJob(), { id: 'online:' + sha, appId: 7, assetName: name,
      sourceUrl: 'https://github.com/o/r/releases/download/v1.2.3/' + encodeURIComponent(name),
      expectedSha256: sha, cachePath, signedPath: cachePath + '.signed.hap',
      bundleName: 'com.example.app', versionCode: 123, versionName: '1.0.0', releaseTag: 'v1.2.3',
      stage: InstallStage.INSTALLED, updatedAt: 3000,
      stageHistory: [{ stage: InstallStage.INSTALLED, at: 2000 }] });
  };
  f.seedLegacy = (name = '旧应用-1.2.3.hap', bytes = Buffer.from('legacy original:' + name)) => {
    const id = digest(bytes), directory = f.context.filesDir + '/downloads', receipts = f.context.filesDir + '/download-receipts';
    fs.mkdirSync(directory, { recursive: true }); fs.mkdirSync(receipts, { recursive: true });
    const row = { id, path: directory + '/' + id + path.extname(name), name, title: '原应用中文名',
      version: '1.2.3', bytes: bytes.length, sha256: id, createdAt: 42, appId: 9, bundleName: 'com.example.legacy' };
    fs.writeFileSync(row.path, bytes);
    fs.writeFileSync(receipts + '/' + id + '.json', JSON.stringify(row));
    return row;
  };
  return f;
}

test('original HAP, whole APP and compressed packages keep their real extension and private receipts', async t => {
  const f = fixture(t);
  for (const name of ['app.hap', 'app.app', 'app.zip / entry.hap', 'app.app.zip / package.app', 'app.7z', 'app.tar.gz']) {
    const job = f.job(name); await f.library.keep(f.context, job);
    const row = (await f.library.list(f.context)).find(value => value.id === job.expectedSha256);
    assert.ok(row); assert.equal(row.name, name.split(' / ')[0]);
    assert.ok(path.basename(row.path).startsWith(row.name.replace(/\.(tar\.gz|hap|app|zip|7z)$/i, '') + '-'));
    assert.ok(row.path.includes(job.expectedSha256));
    assert.ok(row.path.endsWith(/tar\.gz$/i.test(row.name) ? '.tar.gz' : path.extname(row.name)));
    assert.equal(row.title, '测试应用'); assert.equal(row.version, '1.2.3');
    assert.equal(row.createdAt, 2000); assert.equal(row.appId, 7); assert.equal(row.bundleName, job.bundleName);
    assert.equal(row.bytes, fs.statSync(job.cachePath).size);
    assert.deepEqual(fs.readFileSync(row.path), fs.readFileSync(job.cachePath));
    assert.ok(fs.existsSync(job.signedPath), 'archival itself never deletes a signing workspace');
  }
  assert.ok(fs.readdirSync(f.public).every(name => !name.includes('.json')));
  assert.equal(fs.existsSync(f.context.filesDir + '/downloads'), false, 'new installs never recreate the old sandbox directory');
  assert.equal(fs.readdirSync(f.context.filesDir + '/download-receipts').filter(name => name.endsWith('.json')).length, 6);
});

test('concurrent identical downloads deduplicate bytes and preserve their original archive time after restart', async t => {
  const f = fixture(t), job = f.job();
  const again = { ...job, id: 'again', updatedAt: 9000, stageHistory: [{ stage: InstallStage.INSTALLED, at: 8000 }] };
  await Promise.all([f.library.keep(f.context, job), f.library.keep(f.context, again)]);
  assert.equal(f.copies, 1);
  const rows = await f.load().list(f.context); assert.equal(rows.length, 1); assert.equal(rows[0].createdAt, 2000);
  assert.equal(rows[0].sha256, job.expectedSha256);
});

test('archive filenames remain readable, bounded by UTF-8 bytes and isolated across equal asset names', async t => {
  const f = fixture(t), longName = '应用😀'.repeat(80) + '.tar.gz';
  const first = f.job(longName), second = f.job(longName, Buffer.from('different original'));
  await f.library.keep(f.context, first); await f.library.keep(f.context, second);
  const rows = await f.library.list(f.context); assert.equal(rows.length, 2);
  for (const row of rows) {
    const name = path.basename(row.path), prefix = name.slice(0, name.indexOf('-' + row.id));
    assert.ok(name.startsWith('应用😀')); assert.ok(name.endsWith('-' + row.id + '.tar.gz'));
    assert.ok(Array.from(prefix).length <= 40); assert.ok(Buffer.byteLength(prefix) <= 120);
    assert.ok(Buffer.byteLength(name) < 256);
    assert.equal(row.name, longName);
  }
  assert.notEqual(rows[0].path, rows[1].path);
  const traversal = f.job('../other/\\name\u0000.hap'); await f.library.keep(f.context, traversal);
  const row = (await f.library.list(f.context)).find(value => value.id === traversal.expectedSha256);
  assert.equal(path.dirname(row.path), await f.library.directory(f.context));
  assert.ok(!/[\\\u0000-\u001f]/.test(path.basename(row.path)));
});

test('existing SHA-only archives remain usable and clear recognizes friendly-name orphan partials', async t => {
  const f = fixture(t), job = f.job('old.app'); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context), directory = await f.library.directory(f.context), oldPath = directory + '/' + row.id + '.app';
  fs.renameSync(row.path, oldPath);
  fs.writeFileSync(f.context.filesDir + '/download-receipts/' + row.id + '.json', JSON.stringify({ ...row, path: oldPath }));
  assert.equal((await f.library.verify(f.context, row.id)).path, oldPath);
  await f.library.keep(f.context, job); assert.equal(f.copies, 1, 'existing legacy archive is not copied again');
  fs.writeFileSync(directory + '/未完成-' + 'f'.repeat(64) + '.zip.part', 'partial');
  fs.writeFileSync(directory + '/user-file.zip', 'user original');
  assert.equal(await f.library.clear(f.context), 1);
  assert.deepEqual(fs.readdirSync(directory), ['user-file.zip']);
});

for (const operation of ['remove', 'clear', 'external']) test(operation + ' tombstones survive restart and cannot revive old completed packages', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context);
  if (operation === 'external') fs.unlinkSync(row.path);
  else if (operation === 'clear') assert.equal(await f.library.clear(f.context), 1);
  else assert.equal(await f.library.remove(f.context, row.id), true);
  const restarted = f.load();
  await restarted.keep(f.context, job); // Startup pruning may run before a UI list scan.
  assert.equal((await restarted.list(f.context)).length, 0);
  assert.ok(fs.existsSync(job.cachePath), 'keep itself leaves workspace cleanup to the journal');
  const receipt = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + row.id + '.json', 'utf8'));
  assert.ok(receipt.deletedAt > 0);
  const later = { ...job, updatedAt: receipt.deletedAt + 1,
    stageHistory: [{ stage: InstallStage.INSTALLED, at: receipt.deletedAt + 1 }] };
  await restarted.keep(f.context, later);
  assert.equal((await restarted.list(f.context)).length, 1, 'a real later installation can retain a fresh original again');
});

test('local, failed and pending jobs are not duplicated in the download library', async t => {
  const f = fixture(t), job = f.job();
  for (const value of [{ ...job, sourceUrl: 'local' }, { ...job, stage: InstallStage.RETRYABLE_ERROR },
    { ...job, stage: InstallStage.DOWNLOADING }, { ...job, cachePath: '' }]) await f.library.keep(f.context, value);
  assert.equal((await f.library.list(f.context)).length, 0); assert.equal(f.copies, 0);
  assert.ok(fs.existsSync(job.cachePath));
});

test('interrupted or corrupted archival preserves the source and a later attempt seals a verified receipt', async t => {
  const f = fixture(t), job = f.job();
  f.badCopy = true; await assert.rejects(f.library.keep(f.context, job), /已变化/);
  assert.equal((await f.library.list(f.context)).length, 0); assert.ok(fs.existsSync(job.cachePath));
  f.badCopy = false; f.failMetadata = true;
  await assert.rejects(f.library.keep(f.context, job), /disk full/);
  assert.equal((await f.library.list(f.context)).length, 0); assert.ok(fs.existsSync(job.signedPath));
  f.failMetadata = false; await f.library.keep(f.context, job);
  assert.equal((await f.library.list(f.context)).length, 1);
  assert.equal((await f.library.verify(f.context, job.expectedSha256)).sha256, job.expectedSha256);
});

test('a file changed through shared directory access fails verification and a valid later download repairs it', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context);
  const original = fs.readFileSync(row.path); fs.writeFileSync(row.path, Buffer.alloc(original.length, 42));
  await assert.rejects(f.library.verify(f.context, row.id), /已变化/);
  await f.library.keep(f.context, job); assert.deepEqual(fs.readFileSync(row.path), original);
});

test('externally deleted originals remove their stale receipt, and altered paths or symlinks are never followed', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context), receipt = f.context.filesDir + '/download-receipts/' + row.id + '.json';
  const bytes = fs.readFileSync(row.path); fs.unlinkSync(row.path);
  assert.equal((await f.load().list(f.context)).length, 0);
  assert.ok(JSON.parse(fs.readFileSync(receipt, 'utf8')).deletedAt > 0);
  job.stageHistory[0].at = Date.now() + 1;
  await f.library.keep(f.context, job);
  const outside = f.context.filesDir + '/identity.pem'; fs.writeFileSync(outside, bytes);
  fs.unlinkSync(row.path); fs.symlinkSync(outside, row.path);
  assert.equal((await f.library.list(f.context)).length, 0);
  await assert.rejects(f.library.verify(f.context, row.id));
  await f.library.clear(f.context); assert.ok(fs.existsSync(outside));
  fs.unlinkSync(row.path); fs.writeFileSync(row.path, bytes);
  fs.writeFileSync(receipt, JSON.stringify({ ...row, path: outside }));
  assert.equal((await f.library.list(f.context)).length, 0);
  await assert.rejects(f.library.remove(f.context, '../identity.pem'));
  assert.ok(fs.existsSync(outside));
});

test('source and download directory symlinks cannot archive or expose unrelated data', async t => {
  const f = fixture(t), job = f.job();
  fs.renameSync(f.work, f.work + '-real'); fs.symlinkSync(f.work + '-real', f.work);
  await assert.rejects(f.library.keep(f.context, job), /下载目录不可用/);
  const outside = f.context.filesDir + '/unrelated'; fs.mkdirSync(outside);
  fs.symlinkSync(outside, f.context.filesDir + '/downloads');
  await assert.rejects(f.library.list(f.context), /下载目录不可用/);
});

test('export pins survive repeated release calls and prevent delete/clear until readers finish', async t => {
  const f = fixture(t), first = f.job(), second = f.job('other.app');
  await f.library.keep(f.context, first); await f.library.keep(f.context, second);
  const one = f.library.reserve(f.context, first.expectedSha256), two = f.library.reserve(f.context, first.expectedSha256);
  assert.equal(await f.library.remove(f.context, first.expectedSha256), false);
  assert.equal(await f.library.clear(f.context), 1);
  one(); one(); assert.equal(await f.library.remove(f.context, first.expectedSha256), false);
  two(); assert.equal(await f.library.remove(f.context, first.expectedSha256), true);
  assert.equal((await f.library.list(f.context)).length, 0);
  assert.equal(await f.library.remove(f.context, first.expectedSha256), false);
});

test('queued listing and deletion cannot observe an unsealed copy or strand an installed package', async t => {
  const f = fixture(t), job = f.job(); f.copyGate = deferred();
  const keeping = f.library.keep(f.context, job); await tick();
  let listed = false; const listing = f.library.list(f.context).then(rows => { listed = true; return rows; });
  const deleting = f.library.remove(f.context, job.expectedSha256);
  await tick(); assert.equal(listed, false);
  f.copyGate.resolve(); await keeping; assert.equal((await listing).length, 1);
  assert.equal(await deleting, true); assert.ok(fs.existsSync(job.cachePath));
});

test('explicit clear cleans interrupted library files while preserving untracked user files', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const directory = await f.library.directory(f.context), orphan = 'f'.repeat(64);
  fs.writeFileSync(directory + '/' + orphan + '.zip.part', 'partial');
  fs.writeFileSync(directory + '/user-file.hap', 'user');
  assert.equal(await f.library.clear(f.context), 1);
  assert.deepEqual(fs.readdirSync(directory), ['user-file.hap']);
});

test('settings cache size and cleanup exclude original download files and their private receipts', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context);
  const { SettingsCache } = loadEts('data/SettingsCache', {
    './DeviceArtwork': { DeviceArtwork: { size: async () => 0, clear: async () => {} } },
    '@kit.CoreFileKit': { fileIo: f.io }, './CatalogCache': { CatalogCache: { size: async () => 123, clear: async () => {} } },
    '../jobs/DownloadIconCache': { DownloadIconCache: { size: async () => 0, clear: async () => {} } },
    '../jobs/JobStore': { JobStore: { open: async () => ({
      pruneCompleted: async () => {}, pruneSupersededFailures: async () => {}, cleanupOrphanedPackages: async () => {}
    }) } }
  });
  const workingBytes = fs.readdirSync(f.work).reduce((sum, name) => sum + fs.statSync(f.work + '/' + name).size, 0);
  assert.equal(await SettingsCache.size(f.context), workingBytes + 123);
  await SettingsCache.clean(f.context);
  assert.ok(fs.existsSync(row.path)); assert.equal((await f.library.list(f.context)).length, 1);
});

test('completed job pruning migrates original bytes before deleting signing workspaces and preserves update receipts', async t => {
  const f = fixture(t), job = f.job('source.app.zip / app.app'), h = f.store();
  job.packageSourceSha256 = 'c'.repeat(64); job.editedSourceSha256 = 'd'.repeat(64);
  h.rows.push(job); const cachePath = job.cachePath, signedPath = job.signedPath;
  const bytes = fs.readFileSync(cachePath); await h.store.pruneCompleted(f.context);
  const [row] = await f.library.list(f.context);
  assert.deepEqual(fs.readFileSync(row.path), bytes); assert.equal(row.name, 'source.app.zip');
  assert.equal(fs.existsSync(cachePath), false); assert.equal(fs.existsSync(signedPath), false);
  assert.equal(job.cachePath, ''); assert.equal(job.signedPath, ''); assert.equal(h.receipts.length, 0);
  assert.equal(job.packageSourceSha256, 'c'.repeat(64)); assert.equal(job.editedSourceSha256, 'd'.repeat(64));
  assert.equal(job.versionCode, 123); assert.equal(job.stage, InstallStage.INSTALLED);
  await h.store.pruneCompleted(f.context); assert.equal((await f.load().list(f.context)).length, 1);
});

test('an interrupted archival leaves job references and original bytes available for retry', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job);
  f.failMetadata = true; await h.store.pruneCompleted(f.context);
  assert.ok(fs.existsSync(job.cachePath)); assert.ok(fs.existsSync(job.signedPath));
  assert.equal(h.saved.length, 0); assert.equal(h.receipts.length, 0);
  f.failMetadata = false; await h.store.pruneCompleted(f.context);
  assert.equal(job.cachePath, ''); assert.equal((await f.library.list(f.context)).length, 1);
});

test('deleting an archive during interrupted pruning cannot resurrect it on the next startup', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job);
  f.failUpdate = true;
  await assert.rejects(h.store.pruneCompleted(f.context), /journal write/);
  // The durable database still contains the old references after a failed save.
  job.cachePath = h.receipts[0].cachePath; job.signedPath = h.receipts[0].signedPath;
  assert.equal(await f.library.remove(f.context, job.expectedSha256), true);
  f.failUpdate = false; await h.store.pruneCompleted(f.context);
  assert.equal((await f.load().list(f.context)).length, 0); assert.equal(job.cachePath, '');
});

test('pruning waits for package readers and work resumed while archival or journal writes are pending', async t => {
  for (const mode of ['reader', 'resumed', 'journal']) {
    const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job);
    if (mode === 'journal') f.journalHook = () => { h.running.add(job.id); };
    else f.copyGate = deferred();
    const cache = job.cachePath, signed = job.signedPath;
    const pruning = h.store.pruneCompleted(f.context); await tick();
    let release;
    if (mode === 'reader') release = h.JobStore.reservePackage(cache);
    if (mode === 'resumed') h.running.add(job.id);
    if (f.copyGate) f.copyGate.resolve();
    await pruning; assert.equal(h.saved.length, 0); assert.equal(job.cachePath, cache);
    assert.ok(fs.existsSync(cache)); assert.ok(fs.existsSync(signed));
    if (release) release(); h.running.clear(); f.journalHook = undefined;
    await h.store.pruneCompleted(f.context);
    assert.equal(job.cachePath, ''); assert.equal((await f.library.list(f.context)).length, 1);
  }
});

test('a same-ID task replaced during archival is not overwritten even without a live UI running flag', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job); f.copyGate = deferred();
  const pruning = h.store.pruneCompleted(f.context); await tick();
  const replacement = f.job('new-version.app'); replacement.id = job.id;
  replacement.stage = InstallStage.DOWNLOADING; replacement.updatedAt = job.updatedAt + 1;
  h.rows[0] = replacement; const before = JSON.stringify(replacement);
  f.copyGate.resolve(); await pruning;
  assert.equal(JSON.stringify(h.rows[0]), before); assert.equal(h.saved.length, 0);
  assert.ok(fs.existsSync(replacement.cachePath)); assert.ok(fs.existsSync(replacement.signedPath));
});

test('a retry changed at the final database boundary cannot be replaced by completed cleanup', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job);
  f.updateHook = () => { job.stage = InstallStage.WAITING_DEVICE; job.updatedAt++; };
  const cache = job.cachePath; await h.store.pruneCompleted(f.context);
  assert.equal(job.stage, InstallStage.WAITING_DEVICE); assert.equal(job.cachePath, cache);
  assert.equal(h.saved.length, 0); assert.ok(fs.existsSync(cache));
});

test('cancellation during completed journaling cannot recreate the removed installation row', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job);
  f.journalHook = () => { f.cancelled = true; h.rows.splice(0); };
  await h.store.pruneCompleted(f.context);
  assert.equal(h.rows.length, 0); assert.equal(h.saved.length, 0);
  assert.equal((await f.library.list(f.context)).length, 1, 'already retained original remains user-owned');
});

test('a different same-ID cleanup receipt retains its writer and is never replaced by old completed pruning', async t => {
  const f = fixture(t), job = f.job(), future = f.job('future.zip'), h = f.store(); h.rows.push(job);
  future.id = job.id; future.transferTaskId = 'live-transfer'; h.receipts.push({ ...future });
  h.store.stopTransfer = async () => false;
  const receipt = JSON.stringify(h.receipts[0]); await h.store.pruneCompleted(f.context);
  assert.equal(JSON.stringify(h.receipts[0]), receipt); assert.equal(h.saved.length, 0);
  assert.ok(fs.existsSync(future.cachePath)); assert.ok(fs.existsSync(job.cachePath));
});

test('old private HAP, APP and ZIP originals migrate verified bytes and keep their original metadata', async t => {
  const f = fixture(t), rows = ['旧应用.hap', '整包.app', '压缩包.zip'].map(name => f.seedLegacy(name));
  const key = f.context.filesDir + '/key.pem', profile = f.context.filesDir + '/profile.p7b';
  fs.writeFileSync(key, 'private key'); fs.writeFileSync(profile, 'profile');
  f.unlinkHook = p => {
    const old = rows.find(row => row.path === p); if (!old) return;
    const committed = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + old.id + '.json', 'utf8'));
    assert.equal(path.dirname(committed.path), f.public, 'commit the public receipt before deleting old bytes');
    assert.equal(digest(fs.readFileSync(committed.path)), old.id);
  };
  const migrated = await f.library.list(f.context); assert.equal(migrated.length, 3);
  for (const old of rows) {
    const row = migrated.find(value => value.id === old.id);
    assert.equal(path.dirname(row.path), f.public); assert.equal(fs.existsSync(old.path), false);
    assert.deepEqual({ ...row, path: old.path }, { ...old, deletedAt: 0 });
  }
  assert.equal(f.copies, 3); await f.load().list(f.context); assert.equal(f.copies, 3, 'migration is restart-idempotent');
  assert.equal(fs.readFileSync(key, 'utf8'), 'private key'); assert.equal(fs.readFileSync(profile, 'utf8'), 'profile');
});

test('getLocation honors the real authorized Chinese subdirectory without hashing old downloads on installation start', async t => {
  const f = fixture(t), old = f.seedLegacy();
  f.public += '-fallback'; f.publicDisplay = '下载/com.example.installer/轻启·安装器';
  const location = await f.library.getLocation(f.context);
  assert.equal(location.path, f.public); assert.equal(location.displayPath, f.publicDisplay);
  assert.equal(location.uri, 'file://docs' + f.public); assert.equal(f.copies, 0);
  assert.ok(fs.existsSync(old.path), 'location initialization does not delay a new installation with full migration');
  assert.equal(path.dirname((await f.library.list(f.context))[0].path), f.public);
});

test('failed public access preserves private originals and their independent management while new archival waits', async t => {
  const f = fixture(t), old = f.seedLegacy(), job = f.job(); f.failPublic = true;
  await assert.rejects(f.library.getLocation(f.context), /access denied/);
  assert.equal((await f.library.list(f.context))[0].path, old.path);
  assert.equal((await f.library.verify(f.context, old.id)).path, old.path);
  await assert.rejects(f.library.keep(f.context, job), /access denied/);
  assert.ok(fs.existsSync(job.cachePath)); assert.ok(fs.existsSync(old.path));
  assert.equal(await f.library.remove(f.context, old.id), true);
  assert.equal((await f.library.list(f.context)).length, 0);
  const second = f.seedLegacy('另外.app'); assert.equal(await f.library.clear(f.context), 1);
  assert.equal(fs.existsSync(second.path), false);
});

test('unavailable public access never tombstones or clears a previously retained public package', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job);
  const [row] = await f.library.list(f.context); f.seedLegacy(); f.failPublic = true;
  assert.equal(await f.library.remove(f.context, row.id), false);
  assert.equal(await f.library.clear(f.context), 1, 'only the available legacy original is removed');
  assert.ok(fs.existsSync(row.path));
  assert.equal(JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + row.id + '.json', 'utf8')).deletedAt, undefined);
  f.failPublic = false; assert.equal((await f.library.list(f.context)).length, 1);
});

for (const mode of ['corrupt-copy', 'receipt-write', 'old-delete']) test('migration recovers safely after ' + mode + ' interruption', async t => {
  const f = fixture(t), old = f.seedLegacy();
  if (mode === 'corrupt-copy') f.badCopy = true;
  if (mode === 'receipt-write') f.failMetadata = true;
  if (mode === 'old-delete') f.failUnlink = old.path;
  const rows = await f.library.list(f.context); assert.equal(rows.length, 1); assert.ok(fs.existsSync(old.path));
  if (mode !== 'old-delete') assert.equal(rows[0].path, old.path, 'failed copy/receipt preserves the old authoritative path');
  else assert.equal(path.dirname(rows[0].path), f.public, 'post-commit cleanup failure leaves a valid public record');
  f.badCopy = false; f.failMetadata = false; f.failUnlink = undefined;
  const [recovered] = await f.load().list(f.context);
  assert.equal(path.dirname(recovered.path), f.public); assert.equal(digest(fs.readFileSync(recovered.path)), old.id);
  assert.equal(fs.existsSync(old.path), false); assert.equal(recovered.createdAt, old.createdAt);
  assert.equal(fs.readdirSync(f.public).filter(name => !name.endsWith('.part')).length, 1);
  if (mode !== 'corrupt-copy') assert.equal(f.copies, 1, 'verified copied bytes are reused after an interrupted receipt/cleanup');
});

test('one damaged receipt cannot prevent unrelated originals from being migrated', async t => {
  const f = fixture(t), broken = f.seedLegacy('broken.app'), good = f.seedLegacy('good.zip');
  f.failReceipt = f.context.filesDir + '/download-receipts/' + broken.id + '.json';
  const rows = await f.library.list(f.context); assert.equal(rows.length, 2);
  assert.equal(rows.find(row => row.id === broken.id).path, broken.path);
  assert.equal(path.dirname(rows.find(row => row.id === good.id).path), f.public);
  assert.ok(fs.existsSync(broken.path)); assert.equal(fs.existsSync(good.path), false);
});

test('pinned legacy reads finish before migration and repeated bytes reuse the public target', async t => {
  const f = fixture(t), old = f.seedLegacy(), release = f.library.reserve(f.context, old.id);
  assert.equal((await f.library.list(f.context))[0].path, old.path); assert.equal(f.copies, 0);
  release(); const [row] = await f.library.list(f.context); assert.equal(f.copies, 1);
  fs.writeFileSync(old.path, fs.readFileSync(row.path)); // Interrupted post-commit cleanup from a previous process.
  const restarted = f.load(); assert.equal((await restarted.list(f.context))[0].path, row.path);
  assert.equal(fs.existsSync(old.path), false); assert.equal(f.copies, 1);
});

test('an external public deletion cannot be restored by leftover private bytes after a migration crash', async t => {
  const f = fixture(t), old = f.seedLegacy(); f.failUnlink = old.path;
  const [row] = await f.library.list(f.context); fs.unlinkSync(row.path); f.failUnlink = undefined;
  assert.equal((await f.load().list(f.context)).length, 0);
  assert.ok(fs.existsSync(old.path), 'leftover private bytes never override the user deletion');
  const receipt = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + row.id + '.json', 'utf8'));
  assert.ok(receipt.deletedAt > 0);
  const job = f.job(old.name, fs.readFileSync(old.path)); await f.library.keep(f.context, job);
  assert.equal((await f.library.list(f.context)).length, 0);
  job.stageHistory[0].at = receipt.deletedAt + 1; await f.library.keep(f.context, job);
  assert.equal((await f.library.list(f.context)).length, 1, 'a new real installation may retain the bytes again');
});

test('damaged legacy bytes, symlinks and forged receipt paths never migrate unrelated files', async t => {
  const f = fixture(t), corrupt = f.seedLegacy('corrupt.hap'), linked = f.seedLegacy('link.app'), forged = f.seedLegacy('forged.zip');
  fs.writeFileSync(corrupt.path, 'corrupted');
  const secret = f.context.filesDir + '/identity.pem'; fs.writeFileSync(secret, 'private-key-content');
  fs.unlinkSync(linked.path); fs.symlinkSync(secret, linked.path);
  fs.writeFileSync(f.context.filesDir + '/download-receipts/' + forged.id + '.json', JSON.stringify({ ...forged, path: secret }));
  const rows = await f.library.list(f.context); assert.equal(f.copies, 0); assert.equal(rows.length, 1);
  assert.equal(rows[0].path, corrupt.path); await assert.rejects(f.library.verify(f.context, corrupt.id), /已变化/);
  assert.equal(fs.readFileSync(secret, 'utf8'), 'private-key-content'); assert.equal(fs.existsSync(corrupt.path), true);
  assert.deepEqual(fs.readdirSync(f.public), []);
});

test('public partial-file symlinks cannot overwrite an unrelated file during keep or migration', async t => {
  for (const mode of ['keep', 'migration']) {
    const f = fixture(t), name = 'same.hap', job = f.job(name), old = f.seedLegacy(name, fs.readFileSync(job.cachePath));
    const directory = await f.library.directory(f.context), outside = f.context.filesDir + '/identity.pem';
    fs.writeFileSync(outside, 'unchanged secret'); fs.symlinkSync(outside, directory + '/same-' + job.expectedSha256 + '.hap.part');
    if (mode === 'keep') await assert.rejects(f.library.keep(f.context, job), /ELOOP/);
    else assert.equal((await f.library.list(f.context))[0].path, old.path);
    assert.equal(fs.readFileSync(outside, 'utf8'), 'unchanged secret'); assert.ok(fs.existsSync(old.path));
    assert.ok(fs.existsSync(job.cachePath));
  }
});

test('identical payloads with different release asset names keep a readable valid existing archive', async t => {
  const f = fixture(t), first = f.job('old-name.hap'), next = f.job('new-name.hap', fs.readFileSync(first.cachePath));
  await f.library.keep(f.context, first); await f.library.keep(f.context, next);
  const rows = await f.library.list(f.context); assert.equal(rows.length, 1); assert.equal(f.copies, 1);
  assert.equal(rows[0].name, first.assetName); assert.equal((await f.library.verify(f.context, rows[0].id)).path, rows[0].path);
});

test('a root folder becoming read-only migrates its readable originals without hiding them if old deletion fails', async t => {
  const f = fixture(t), job = f.job('root.hap'); await f.library.keep(f.context, job);
  const [old] = await f.library.list(f.context), root = f.public;
  f.public = path.dirname(root) + '/com.example.installer/轻启·安装器';
  f.publicDisplay = '下载/com.example.installer/轻启·安装器'; f.knownPublicPaths = [root, f.public];
  f.failUnlink = old.path;
  const location = await f.library.getLocation(f.context); assert.equal(location.path, f.public);
  const [row] = await f.load().list(f.context); assert.equal(path.dirname(row.path), f.public);
  assert.ok(fs.existsSync(old.path)); assert.equal((await f.library.verify(f.context, old.id)).path, row.path);
  const another = f.job('current.app'); await f.library.keep(f.context, another);
  const rows = await f.library.list(f.context); assert.equal(rows.length, 2);
  assert.equal(path.dirname(rows.find(value => value.id === another.expectedSha256).path), f.public);
  f.failUnlink = undefined; assert.equal(await f.library.clear(f.context), 2); assert.equal(fs.existsSync(old.path), false);
});

test('extra system-derived candidates reject symlink folders and never authorize arbitrary receipt paths', async t => {
  const f = fixture(t), job = f.job(); await f.library.keep(f.context, job); const [old] = await f.library.list(f.context);
  const real = f.public; fs.renameSync(real, real + '-real'); fs.symlinkSync(real + '-real', real);
  f.public = path.dirname(real) + '/com.example.installer/轻启·安装器'; f.knownPublicPaths = [real, f.public];
  assert.equal((await f.library.list(f.context)).length, 0); await assert.rejects(f.library.verify(f.context, old.id));
  assert.equal(await f.library.remove(f.context, old.id), false); assert.ok(fs.existsSync(real + '-real/' + path.basename(old.path)));
  const secret = f.context.filesDir + '/identity.pem'; fs.writeFileSync(secret, 'private key');
  fs.writeFileSync(f.context.filesDir + '/download-receipts/' + old.id + '.json', JSON.stringify({ ...old, path: secret }));
  assert.equal((await f.library.list(f.context)).length, 0); assert.equal(await f.library.remove(f.context, old.id), false);
  assert.equal(fs.readFileSync(secret, 'utf8'), 'private key');
});

test('a reader acquired during migration keeps its private source until it releases while deletes remain serialized', async t => {
  const f = fixture(t), old = f.seedLegacy(); f.copyStarted = deferred(); f.copyGate = deferred();
  const listing = f.library.list(f.context); await f.copyStarted.promise;
  const release = f.library.reserve(f.context, old.id);
  let deleted = false; const deleting = f.library.remove(f.context, old.id).then(value => { deleted = true; return value; });
  await tick(); assert.equal(deleted, false, 'delete waits for the migration transaction');
  f.copyGate.resolve(); const [row] = await listing;
  assert.equal(path.dirname(row.path), f.public); assert.ok(fs.existsSync(old.path));
  assert.equal(await deleting, false, 'a newly pinned reader protects both copies');
  release(); await f.library.list(f.context); assert.equal(fs.existsSync(old.path), false);
  assert.equal(await f.library.remove(f.context, old.id), true);
  assert.equal((await f.load().list(f.context)).length, 0);
});

test('explicit deletion and clear never copy old packages merely to delete them immediately', async t => {
  const f = fixture(t), one = f.seedLegacy('one.hap'), two = f.seedLegacy('two.app');
  assert.equal(await f.library.remove(f.context, one.id), true);
  assert.equal(await f.library.clear(f.context), 1); assert.equal(f.copies, 0);
  assert.equal(fs.existsSync(one.path), false); assert.equal(fs.existsSync(two.path), false);
  assert.equal((await f.library.list(f.context)).length, 0);
});

test('successful-install auto cleanup removes only its own raw download and preserves evidence and signing materials', async t => {
  const f = fixture(t), job = f.job('cleanup.app.zip / package.app'), other = f.job('history.hap'), h = f.store();
  f.autoClean = true; h.rows.push(job); await f.library.keep(f.context, job); await f.library.keep(f.context, other);
  const [own] = (await f.library.list(f.context)).filter(row => row.id === job.expectedSha256);
  const source = job.cachePath, signed = job.signedPath;
  const profile = f.context.filesDir + '/profiles/app.p7b', key = f.context.filesDir + '/key.pem';
  fs.mkdirSync(path.dirname(profile), { recursive: true }); fs.writeFileSync(profile, 'authorization'); fs.writeFileSync(key, 'key');
  job.profilePath = profile; job.packageSourceSha256 = 'c'.repeat(64); job.authorizationExpiresAt = 1900000000;
  await h.store.pruneCompleted(f.context);
  assert.equal(fs.existsSync(source), false); assert.equal(fs.existsSync(signed), false); assert.equal(fs.existsSync(own.path), false);
  assert.equal(job.cachePath, ''); assert.equal(job.stage, InstallStage.INSTALLED);
  assert.equal(job.packageSourceSha256, 'c'.repeat(64)); assert.equal(job.authorizationExpiresAt, 1900000000);
  assert.ok(fs.existsSync(profile)); assert.ok(fs.existsSync(key));
  assert.deepEqual(Array.from(await f.library.list(f.context), row => row.id), [other.expectedSha256]);
  assert.ok(JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + own.id + '.json', 'utf8')).deletedAt > 0);
});

test('enabled auto cleanup skips archival of a new original and cannot revive it after interrupted SQLite cleanup', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); f.autoClean = true; h.rows.push(job); f.failUpdate = true;
  const source = job.cachePath; await assert.rejects(h.store.pruneCompleted(f.context), /journal write/);
  assert.ok(fs.existsSync(source)); assert.equal(f.copies, 0); assert.equal((await f.library.list(f.context)).length, 0);
  f.autoClean = false; f.failUpdate = false; await h.store.pruneCompleted(f.context);
  assert.equal(fs.existsSync(source), false); assert.equal((await f.load().list(f.context)).length, 0, 'the old completed row cannot recreate intentionally cleared bytes');
  const deleted = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + job.expectedSha256 + '.json', 'utf8')).deletedAt;
  const later = f.job(); later.stageHistory[0].at = deleted + 1; later.updatedAt = deleted + 2; h.rows[0] = later;
  await h.store.pruneCompleted(f.context); assert.equal((await f.library.list(f.context)).length, 1, 'disabling cleanup retains a genuinely later successful download');
});

test('auto cleanup waits for a same-digest sharing reader and retries after it closes', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); f.autoClean = true; h.rows.push(job);
  await f.library.keep(f.context, job); const [row] = await f.library.list(f.context), source = job.cachePath;
  const release = f.library.reserve(f.context, row.id); await h.store.pruneCompleted(f.context);
  assert.equal(job.cachePath, source); assert.equal(h.saved.length, 0); assert.ok(fs.existsSync(source)); assert.ok(fs.existsSync(row.path));
  assert.equal(JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + row.id + '.json', 'utf8')).deletedAt, undefined);
  release(); await h.store.pruneCompleted(f.context);
  assert.equal(job.cachePath, ''); assert.equal(fs.existsSync(row.path), false); assert.equal(fs.existsSync(source), false);
});

test('turning on cleanup never applies it to earlier successful or already-pruned downloads', async t => {
  const f = fixture(t), old = f.job('old.hap'), pruned = f.job('pruned.app'), h = f.store();
  await f.library.keep(f.context, pruned); pruned.cachePath = ''; pruned.signedPath = '';
  h.rows.push(old, pruned); f.autoClean = true; f.enabledSince = 2500;
  await h.store.pruneCompleted(f.context);
  assert.equal((await f.library.list(f.context)).length, 2); assert.equal(old.cachePath, '');
  assert.equal(fs.readdirSync(f.context.filesDir + '/download-receipts').filter(name => name.endsWith('.json')).length, 2);
});

test('new installation of an old retained digest cleans its workspace and preserves the historical public original', async t => {
  const f = fixture(t), job = f.job(), h = f.store(); job.stageHistory[0].at = 500;
  await f.library.keep(f.context, job); const [row] = await f.library.list(f.context);
  const receiptPath = f.context.filesDir + '/download-receipts/' + row.id + '.json', before = fs.readFileSync(receiptPath, 'utf8');
  job.stageHistory[0].at = 2000; job.updatedAt = 3000; h.rows.push(job); f.autoClean = true; f.enabledSince = 1000;
  await h.store.pruneCompleted(f.context);
  assert.equal(job.cachePath, ''); assert.ok(fs.existsSync(row.path)); assert.equal(fs.readFileSync(receiptPath, 'utf8'), before);
  assert.equal((await f.library.list(f.context)).length, 1); assert.equal(f.copies, 1);
});

for (const mode of ['preferences-failure', 'missing-enable-time', 'archive-delete-failure']) test('auto cleanup conservatively retains a verified original after ' + mode, async t => {
  const f = fixture(t), job = f.job(), h = f.store(); f.autoClean = true; h.rows.push(job);
  if (mode === 'preferences-failure') f.failPreference = true;
  if (mode === 'missing-enable-time') f.enabledSince = 0;
  if (mode === 'archive-delete-failure') {
    await f.library.keep(f.context, job); const [row] = await f.library.list(f.context); f.failUnlink = row.path;
  }
  const source = job.cachePath; await h.store.pruneCompleted(f.context);
  assert.equal(job.cachePath, ''); assert.equal(fs.existsSync(source), false);
  const [row] = await f.library.list(f.context); assert.ok(row); assert.equal(digest(fs.readFileSync(row.path)), job.expectedSha256);
});

test('unavailable public access and a changed original cannot discard the only local source', async t => {
  for (const mode of ['public-unavailable', 'source-changed']) {
    const f = fixture(t), job = f.job(), h = f.store(); f.autoClean = true; h.rows.push(job);
    if (mode === 'public-unavailable') f.failPublic = true;
    else fs.writeFileSync(job.cachePath, 'corrupt source');
    const source = job.cachePath; await h.store.pruneCompleted(f.context);
    assert.equal(job.cachePath, source); assert.ok(fs.existsSync(source)); assert.ok(fs.existsSync(job.signedPath));
    assert.equal(h.saved.length, 0); assert.equal(h.receipts.length, 0);
  }
});

for (const mode of ['resumed', 'running', 'cancelled', 'source-reader']) test('auto deletion rechecks the completed SQLite snapshot after hashing: ' + mode, async t => {
  const f = fixture(t), job = f.job(), h = f.store(); h.rows.push(job); f.autoClean = true;
  await f.library.keep(f.context, job); const [row] = await f.library.list(f.context); const source = job.cachePath;
  let release;
  f.hashHook = p => {
    if (p !== source) return; f.hashHook = undefined;
    if (mode === 'resumed') h.rows[0] = { ...job, stage: InstallStage.DOWNLOADING, updatedAt: job.updatedAt + 1 };
    if (mode === 'running') h.running.add(job.id);
    if (mode === 'cancelled') f.cancelled = true;
    if (mode === 'source-reader') release = h.JobStore.reservePackage(source);
  };
  await h.store.pruneCompleted(f.context);
  assert.equal(h.rows[0].cachePath, source); assert.ok(fs.existsSync(source)); assert.ok(fs.existsSync(row.path));
  assert.equal(h.saved.length, 0); assert.equal(h.receipts.length, 0); if (release) release();
});

test('incomplete or failed tasks are unaffected by successful-install auto cleanup', async t => {
  const f = fixture(t), h = f.store(); f.autoClean = true;
  for (const stage of [InstallStage.DOWNLOADING, InstallStage.RETRYABLE_ERROR, InstallStage.WAITING_DEVICE]) {
    const job = f.job(stage + '.hap'); job.stage = stage; h.rows.push(job);
  }
  await h.store.pruneCompleted(f.context);
  for (const job of h.rows) { assert.ok(fs.existsSync(job.cachePath)); assert.ok(fs.existsSync(job.signedPath)); }
  assert.equal(f.copies, 0); assert.equal(h.receipts.length, 0); assert.equal(h.saved.length, 0);
});

test('duplicate Chinese public folders migrate whole original packages to the real app download child', async t => {
  const f = fixture(t), outer = f.public; f.public = outer + '/轻启·安装器';
  const rows = [];
  for (const name of ['软件.hap', '整包.app', '打包.zip']) {
    const job = f.job(name); await f.library.keep(f.context, job);
    rows.push((await f.library.list(f.context)).find(row => row.id === job.expectedSha256));
  }
  const oldFolder = f.public, userFile = oldFolder + '/我自己的安装包.hap'; fs.writeFileSync(userFile, 'user file');
  const orphan = oldFolder + '/没有收据-' + 'f'.repeat(64) + '.hap'; fs.writeFileSync(orphan, 'untracked');
  const profile = oldFolder + '/profile.p7b'; fs.writeFileSync(profile, 'authorization');
  f.public = outer + '/download'; f.knownPublicPaths = [f.public, outer, oldFolder]; f.publicDisplay = '下载/轻启·安装器/download';
  f.unlinkHook = p => {
    const old = rows.find(row => row.path === p); if (!old) return;
    const receipt = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + old.id + '.json', 'utf8'));
    assert.equal(path.dirname(receipt.path), f.public); assert.equal(digest(fs.readFileSync(receipt.path)), old.id);
  };
  const migrated = await f.library.list(f.context); assert.equal(migrated.length, 3);
  for (const old of rows) {
    const row = migrated.find(value => value.id === old.id);
    assert.equal(path.dirname(row.path), f.public); assert.equal(fs.existsSync(old.path), false);
    assert.equal(row.createdAt, old.createdAt); assert.equal(row.name, old.name); assert.equal(row.version, old.version);
    assert.equal(digest(fs.readFileSync(row.path)), old.id);
  }
  assert.equal(f.copies, 6); await f.load().list(f.context); assert.equal(f.copies, 6);
  assert.equal(fs.readFileSync(userFile, 'utf8'), 'user file'); assert.ok(fs.existsSync(orphan)); assert.ok(fs.existsSync(profile));
});

for (const mode of ['corrupt-copy', 'receipt-write', 'old-delete']) test('duplicate public-folder migration retries after ' + mode + ' without losing its original', async t => {
  const f = fixture(t), outer = f.public; f.public = outer + '/轻启·安装器';
  const job = f.job(); await f.library.keep(f.context, job); const [old] = await f.library.list(f.context), previous = f.public;
  f.public = outer + '/download'; f.knownPublicPaths = [f.public, outer, previous];
  if (mode === 'corrupt-copy') f.badCopy = true;
  if (mode === 'receipt-write') f.failMetadata = true;
  if (mode === 'old-delete') f.failUnlink = old.path;
  const [pending] = await f.library.list(f.context); assert.ok(fs.existsSync(old.path));
  assert.equal(path.dirname(pending.path), mode === 'old-delete' ? f.public : previous);
  f.badCopy = false; f.failMetadata = false; f.failUnlink = undefined;
  const [recovered] = await f.load().list(f.context);
  assert.equal(path.dirname(recovered.path), f.public); assert.equal(fs.existsSync(old.path), false);
  assert.equal(digest(fs.readFileSync(recovered.path)), old.id);
  assert.equal(fs.readdirSync(f.public).filter(name => !name.endsWith('.part')).length, 1);
  if (mode !== 'corrupt-copy') assert.equal(f.copies, 2, 'a verified copy is not duplicated after an interrupted commit/cleanup');
});

test('sharing a duplicate-folder original delays migration and external deletion after commit never resurrects the old copy', async t => {
  const f = fixture(t), outer = f.public; f.public = outer + '/轻启·安装器';
  const job = f.job(); await f.library.keep(f.context, job); const [old] = await f.library.list(f.context), previous = f.public;
  f.public = outer + '/download'; f.knownPublicPaths = [f.public, outer, previous];
  const release = f.library.reserve(f.context, old.id);
  assert.equal((await f.library.list(f.context))[0].path, old.path); assert.equal(f.copies, 1);
  release(); f.failUnlink = old.path; const [row] = await f.library.list(f.context);
  assert.equal(path.dirname(row.path), f.public); assert.ok(fs.existsSync(old.path));
  fs.unlinkSync(row.path); f.failUnlink = undefined; assert.equal((await f.load().list(f.context)).length, 0);
  assert.ok(fs.existsSync(old.path)); assert.equal(f.copies, 2, 'old surviving bytes do not override the public deletion');
});

test('listing old public folders without owned originals does not rehash unrelated current downloads', async t => {
  const f = fixture(t), oldFolder = f.public, job = f.job();
  f.public = oldFolder + '/download'; f.knownPublicPaths = [f.public, oldFolder, oldFolder + '/轻启·安装器'];
  await f.library.keep(f.context, job);
  fs.mkdirSync(oldFolder + '/轻启·安装器');
  fs.writeFileSync(oldFolder + '/user.app', 'user'); fs.writeFileSync(oldFolder + '/轻启·安装器/untracked.zip', 'user');
  f.hashReads.length = 0; await f.library.list(f.context); await f.load().list(f.context);
  assert.equal(f.hashReads.length, 0, 'only IDs present in an old owned archive require migration hashing');
  assert.equal(f.copies, 1);
});

test('deletion in an old public folder bypasses migration and keep seals a new location before deleting the old copy', async t => {
  for (const mode of ['remove', 'clear', 'keep']) {
    const f = fixture(t), outer = f.public; f.public = outer + '/轻启·安装器';
    const job = f.job(); await f.library.keep(f.context, job); const [old] = await f.library.list(f.context), previous = f.public;
    f.public = outer + '/download'; f.knownPublicPaths = [f.public, outer, previous];
    if (mode === 'remove') assert.equal(await f.library.remove(f.context, old.id), true);
    else if (mode === 'clear') assert.equal(await f.library.clear(f.context), 1);
    else {
      f.unlinkHook = p => {
        if (p !== old.path) return;
        const receipt = JSON.parse(fs.readFileSync(f.context.filesDir + '/download-receipts/' + old.id + '.json', 'utf8'));
        assert.equal(path.dirname(receipt.path), f.public); assert.equal(digest(fs.readFileSync(receipt.path)), old.id);
      };
      await f.library.keep(f.context, job); assert.equal(path.dirname((await f.library.list(f.context))[0].path), f.public);
    }
    assert.equal(fs.existsSync(old.path), false); assert.equal(f.copies, mode === 'keep' ? 2 : 1);
  }
});

test('real PublicDownloadDirectory and DownloadLibrary retain an APP under the Chinese system grant despite denied parent writes', async t => {
  const f = fixture(t, { realPublicHelper: true }), job = f.job('真实包.app');
  assert.equal(fs.existsSync(f.public), false, 'only the operating-system grant exists before the actual helper runs');
  await f.library.keep(f.context, job); const [row] = await f.library.list(f.context);
  assert.ok(row); assert.equal(path.dirname(row.path), f.grantedApp + '/download');
  assert.equal(row.name, '真实包.app'); assert.equal(digest(fs.readFileSync(row.path)), job.expectedSha256);
  const location = await f.library.getLocation(f.context);
  assert.equal(location.displayPath, '下载/轻启·安装器/download');
  assert.equal(location.uri, 'file://docs' + location.path.split('/').map(encodeURIComponent).join('/'));
  assert.ok(location.uri.endsWith('/download'));
  assert.deepEqual(f.publicCreates, [f.grantedApp + '/download']); assert.equal(f.saves, 1);
  assert.equal(f.publicAccess.some(([p]) => p === f.publicRoot), false, 'no parent read/write grant is needed');
  assert.equal(fs.existsSync(f.grantedApp + '/轻启·安装器'), false, 'the helper and library never duplicate the outer Chinese directory');
});

test('reinstall restores identical retained HAP, APP and archive bytes into a new private workspace', async t => {
  const f=fixture(t);
  for(const name of ['app.hap','app.app','app.zip / main.hap','app.app.zip / whole.app']) {
    const old=f.job(name);await f.library.keep(f.context,old);
    const destination=f.work+'/reinstall-'+old.expectedSha256+'.hap';
    const job={...old,expectedSha256:'',catalogSha256:old.expectedSha256,cachePath:destination,signedPath:destination+'.signed'};
    assert.equal(await f.load().restore(f.context,job),old.expectedSha256);
    assert.deepEqual(fs.readFileSync(destination),fs.readFileSync(old.cachePath));
    assert.equal((await f.library.list(f.context)).some(row=>row.id===old.expectedSha256),true);
  }
});

test('retained package reuse rejects tampering, deleted files and same-version changed bytes', async t => {
  const f=fixture(t),old=f.job();await f.library.keep(f.context,old);
  const [row]=await f.library.list(f.context);
  const job={...old,expectedSha256:'',catalogSha256:'f'.repeat(64),cachePath:f.work+'/new.hap',signedPath:f.work+'/new.signed.hap'};
  assert.equal(await f.library.restore(f.context,job),'');
  job.catalogSha256=old.expectedSha256;fs.writeFileSync(row.path,'modified');
  assert.equal(await f.library.restore(f.context,job),'');assert(!fs.existsSync(job.cachePath));
  fs.unlinkSync(row.path);
  assert.equal(await f.library.restore(f.context,job),'');
  assert.equal(await f.library.restore(f.context,{...job,cachePath:row.path}),'', 'no writes outside the private installation workspace');
});
