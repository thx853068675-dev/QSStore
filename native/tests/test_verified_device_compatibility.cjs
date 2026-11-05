const { test } = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const crypto = require('node:crypto');
const fs = require('node:fs'), path = require('node:path');
const { loadEts } = require('./load_ets.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
const jobs = loadEts('jobs/InstallJob');
const planner = loadEts('jobs/RecoveryPlanner', { './InstallJob': jobs });
const display = loadEts('data/DeviceSupportDisplay', { './ReleaseInfo': loadEts('data/ReleaseInfo') });
const archive = loadEts('jobs/PackageArchive', { './PackageInspector': loadEts('jobs/PackageInspector') });
const scheduler = { JobScheduler: { runInstall: async (_id, action) => action() } };
const cancellation = { JobCancellation: { assertActive() {}, isCancelled: () => false } };
const runner = loadEts('jobs/JobRunner', { './InstallJob': jobs, './JobScheduler': scheduler,
  './RecoveryPlanner': planner, './JobCancellation': cancellation });
const digest = text => crypto.createHash('sha256').update(text).digest('hex');

function fixture({ types = ['tablet'], local = false, extension = '.hap', selected = '' } = {}) {
  const f = { current: 'phone', dialogs: [], preparations: 0, profiles: 0, signs: 0, installs: 0,
    parses: [], writes: [], localVersion: 0, files: new Map(), modules: new Map(), extractions: [], cacheChecks: 0 };
  const manifest = deviceTypes => JSON.stringify({ app: { bundleName: 'com.example.app', versionCode: 7 },
    module: { name: 'entry', type: 'entry', mainElement: 'MainAbility', ...(deviceTypes === undefined ? {} : { deviceTypes }) } });
  f.manifest = manifest;
  f.job = Object.assign(new jobs.InstallJob(), { id: 'device-guard', appId: local ? 0 : 42,
    assetName: 'actual' + extension, cachePath: '/private/actual' + extension,
    signedPath: '/private/actual.signed' + extension, sourceUrl: local ? 'local' : 'https://example.com/actual' + extension,
    catalogSourceUrl: local ? '' : 'https://example.com/actual' + extension,
    catalogBundleName: local ? '' : 'com.example.app', catalogVersionCode: local ? 0 : 7,
    bundleName: 'com.example.app', versionCode: 7, reinstallRequired: local,
    profilePath: '/private/profile.p7b', profileSha256: 'profile' });
  f.files.set(f.job.cachePath, manifest(types)); f.files.set(f.job.signedPath, manifest(types));
  if (selected) {
    f.job.sourceUrl += '#qingqi-package=' + encodeURIComponent(selected);
    f.job.catalogSourceUrl = f.job.sourceUrl;
    f.modules.set(selected, manifest(types));
    f.modules.set('B.hap', manifest(types) + ' ');
    f.files.set(f.job.cachePath, 'verified ZIP containing A and B');
  }
  f.job.expectedSha256 = digest(f.files.get(f.job.cachePath));
  const deviceInfo = {}; Object.defineProperty(deviceInfo, 'deviceType', { get: () => f.current });
  const compatibility = loadEts('jobs/InstallDeviceCompatibility', {
    './PackageArchive': archive,
    '@kit.BasicServicesKit': { deviceInfo }, '../data/DeviceSupportDisplay': display,
    '../theme/Palette': loadEts('theme/Palette'), './InstallJob': jobs,
    '@kit.ArkUI': { promptAction: { showDialog: options => new Promise((resolve, reject) =>
      f.dialogs.push({ options, resolve, reject })) } }
  });
  f.compatibility = compatibility.InstallDeviceCompatibility;
  const inspector = loadEts('jobs/PackageInspector', { '../data/DeviceSupportDisplay': display,
    './PackagePresentation': { PackagePresentation: { label: () => '真实应用' } },
    'libhap_core.so': { readModuleJson: source => { f.parses.push(source); return f.files.get(source); }, readPackInfo: () => '' } });
  const io = { accessSync: source => f.files.has(source), statSync: () => ({ size: 512 }) };
  const native = { hasSigningBlock: () => true, signHap: async () => f.signs++, verifyHap: async () => {} };
  const mocks = {
    '@kit.CoreFileKit': { fileIo: io, hash: { hash: async source => source === f.job.profilePath ? 'profile' : digest(f.files.get(source)) } },
    './InstallJob': jobs, './JobRunner': runner, './JobCancellation': cancellation,
    './PackageInspector': inspector, './InstallDeviceCompatibility': compatibility,
    './PackageArchive': { PackageArchive: { inspect: async source => inspector.inspectPackage(source),
      installablePath: async path => path,
      selectedEntry: archive.PackageArchive.selectedEntry, extension: archive.PackageArchive.extension,
      extractSelected: async (_container, entry, output) => {
        f.extractions.push(entry); f.files.set(output, f.modules.get(entry)); return output;
      }, permissions: async () => [], workingBytes: () => 512, release() {} } },
    './StorageBudget': { StorageBudget: { require: async () => {} } },
    './InstallTaskState': { InstallTaskState: { installProgress() {} } },
    './LocalBundles': { LocalBundles: { liveInstalledVersion: () => f.localVersion,
      isSelfBundle: () => false, isKnown: () => false, installedVersionName: () => '' } },
    './ReleaseUpdate': { ReleaseUpdate: { forJob: () => ({}), available: () => false } },
    './AssetDownload': { AssetDownload: class { async verifiedFileExists(job) {
      f.cacheChecks++; return f.files.has(job.cachePath) && digest(f.files.get(job.cachePath)) === job.expectedSha256;
    } } },
    '../data/SigningIdentity': { SigningIdentityRecovery: {
      ensureForInstall: async () => { f.preparations++; return { certId: '1' }; },
      forJob: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' })
    } },
    '../data/AgcProfile': { AgcProfile: { valid: () => true, effectiveAcls: rows => rows } },
    './InstalledSigningExpiry': { InstalledSigningExpiry: { current: () => undefined } },
    './InstalledAppRegistry': { InstalledAppRegistry: { signingIdentity: () => undefined } },
    'libhap_core.so': native
  };
  const rows = new Map([[f.job.id, f.job]]);
  f.store = { get: async id => rows.get(id), listAll: async () => [...rows.values()],
    save: async job => { f.writes.push(jobs.InstallJob.displayCopy(job)); rows.set(job.id, job); },
    recordFailure: async (job, kind, message) => { job.stage = planner.stageForFailure(kind); job.lastError = message; await f.store.save(job); } };
  const device = { connected: async () => true, udid: async () => 'test-device',
    installedVersion: async () => f.localVersion, installedSigningIdentity: async () => undefined,
    install: async () => { if (f.installError) throw f.installError; f.installs++; f.localVersion = 7; } };
  const { NativeJobRuntime } = loadEts('jobs/NativeJobRuntime', mocks);
  f.createRuntime = (store = f.store, account = { userId: '42' }) => {
    const runtime = new NativeJobRuntime({}, store, account, device);
    runtime.ensureAccountProfile = async () => { f.profiles++; if (f.profileError) throw f.profileError; };
    return runtime;
  };
  f.runtime = f.createRuntime();
  f.run = () => new runner.JobRunner(f.store, f.runtime).run(f.job.id);
  return f;
}

test('multi-device manifest mismatch yields the execution lane to the conflict chain before AGC',async()=>{
 const f=fixture({local:true});f.job.batchId='same-package-many-targets';
 const result=await f.run();
 assert.equal(result.stage,jobs.InstallStage.WAITING_CONFIRMATION);
 assert.equal(result.conflictKind,'compatibility');assert.equal(f.dialogs.length,0);
 const pending=JSON.parse(result.conflictState);assert.match(pending.supported,/平板/);
 assert.equal(f.preparations+f.profiles+f.signs+f.installs,0);
 result.deviceCompatibilityFingerprint=pending.fingerprint;result.stage=jobs.InstallStage.QUEUED;
 assert.equal((await f.run()).stage,jobs.InstallStage.INSTALLED);assert.equal(f.installs,1);
});

for (const local of [false, true]) for (const extension of ['.hap', '.app']) {
  test('actual ' + (local ? 'local' : 'API declarations absent') + extension + ' mismatch pauses before AGC or signing', async () => {
    const f = fixture({ local, extension }), running = f.run(); await tick();
    assert.equal(f.dialogs.length, 1); assert.match(f.dialogs[0].options.message, /真实应用.*平板/);
    assert.equal(f.preparations, 0); assert.equal(f.profiles, 0); assert.equal(f.signs, 0);
    f.dialogs[0].resolve({ index: 0 }); const result = await running;
    assert.equal(result.stage, jobs.InstallStage.WAITING_COMPATIBILITY);
    assert.equal(result.reinstallRequired, true); assert.equal(result.allowDataLoss, false);
    assert.equal(result.deviceCompatibilityFingerprint, ''); assert.equal(f.installs, 0);
    assert.equal(f.preparations, 0); assert.equal(f.profiles, 0); assert.equal(f.signs, 0);
  });
}

test('cancelled compatibility confirmation cannot turn an old same-code installation into success on manual retry', async () => {
  const f = fixture({ local: true }), running = f.run(); await tick();
  f.dialogs[0].resolve({ index: 0 }); await running; f.localVersion = 7;
  f.runtime = f.createRuntime(); const retry = f.run(); await tick();
  assert.equal(f.dialogs.length, 2); assert.equal(f.installs, 0);
  f.dialogs[1].resolve({ index: 0 }); assert.equal((await retry).stage, jobs.InstallStage.WAITING_COMPATIBILITY);
  assert.equal(f.preparations, 0);
});

test('one explicit acceptance continues the full real runtime pipeline without a second prompt', async () => {
  const f = fixture({ local: true }), running = f.run(); await tick();
  f.dialogs[0].resolve({ index: 1 }); assert.equal((await running).stage, jobs.InstallStage.INSTALLED);
  assert.equal(f.dialogs.length, 1); assert.equal(f.preparations, 1); assert.equal(f.profiles, 1);
  assert.equal(f.signs, 1); assert.equal(f.installs, 1); assert.ok(f.job.deviceCompatibilityFingerprint);
});

for (const entry of ['ensureProfile', 'sign', 'install']) test('a restored task cannot bypass the real manifest through ' + entry, async () => {
  const f = fixture(), action = f.runtime[entry](f.job); await tick();
  assert.equal(f.dialogs.length, 1); f.dialogs[0].resolve({ index: 0 });
  await assert.rejects(action, error => error.kind === jobs.FailureKind.COMPATIBILITY);
  assert.equal(f.preparations + f.profiles + f.signs + f.installs, 0);
});

test('original-signed installer fast return still requires actual device confirmation', async () => {
  const f = fixture(); f.runtime.usesOriginalInstaller = () => true;
  const signing = f.runtime.sign(f.job); await tick(); assert.equal(f.dialogs.length, 1);
  f.dialogs[0].resolve({ index: 0 }); await assert.rejects(signing, error => error.kind === jobs.FailureKind.COMPATIBILITY);
  assert.equal(f.signs, 0);
});

test('matching, missing manifest declaration and unknown current system type remain nonblocking without consent', async () => {
  for (const settings of [{ types: ['phone'] }, { types: undefined }, { current: 'default' }]) {
    const f = fixture(settings);
    if ('types' in settings && settings.types === undefined) {
      f.files.set(f.job.cachePath, f.manifest(undefined)); f.job.expectedSha256 = digest(f.files.get(f.job.cachePath));
    }
    if (settings.current) f.current = settings.current;
    await f.runtime.ensureProfile(f.job);
    assert.equal(f.dialogs.length, 0); assert.equal(f.preparations, 1);
    assert.equal(f.job.deviceCompatibilityFingerprint, '');
  }
});

test('a modified cache cannot consume a metadata acceptance or reach AGC', async () => {
  const f = fixture(); f.job.deviceCompatibilityFingerprint = JSON.stringify([1, f.job.catalogSourceUrl,
    f.job.expectedSha256, 'phone', ['tablet']]);
  f.files.set(f.job.cachePath, f.manifest(['2in1']));
  await assert.rejects(f.runtime.ensureProfile(f.job), error => error.kind === jobs.FailureKind.INVALID_PACKAGE);
  assert.equal(f.dialogs.length, 0); assert.equal(f.preparations, 0); assert.equal(f.profiles, 0);
});

test('explicit metadata consent is reused only after actual SHA and manifest targets agree', async () => {
  const f = fixture(), asset = { bundleName: f.job.bundleName, versionCode: 7, name: f.job.assetName,
    url: f.job.catalogSourceUrl, sha256: f.job.expectedSha256, deviceTypes: ['TABLET', 'tablet'] };
  const warning = f.compatibility.confirm(asset, '目录应用'); await tick(); f.dialogs[0].resolve({ index: 1 }); await warning;
  f.job.deviceCompatibilityFingerprint = f.compatibility.confirmedFingerprint(asset);
  f.job.sourceUrl = 'https://mirror.example/actual.hap';
  await f.runtime.ensureProfile(f.job); assert.equal(f.dialogs.length, 1); assert.equal(f.preparations, 1);
  const changed = fixture(); changed.job.deviceCompatibilityFingerprint = f.job.deviceCompatibilityFingerprint;
  changed.files.set(changed.job.cachePath, changed.manifest(['2in1'])); changed.job.expectedSha256 = digest(changed.files.get(changed.job.cachePath));
  const guarded = changed.runtime.ensureProfile(changed.job); await tick(); assert.equal(changed.dialogs.length, 1);
  changed.dialogs[0].resolve({ index: 0 }); await assert.rejects(guarded, error => error.kind === jobs.FailureKind.COMPATIBILITY);
});

test('same-runtime ZIP A-to-B switch invalidates both the extracted-byte cache and accepted receipt before AGC', async () => {
  const f = fixture({ extension: '.zip', selected: 'A.hap' });
  const asset = { bundleName: f.job.bundleName, versionCode: 7, name: f.job.assetName,
    url: f.job.catalogSourceUrl, sha256: f.job.expectedSha256, deviceTypes: ['tablet'] };
  const initial = f.compatibility.confirm(asset, '目录 A'); await tick(); f.dialogs[0].resolve({ index: 1 }); await initial;
  f.job.deviceCompatibilityFingerprint = f.compatibility.confirmedFingerprint(asset);
  await f.runtime.inspectPackage(f.job);
  const firstInner = f.job.packageSourceSha256; assert.equal(f.dialogs.length, 1);
  f.job.sourceUrl = 'https://mirror.example/actual.zip#qingqi-package=B.hap';
  const switched = f.runtime.ensureProfile(f.job); await tick();
  assert.deepEqual(f.extractions, ['A.hap', 'B.hap']);
  assert.equal(f.job.packageSourceSha256, digest(f.modules.get('B.hap')));
  assert.notEqual(f.job.packageSourceSha256, firstInner);
  assert.equal(f.dialogs.length, 2); assert.equal(f.preparations + f.profiles, 0);
  f.dialogs[1].resolve({ index: 0 }); await assert.rejects(switched, error => error.kind === jobs.FailureKind.COMPATIBILITY);
  assert.equal(f.preparations + f.profiles + f.signs + f.installs, 0);
});

test('a granted compatibility warning preserves later AGC and installation failures', async () => {
  for (const failure of ['profile', 'install']) {
    const f = fixture({ local: true });
    if (failure === 'profile') f.profileError = new runner.JobFailure(jobs.FailureKind.NETWORK, 'AGC offline');
    else f.installError = Error('signature verification failed');
    const running = f.run(); await tick(); f.dialogs[0].resolve({ index: 1 }); const result = await running;
    assert.equal(result.stage, failure === 'profile' ? jobs.InstallStage.WAITING_NETWORK : jobs.InstallStage.RETRYABLE_ERROR);
    assert.match(result.lastError, failure === 'profile' ? /AGC offline/ : /signature verification failed/);
    assert.equal(f.dialogs.length, 1); assert.notEqual(result.stage, jobs.InstallStage.INSTALLED);
  }
});

function sqliteFixture(t, legacy) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/JobStore.ets'), 'utf8');
  const schema = source.match(/const JOB_SCHEMA = `([\s\S]*?)`;/)[1];
  if (legacy) db.exec(schema.replace(/^  (catalog_source_url|device_compatibility_fingerprint).*\n/gm, ''));
  const adapter = {
    executeSql: async (sql, args = []) => db.prepare(sql).run(...args),
    querySql: async (sql, args = []) => {
      const statement = db.prepare(sql), rows = statement.all(...args), columns = statement.columns().map(row => row.name); let index = -1;
      return { goToNextRow: () => ++index < rows.length, getColumnIndex: name => columns.indexOf(name),
        getString: column => String(rows[index][columns[column]]), getLong: column => Number(rows[index][columns[column]]), close() {} };
    }
  };
  const { JobStore } = loadEts('jobs/JobStore', { './InstallJob': jobs, './RecoveryPlanner': planner,
    '@kit.ArkData': { relationalStore: { getRdbStore: async () => adapter, SecurityLevel: { S1: 1 } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false } }, './JobCancellation': cancellation,
    './InstallTaskState': { InstallTaskState: { publish() {} } } });
  return { JobStore, context: { filesDir: '/private' } };
}

for (const legacy of [false, true]) test('real SQLite persists the exact accepted bytes across process/runtime restart; legacy=' + legacy, async t => {
  const journal = sqliteFixture(t, legacy), store = await journal.JobStore.initialize(journal.context);
  const f = fixture(); f.job.profilePath = ''; f.job.profileSha256 = '';
  const enqueue = await store.enqueue(42, f.job.assetName, f.job.sourceUrl, f.job.expectedSha256,
    ['https://mirror.example/actual.hap'], '', f.job.bundleName, 7, '', '', true);
  assert.equal(enqueue.deviceCompatibilityFingerprint, ''); assert.equal(enqueue.catalogSourceUrl, f.job.sourceUrl);
  f.job.id = enqueue.id;
  const inspecting = f.runtime.inspectPackage(f.job); await tick(); f.dialogs[0].resolve({ index: 1 }); await inspecting;
  f.job.stage = jobs.InstallStage.PACKAGE_INSPECTED; await store.save(f.job);
  const reopened = await journal.JobStore.initialize(journal.context), restored = await reopened.get(f.job.id);
  const view = jobs.InstallJob.displayCopy(restored);
  assert.equal(restored.deviceCompatibilityFingerprint, f.job.deviceCompatibilityFingerprint);
  assert.equal(view.deviceCompatibilityFingerprint, f.job.deviceCompatibilityFingerprint);
  assert.equal(restored.catalogSourceUrl, f.job.catalogSourceUrl); assert.equal(view.catalogSourceUrl, f.job.catalogSourceUrl);
  const freshProcess = fixture(); freshProcess.job = restored;
  // A fresh compatibility class has no prior in-memory confirmations.
  const runtime = freshProcess.createRuntime(reopened);
  await runtime.inspectEvidence(restored); await runtime.ensureProfile(restored);
  assert.equal(freshProcess.dialogs.length, 0); assert.equal(freshProcess.preparations, 1);
});

test('SQLite enqueue preserves pending consent but a completed reinstall request requires a fresh real-package decision', async t => {
  const journal = sqliteFixture(t, true), store = await journal.JobStore.initialize(journal.context), f = fixture();
  const args = [42, f.job.assetName, f.job.sourceUrl, f.job.expectedSha256,
    [], '', f.job.bundleName, 7, '', '', true];
  const enqueued = await store.enqueue(...args); f.job.id = enqueued.id;
  const inspect = f.runtime.inspectPackage(f.job); await tick(); f.dialogs[0].resolve({ index: 1 }); await inspect;
  f.job.stage = jobs.InstallStage.WAITING_NETWORK; await store.save(f.job);
  const pending = await store.enqueue(...args);
  assert.equal(pending.deviceCompatibilityFingerprint, f.job.deviceCompatibilityFingerprint, 'pending resume retains accepted real bytes');
  pending.stage = jobs.InstallStage.INSTALLED; await store.save(pending);
  const reinstall = await store.enqueue(...args);
  assert.equal(reinstall.deviceCompatibilityFingerprint, '', 'new install request cannot borrow last completed approval');
  reinstall.stage = jobs.InstallStage.QUEUED; reinstall.reinstallRequired = true; await store.save(reinstall);
  const fresh = fixture(); fresh.job = reinstall;
  const running = new runner.JobRunner(store, fresh.createRuntime(store)).run(reinstall.id); await tick();
  assert.equal(fresh.dialogs.length, 1); assert.equal(fresh.preparations, 0);
  fresh.dialogs[0].resolve({ index: 0 }); assert.equal((await running).stage, jobs.InstallStage.WAITING_COMPATIBILITY);
  assert.equal(fresh.preparations + fresh.profiles + fresh.signs + fresh.installs, 0);
});

test('an explicit new metadata decision replaces a completed receipt before the task is queued again', async t => {
  const journal = sqliteFixture(t, false), store = await journal.JobStore.initialize(journal.context), f = fixture();
  const asset = { bundleName: f.job.bundleName, versionCode: 7, name: f.job.assetName,
    url: f.job.sourceUrl, sha256: f.job.expectedSha256, deviceTypes: ['tablet'] };
  const args = [42, asset.name, asset.url, asset.sha256, [], '', asset.bundleName, 7, '', '', true];
  const original = await store.enqueue(...args); original.stage = jobs.InstallStage.INSTALLED;
  original.deviceCompatibilityFingerprint = 'old completed receipt'; await store.save(original);
  const warning = f.compatibility.confirm(asset, '目录应用'); await tick();
  f.dialogs[0].resolve({ index: 1 }); await warning;
  const freshReceipt = f.compatibility.confirmedFingerprint(asset), requested = await store.enqueue(...args, freshReceipt);
  assert.equal(requested.deviceCompatibilityFingerprint, freshReceipt);
  assert.equal((await store.get(requested.id)).deviceCompatibilityFingerprint, freshReceipt);
});

test('compatibility pause is distinct from data-loss confirmation and cannot be resumed by condition changes', async () => {
  assert.equal(planner.stageForFailure(jobs.FailureKind.COMPATIBILITY), jobs.InstallStage.WAITING_COMPATIBILITY);
  assert.notEqual(jobs.InstallStage.WAITING_COMPATIBILITY, jobs.InstallStage.WAITING_CONFIRMATION);
  const { InstallCoordinator } = loadEts('jobs/InstallCoordinator', { './InstallJob': jobs,
    './JobStore': { JobStore: { open: async () => { throw Error('automatic compatibility resume reached journal'); } } } });
  await InstallCoordinator.conditionReady({}, jobs.InstallStage.WAITING_COMPATIBILITY);
  const state = loadEts('jobs/InstallTaskState', { './InstallJob': jobs });
  const row = { job: Object.assign(new jobs.InstallJob(), { stage: jobs.InstallStage.WAITING_COMPATIBILITY }), running: false };
  assert.equal(state.InstallTaskState.label(row), '等待确认设备适配');
  assert.equal(state.InstallTaskState.compactLabel(row), '适配');
});
