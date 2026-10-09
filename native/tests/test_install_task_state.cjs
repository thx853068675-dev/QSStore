// Run: node --test native/tests/test_install_task_state.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function fixture(kits = {}) {
  const modules = new Map();
  const stats = { serializations: 0 };
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {};
    modules.set(name, exports);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInNewContext(code, { exports, setTimeout, clearTimeout, setInterval: () => 1, clearInterval: () => {},
      JSON: { parse: JSON.parse, stringify: (...args) => { stats.serializations++; return JSON.stringify(...args); } },
      require: dep => dep.startsWith('.') ? load(path.posix.join(path.posix.dirname(name), dep)) : (kits[dep] || {}) });
    return exports;
  }
  const { InstallJob, InstallStage } = load('jobs/InstallJob');
  const { InstallTaskState: state } = load('jobs/InstallTaskState');
  const { JobScheduler: scheduler } = load('jobs/JobScheduler');
  const { JobStore } = load('jobs/JobStore');
  const writes = [];
  const store = new JobStore({ executeSql: async (...args) => writes.push(args) });
  const job = InstallJob.create('42:release:sha', 42, 'app.hap', 'https://example.org/a.hap', 'a'.repeat(64));
  job.bundleName = 'test.bundle'; job.versionCode = 2;
  return { load, state, scheduler, store, job, InstallStage, writes, stats };
}
function pageClass(name, methods, globals) {
  const source = fs.readFileSync(path.join(root, `pages/${name}.ets`), 'utf8');
  const parts = methods.map(method => {
    const start = source.search(new RegExp(`^  private (?:async )?${method}\\(`, 'm'));
    assert.notEqual(start, -1, `production method ${method}`);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const code = ts.transpileModule(`class Page { ${parts.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const sandbox = { ...globals }; vm.runInNewContext(code, sandbox);
  return new sandbox.Page();
}
function pages(f) {
  const globals = { CatalogPackageVariant: f.load('data/CatalogPackageVariant').CatalogPackageVariant, InstallTaskState: f.state, InstallStage: f.InstallStage,
    ReleaseUpdate: f.load('jobs/ReleaseUpdate').ReleaseUpdate,
    InstalledAppRegistry: { versionName: () => '', signingIdentity: () => undefined },
    LocalInstallTimeline: f.load('jobs/LocalInstallTimeline').LocalInstallTimeline,
    setInterval: () => 1, clearInterval: () => {},
    isPending: f.load('jobs/RecoveryPlanner').isPending };
  const index = pageClass('Index', ['latestAssets', 'assetForBundle', 'observeInstallTasks', 'taskForApp', 'taskPending', 'jobRunning', 'queueTime', 'taskJobLabel'], globals);
  Object.assign(index, { installSubscription: -1, installTasks: [], pendingJobs: [], installedJobs: [],
    catalogApp: () => undefined, updateFor: () => undefined,
    refreshCatalogInstallState() {}, checkInstalledUpdates() {} });
  index.observeInstallTasks();
  function detail() {
    const ui = pageClass('Detail', ['observeInstallTasks', 'currentInstallTask', 'syncInstallTask',
      'installButtonLabel', 'updateAvailable', 'selectedDowngrade', 'installButtonEnabled'], globals);
    Object.assign(ui, { installSubscription: -1, detailAppId: 42,
      selectedAsset: { name: 'app.hap', sha256: 'a'.repeat(64),
        bundleName: 'test.bundle', versionCode: 2 },
      releases: [], showPreviewReleases: false, installTasks: [], installedJobs: [], downloadBusy: false, downloadPercent: 0,
      paintInstallButton() {}, refreshInstalledVersion() {}, installedForApp() { return this.installedJobs[0]; },
      selectedVersionLabel: () => '2' });
    ui.observeInstallTasks(); return ui;
  }
  function local() {
    const ui = pageClass('LocalInstall', ['observeTasks', 'refreshTimeline'], {
      ...globals, LocalTimelineView: f.load('jobs/LocalInstallTimeline').LocalTimelineView
    });
    Object.assign(ui, { subscription: -1, tasks: [], preview: false, selected: f.job });
    ui.observeTasks(); return ui;
  }
  return { index, detail, local };
}
test('data-loss approval is bound to the exact installed identity and only a waiting task', async () => {
  const f = fixture();
  f.job.stage = f.InstallStage.WAITING_CONFIRMATION;
  f.store.get = async () => f.job;
  await assert.rejects(() => f.store.approveDataLoss(f.job.id,
    { versionCode: 0, fingerprint: '', appIdentifier: '' }), /无法核对/);
  const approved = await f.store.approveDataLoss(f.job.id,
    { versionCode: 4, fingerprint: 'A'.repeat(64), appIdentifier: 'app-id' });
  assert.equal(approved.allowDataLoss, true);
  assert.equal(approved.approvedInstalledVersion, 4);
  assert.equal(approved.approvedInstalledFingerprint, 'A'.repeat(64));
  f.job.stage = f.InstallStage.INSTALLED;
  await assert.rejects(() => f.store.approveDataLoss(f.job.id,
    { versionCode: 4, fingerprint: 'A'.repeat(64), appIdentifier: 'app-id' }), /不再等待确认/);
});
test('Discover, a newly opened Detail, and Management consume the same running task and percentage', async () => {
  const f = fixture(), { index, detail } = pages(f);
  f.job.stage = f.InstallStage.DOWNLOADING; await f.store.save(f.job);
  let release; const gate = new Promise(r => release = r);
  const work = f.scheduler.runExclusive(f.job.id, () => gate);
  f.state.downloadProgress(f.job.id, 50, 100);
  const d = detail();
  assert.equal(index.taskJobLabel(f.job), '下载中 50%');
  assert.equal(d.installButtonLabel(), index.taskJobLabel(f.job));
  assert.equal(d.downloadPercent, 50); assert.equal(d.downloadBusy, true);
  assert.equal(index.pendingJobs.length, 1);
  assert.equal(index.taskJobLabel(index.pendingJobs[0]), d.installButtonLabel());
  await assert.rejects(f.scheduler.runExclusive(f.job.id, async () => {}), /正在执行/);
  f.job.stage = f.InstallStage.PROFILE_READY; await f.store.save(f.job);
  assert.equal(d.installButtonLabel(), '签名中');
  assert.equal(index.taskJobLabel(f.job), d.installButtonLabel());
  f.job.stage = f.InstallStage.INSTALLED; await f.store.save(f.job); release(); await work;
  assert.equal(d.downloadBusy, false); assert.equal(d.installButtonLabel(), '打开应用');
  assert.equal(index.taskPending(42), false); assert.equal(index.pendingJobs.length, 0);
  assert.equal(index.installedJobs.length, 1);
});
test('paused device/account/network states stay consistent and release running UI', async () => {
  for (const stage of ['WAITING_DEVICE', 'WAITING_ACCOUNT', 'WAITING_NETWORK', 'RETRYABLE_ERROR']) {
    const f = fixture(), { index, detail } = pages(f), d = detail();
    await f.store.save(f.job);
    await f.scheduler.runExclusive(f.job.id, async () => {
      f.job.stage = f.InstallStage[stage]; await f.store.save(f.job);
    });
    assert.equal(index.jobRunning(f.job.id), false); assert.equal(d.downloadBusy, false);
    assert.equal(d.installButtonLabel(), index.taskJobLabel(f.job) + ' · 继续');
  }
});
test('unknown device state leaves installation available and offers recorded updates', () => {
  const f = fixture(); const { detail } = pages(f); const d = detail();
  d.installedUnknown = true;
  assert.equal(d.installButtonLabel(), '安装/更新');
  d.installedJobs = [{ bundleName: 'test.bundle', versionCode: 1 }];
  assert.equal(d.updateAvailable(), true);
  assert.equal(d.installButtonLabel(), '更新到 2');
});
test('slow seed and removal cannot resurrect obsolete records or reset byte progress', async () => {
  const f = fixture(); f.job.stage = f.InstallStage.DOWNLOADING;
  const stale = JSON.parse(JSON.stringify(f.job)); await f.store.save(f.job);
  f.state.downloadProgress(f.job.id, 70, 100); f.state.seed([stale]);
  assert.equal(f.state.snapshot()[0].percent, 70);
  await f.store.forget(f.job.id); f.state.seed([stale]);
  assert.equal(f.state.snapshot().length, 0);
});

test('journal rechecks do not broadcast unchanged histories, while new rows and live progress still publish', () => {
  const f = fixture(); let events = 0;
  f.state.subscribe(() => events++); assert.equal(events, 1);
  f.state.seed([f.job]); assert.equal(events, 2);
  for (let i = 0; i < 100; i++) f.state.seed([JSON.parse(JSON.stringify(f.job))]);
  assert.equal(events, 2);
  f.job.stage = f.InstallStage.DOWNLOADING; f.state.publish(f.job);
  assert.equal(events, 3);
  f.state.downloadProgress(f.job.id, 50, 100); assert.equal(events, 4);
  f.state.seed([f.job]); assert.equal(events, 4);
  assert.equal(f.state.snapshot()[0].percent, 50);
});
test('running newer update wins over an older installed task, also when matched by bundle', async () => {
  const f = fixture(); const old = JSON.parse(JSON.stringify(f.job));
  old.id = 'old'; old.stage = f.InstallStage.INSTALLED; old.updatedAt = Date.now() + 1000;
  f.state.seed([old]); await f.store.save(f.job); f.state.setRunning(f.job.id, true);
  assert.equal(f.state.forApp(f.state.snapshot(), 42).job.id, f.job.id);
  assert.equal(f.state.forApp(f.state.snapshot(), 0, 'test.bundle').job.id, f.job.id);
  assert.equal(f.state.forApp(f.state.snapshot(), 0), undefined);
});
test('a failed old release cannot replace the selected newer or reuploaded asset', async () => {
  const f = fixture();
  f.job.assetName = 'installer.hap';
  f.job.catalogVersionCode = 2;
  f.job.expectedSha256 = 'a'.repeat(64);
  f.job.stage = f.InstallStage.RETRYABLE_ERROR;
  await f.store.save(f.job);
  const rows = f.state.snapshot();
  assert.equal(f.state.forAsset(rows, 42, 'test.bundle', 'installer.hap',
    'b'.repeat(64), 2), undefined);
  assert.equal(f.state.forAsset(rows, 42, 'test.bundle', 'installer.hap',
    'a'.repeat(64), 3), undefined);
  assert.equal(f.state.forAsset(rows, 42, 'test.bundle', 'installer.hap',
    'a'.repeat(64), 2).job.id, f.job.id);
  f.state.remove(f.job.id);
  f.job.id = '42:installer.hap:' + 'a'.repeat(64);
  f.job.expectedSha256 = 'f'.repeat(64); // 实际下载摘要与目录摘要不同
  await f.store.save(f.job);
  assert.equal(f.state.forAsset(f.state.snapshot(), 42, 'test.bundle',
    'installer.hap', 'a'.repeat(64), 2).job.id, f.job.id);
});
test('store publishes only successful saves, and snapshots do not follow unsaved mutations', async () => {
  const f = fixture(); await f.store.save(f.job); const before = f.state.snapshot()[0];
  f.job.stage = f.InstallStage.INSTALLED;
  f.store.db.executeSql = async () => { throw Error('disk full'); };
  await assert.rejects(f.store.save(f.job), /disk full/);
  assert.equal(f.state.snapshot()[0].job.stage, f.InstallStage.QUEUED);
  assert.equal(before.job.stage, f.InstallStage.QUEUED);
});
test('unsubscribed pages stop receiving events; new pages immediately receive current state', async () => {
  const f = fixture(); let calls = 0;
  const id = f.state.subscribe(() => calls++); f.state.unsubscribe(id);
  await f.store.save(f.job); assert.equal(calls, 1);
  let rows; f.state.subscribe(value => rows = value);
  assert.equal(rows[0].job.id, f.job.id);
});
test('timeout keeps every page busy until actual work finishes', async () => {
  const f = fixture(), { index, detail } = pages(f); await f.store.save(f.job); const d = detail();
  let release; const gate = new Promise(r => release = r);
  await assert.rejects(f.scheduler.runExclusive(f.job.id, () => gate, 5), /超时/);
  assert.equal(d.downloadBusy, true); assert.equal(d.installButtonLabel(), '正在收尾');
  assert.equal(index.taskJobLabel(f.job), '正在收尾'); release(); await new Promise(setImmediate);
  assert.equal(d.downloadBusy, false); assert.equal(index.jobRunning(f.job.id), false);
});

test('re-picking the same local HAP does not revive a stalled stage history', async () => {
  const f = fixture();
  const sha = 'b'.repeat(64);
  const args = ['/sandbox/a.hap', '/sandbox/a-signed.hap', sha, 'test.bundle', 2, 'entry', 'EntryAbility'];
  const { InstallJob: Job } = f.load('jobs/InstallJob');
  const stalled = Job.create('local:' + sha, 0, 'test.bundle.hap', 'local', sha);
  stalled.stage = f.InstallStage.PACKAGE_INSPECTED;
  stalled.updatedAt = 1000;   // 明显过时，重建后会刷新
  f.store.get = async () => stalled;
  const rebuilt = await f.store.enqueueLocal(...args);
  // 停在中间阶段的记录是上次中断留下的，必须重建，否则界面会一直显示那条旧时间轴
  assert.equal(rebuilt.stage, f.InstallStage.PACKAGE_INSPECTED);
  assert.equal(rebuilt.stageHistory.length, 1);
  assert.ok(rebuilt.updatedAt > 1000, '重建后应刷新时间戳，便于排序与展示');
});

test('explicit same-version local reinstallation cannot accept an old installation', async () => {
  const f = fixture();
  const sha = 'c'.repeat(64);
  const args = ['/sandbox/a.hap', '/sandbox/a-signed.hap', sha, 'test.bundle', 2, 'entry', 'EntryAbility'];
  const { InstallJob: Job } = f.load('jobs/InstallJob');
  const done = Job.create('local:' + sha, 0, 'test.bundle.hap', 'local', sha);
  done.stage = f.InstallStage.INSTALLED;
  done.updatedAt = 4242;
  f.store.get = async () => done;
  const reused = await f.store.enqueueLocal(...args);
  assert.equal(reused, done);
  assert.equal(reused.stage, f.InstallStage.PACKAGE_INSPECTED);
  assert.equal(reused.reinstallRequired, true);
  assert.ok(reused.updatedAt > 4242);
  assert.equal(reused.stageHistory.length, 1);
});

function localFixture() {
  const f = fixture();
  f.job.id = 'local:' + 'a'.repeat(64); f.job.appId = 0; f.job.sourceUrl = 'local';
  f.job.cachePath = '/sandbox/local.hap'; f.job.signedPath = '/sandbox/local.signed.hap';
  f.job.stage = f.InstallStage.PACKAGE_INSPECTED;
  f.timeline = f.load('jobs/LocalInstallTimeline').LocalInstallTimeline;
  f.view = (now = Date.now()) => f.timeline.present(f.state.snapshot(), f.job.id, now);
  return f;
}
test('local timeline: inspected milestone completes while authorization has its own spinner', async () => {
  const f = localFixture(); await f.store.save(f.job); f.state.setRunning(f.job.id, true);
  const view = f.view();
  assert.equal(view.steps[0].label, '已核对应用身份');
  assert.equal(view.steps[0].indicator, 'done');
  assert.equal(view.steps[1].label, '正在准备设备授权');
  assert.equal(view.steps[1].indicator, 'running');
});
test('local timeline: actual runner pushes authorization, signing, install and completion into the page', async () => {
  const f = localFixture(), ui = pages(f).local();
  await f.store.save(f.job);
  f.store.get = async () => JSON.parse(JSON.stringify(f.state.snapshot()[0].job));
  let installed = 0;
  const runtime = {
    inspectEvidence: async () => ({ verifiedCache: true, validProfile: false,
      verifiedSignature: false, deviceConnected: true, installedVersionCode: 0 }),
    ensureProfile: async () => {}, sign: async () => {}, verifySignature: async () => {},
    ensureDevice: async () => true, install: async () => { installed = 2; },
    installedVersion: async () => installed
  };
  const views = []; const observer = f.state.subscribe(() => views.push(ui.timeline));
  const { JobRunner } = f.load('jobs/JobRunner');
  const result = await new JobRunner(f.store, runtime).run(f.job.id);
  f.state.unsubscribe(observer);
  assert.equal(result.stage, f.InstallStage.INSTALLED);
  for (const label of ['正在准备设备授权', '正在用本机证书签名', '正在校验签名', '正在连接设备', '正在安装到设备']) {
    assert.ok(views.some(view => view.steps.some(step => step.label === label && step.indicator === 'running')), label);
  }
  assert.equal(ui.timeline.status, '安装完成');
  assert.equal(ui.timeline.steps.at(-1).label, '安装完成');
  assert.equal(ui.timeline.steps.some(step => step.indicator === 'running'), false);
  f.state.unsubscribe(ui.subscription);
});
test('a submitted install with an old reported version pauses without asking to reconnect', async () => {
  const f = localFixture(); f.job.stage = f.InstallStage.INSTALLING;
  await f.store.save(f.job);
  f.store.get = async () => JSON.parse(JSON.stringify(f.job));
  const runtime = { inspectEvidence: async () => ({ verifiedCache: true,
    validProfile: true, verifiedSignature: true, deviceConnected: true,
    installedVersionCode: 1 }),
    installedVersion: async () => 1, install: async () => {} };
  const { JobRunner } = f.load('jobs/JobRunner');
  JobRunner.PROBE_TOTAL_MS = 0;
  const result = await new JobRunner(f.store, runtime).run(f.job.id);
  assert.equal(result.stage, f.InstallStage.RETRYABLE_ERROR);
  assert.match(result.lastError, /新版本尚未生效/);
});
test('local timeline: completing the same historical row changes its ForEach key and removes its spinner', async () => {
  const f = localFixture(); f.job.stage = f.InstallStage.INSTALLING;
  await f.store.save(f.job); f.state.setRunning(f.job.id, true);
  const before = f.view().steps[0];
  f.job.stage = f.InstallStage.INSTALLED; await f.store.save(f.job);
  // Success must stop animation before scheduler finally releases the lock.
  const after = f.view().steps[0];
  assert.notEqual(after.key, before.key);
  assert.equal(before.indicator, 'running'); assert.equal(after.indicator, 'done');
  assert.equal(f.view().running, false);
});
test('local timeline: waiting, retryable and terminal failures remain visible without spinning', async () => {
  for (const stage of ['WAITING_DEVICE', 'WAITING_ACCOUNT', 'WAITING_NETWORK', 'RETRYABLE_ERROR', 'TERMINAL_ERROR']) {
    const f = localFixture(), ui = pages(f).local();
    await f.store.save(f.job); f.state.setRunning(f.job.id, true);
    f.job.stage = f.InstallStage[stage]; f.job.lastError = 'test failure'; await f.store.save(f.job);
    f.state.setRunning(f.job.id, false);
    assert.equal(ui.timeline.visible, true, stage);
    assert.equal(ui.timeline.running, false, stage);
    assert.equal(ui.timeline.steps.at(-1).indicator, 'paused', stage);
    assert.equal(ui.timeline.message, 'test failure', stage);
    f.state.unsubscribe(ui.subscription);
  }
});
test('local timeline: restart restores terminal state and selected local task excludes unrelated catalog work', async () => {
  const f = localFixture(); f.job.stage = f.InstallStage.TERMINAL_ERROR; await f.store.save(f.job);
  const catalog = fixture().job; catalog.updatedAt = Date.now() + 1000; f.state.publish(catalog);
  const view = f.timeline.present(f.state.snapshot(), f.job.id, Date.now());
  assert.equal(view.visible, true); assert.equal(view.status, '安装失败');
  assert.equal(view.steps.at(-1).indicator, 'paused');
  const restored = localFixture(); restored.state.seed([JSON.parse(JSON.stringify(f.job))]);
  assert.equal(restored.view().status, view.status);
});
test('local timeline: completed timing stays fixed and legacy records still show their actual terminal stage', async () => {
  const f = localFixture(); await f.store.save(f.job);
  f.job.stage = f.InstallStage.INSTALLED; await f.store.save(f.job);
  const before = f.view(100000); const after = f.view(200000);
  assert.deepEqual(Array.from(after.steps, row => row.timing), Array.from(before.steps, row => row.timing));
  f.job.stageHistory = []; await f.store.save(f.job);
  assert.equal(f.view().steps.at(-1).label, '安装完成');
  assert.equal(f.view().steps.at(-1).indicator, 'done');
});

test('local timeline stays hidden until a local task is selected', async () => {
  const f = localFixture(); await f.store.save(f.job);
  // 装完之后切走再回来不该继续挂着上一次的流程卡片：没有选中项就不显示
  const hidden = f.timeline.present(f.state.snapshot(), '', Date.now());
  assert.equal(hidden.visible, false);
  assert.deepEqual(Array.from(hidden.steps), []);
  // 显式选中才出现
  assert.equal(f.view().visible, true);
});

test('enqueueing an already completed asset retains its identity and installed journal', async () => {
  const f = fixture(); f.job.stage = f.InstallStage.INSTALLED;
  await f.store.save(f.job);
  f.store.get = async () => f.job;
  const writes = f.writes.length;
  const again = await f.store.enqueue(f.job.appId, f.job.assetName, f.job.sourceUrl, f.job.expectedSha256);
  assert.equal(again, f.job); assert.equal(again.stage, f.InstallStage.INSTALLED);
  assert.equal(again.bundleName, 'test.bundle'); assert.equal(f.writes.length, writes);
});

test('catalog asset without SHA-256 can still enter the install queue', async () => {
  const f = fixture();
  f.store.get = async () => undefined;
  const job = await f.store.enqueue(42, 'app.hap', 'https://example.org/app.hap', '');
  assert.equal(job.expectedSha256, '');
  assert.match(job.id, /https:\/\/example\.org\/app\.hap$/);
});

test('catalog digest is used for task identity, while package identity is retained for inspection', async () => {
  const f = fixture();
  f.store.get = async () => undefined;
  const digest = 'a'.repeat(64);
  const job = await f.store.enqueue(42, 'app.hap', 'https://example.org/app.hap', digest,
    [], '1.2.3', 'com.example.app', 123);
  assert.match(job.id, new RegExp(`${digest}$`));
  assert.equal(job.expectedSha256, '');
  assert.equal(job.catalogBundleName, 'com.example.app');
  assert.equal(job.catalogVersionCode, 123);
  const sql = f.writes.at(-1)[0];
  assert.equal((sql.match(/\?/g) || []).length, f.writes.at(-1)[1].length);
});

// ── 安装阶段的耗时反馈（95% 那段没有中间进度）──────────────────────

test('installing label shows elapsed time so a long install does not look frozen', () => {
  const f = localFixture();
  const start = 1000000;
  f.job.stage = f.InstallStage.INSTALLING;
  f.job.stageHistory = [{ stage: f.InstallStage.INSTALLING, at: start }];
  const row = { job: f.job, running: true, finishing: false, percent: 95 };
  // 设备只在结束时回结果，中途百分比不动；没有耗时的话界面完全静止
  assert.equal(f.state.label(row, start + 400), '等待设备接收');
  assert.equal(f.state.label(row, start + 47000), '等待设备接收 · 47 秒');
});

test('installing label omits elapsed time when the stage just started', () => {
  const f = localFixture();
  const start = 2000000;
  f.job.stage = f.InstallStage.INSTALLING;
  f.job.stageHistory = [{ stage: f.InstallStage.INSTALLING, at: start }];
  const row = { job: f.job, running: true, finishing: false, percent: 95 };
  assert.equal(f.state.label(row, start), '等待设备接收');
});

test('a paused install still says waiting instead of showing elapsed time', () => {
  const f = localFixture();
  f.job.stage = f.InstallStage.INSTALLING;
  f.job.stageHistory = [{ stage: f.InstallStage.INSTALLING, at: 1000 }];
  const row = { job: f.job, running: false, finishing: false, percent: 95 };
  assert.equal(f.state.label(row, 999999), '等待确认安装');
});

test('stageElapsedMs falls back to zero when the stage has no mark yet', () => {
  const f = localFixture();
  f.job.stage = f.InstallStage.INSTALLING;
  f.job.stageHistory = [];
  const row = { job: f.job, running: true, finishing: false, percent: 95 };
  assert.equal(f.state.stageElapsedMs(row, 5000), 0);
  assert.equal(f.state.label(row, 5000), '等待设备接收');
});

test('cancel removes the task immediately, blocks late saves, and cleans after live work settles', async () => {
  const f = fixture(); await f.store.save(f.job);
  let release; const gate = new Promise(r => release = r);
  let started; const entered = new Promise(resolve => { started = resolve; });
  let cleanups = 0, stopped = 0;
  f.store.cleanupCancelled = async () => { cleanups++; };
  f.store.stopTransfer = async () => { stopped++; return true; };
  const work = f.scheduler.runInstall(f.job.id, async () => {
    started();
    await gate;
    f.job.stage = f.InstallStage.INSTALLED;
    await f.store.save(f.job);
  });
  await entered; // 等后台任务申请结束并进入模拟原生调用，再取消。
  const cancelled = assert.rejects(work, /已取消/);
  await f.scheduler.cancel({ filesDir: '/sandbox' }, f.store, f.job);
  await cancelled;
  assert.equal(f.state.snapshot().length, 0);
  assert.equal(f.scheduler.isRunning(f.job.id), true, 'live work retains its lock');
  assert.equal(cleanups, 0, 'do not delete a package still used by a native call');
  await assert.rejects(f.store.save(f.job), /已取消/);
  release(); await new Promise(setImmediate);
  assert.equal(f.state.snapshot().length, 0, 'late native completion cannot resurrect the task');
  assert.equal(f.scheduler.isRunning(f.job.id), false);
  assert.equal(cleanups, 1); assert.equal(stopped, 1);
  assert(f.writes.some(([sql]) => sql.includes('cancelled_job_cleanup')));
});

test('cancel during a database save deletes the late write without publishing it', async () => {
  const f = fixture(); let release, inserting = true;
  const gate = new Promise(r => release = r);
  f.store.db.executeSql = async (sql) => {
    if (inserting && sql.includes('INSERT OR REPLACE INTO install_jobs')) {
      inserting = false; await gate;
    }
  };
  const saving = f.store.save(f.job);
  await f.store.cancel(f.job);
  release(); await assert.rejects(saving, /已取消/);
  assert.equal(f.state.snapshot().length, 0);
});

test('cancel cleanup removes task files and partials while retaining shared files and identity material', async () => {
  const files = new Set(['/sandbox/install-jobs/source.hap', '/sandbox/install-jobs/source.hap.part',
    '/sandbox/install-jobs/signed.hap', '/sandbox/signing-identity/key.pem', '/user/original.hap']);
  const f = fixture({ '@kit.CoreFileKit': { fileIo: {
    accessSync: p => files.has(p), unlinkSync: p => files.delete(p), listFileSync: () => []
  } } });
  f.job.cachePath = '/sandbox/install-jobs/source.hap';
  f.job.signedPath = '/sandbox/install-jobs/signed.hap';
  f.job.profilePath = '/sandbox/signing-identity/key.pem';
  f.store.listAll = async () => [{ id: 'other', cachePath: f.job.cachePath, signedPath: '' }];
  let read = false;
  f.store.db.querySql = async () => ({ goToNextRow: () => !read && (read = true),
    getColumnIndex: k => k, getString: () => JSON.stringify(f.job), close() {} });
  await f.store.cleanupCancelled({ filesDir: '/sandbox' });
  assert(files.has(f.job.cachePath), 'a retained task still owns the original package');
  assert(files.has(f.job.cachePath + '.part'), 'shared download is retained');
  assert(!files.has(f.job.signedPath));
  assert(files.has(f.job.profilePath)); assert(files.has('/user/original.hap'));
  assert(f.writes.some(([sql]) => sql.startsWith('DELETE FROM cancelled_job_cleanup')));
});

test('Management moves installed apps with queued updates into the task section, then restores them on cancel', () => {
  const ui = pageClass('Index', ['managementInstalledJobs'], {});
  const installed = [{ id: 'local', appId: 0, bundleName: 'test.bundle' },
    { id: 'other', appId: 12, bundleName: 'another.bundle' }];
  ui.allInstalledJobs = () => installed;
  ui.updateFor = () => undefined;
  ui.renewalDeadline = () => 1800000000;
  ui.updateApps = () => [{ latestAssets: installed.map(job => ({ bundleName: job.bundleName })) }];
  ui.installedAssets = app => app.latestAssets;
  ui.installedLocalOnly = false;
  ui.pendingJobs = [{ appId: 42, bundleName: '', catalogBundleName: 'test.bundle' }];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(), job => job.id), ['other']);
  ui.pendingJobs = [];
  assert.deepEqual(Array.from(ui.managementInstalledJobs(), job => job.id), ['local', 'other']);
});

test('failed transfer cancellation preserves its cleanup entry and files for retry', async () => {
  const files = new Set(['/sandbox/install-jobs/source.hap']);
  const f = fixture({ '@kit.CoreFileKit': { fileIo: {
    accessSync: p => files.has(p), unlinkSync: p => files.delete(p)
  } }, '@kit.BasicServicesKit': { request: { agent: {
    getTask: async () => { throw Object.assign(Error('busy'), { code: 21900001 }); }
  } } } });
  f.job.cachePath = '/sandbox/install-jobs/source.hap'; f.job.transferTaskId = 'still-live';
  let read = false;
  f.store.db.querySql = async () => ({ goToNextRow: () => !read && (read = true),
    getColumnIndex: k => k, getString: () => JSON.stringify(f.job), close() {} });
  await f.store.cleanupCancelled({ filesDir: '/sandbox' });
  assert(files.has(f.job.cachePath));
  assert(!f.writes.some(([sql]) => sql.startsWith('DELETE FROM cancelled_job_cleanup')));
});

test('selecting QuietStart again repairs its embedded worker even when the main version is installed', async () => {
  const f = fixture(), sha = 'e'.repeat(64);
  const { InstallJob } = f.load('jobs/InstallJob');
  const done = InstallJob.create('local:' + sha, 0, 'quietstart.hap', 'local', sha);
  done.stage = f.InstallStage.INSTALLED;
  f.store.get = async () => done;
  const job = await f.store.enqueueLocal('/sandbox/main.hap', '/sandbox/signed.hap', sha,
    'com.tonghongxiang.quietstart', 120000, '1.2.0', 'entry', 'EntryAbility');
  assert.equal(job.reinstallRequired, true);
  assert.equal(job.stage, f.InstallStage.PACKAGE_INSPECTED);
  const save = f.writes.at(-1);
  assert.match(save[0], /reinstall_required/);
});
test('same-version module repair submits installation rather than accepting version equality', async () => {
  const f = localFixture(); f.job.reinstallRequired = true;
  await f.store.save(f.job); f.store.get = async () => f.job;
  let calls = 0;
  const runtime = {
    inspectEvidence: async () => ({ verifiedCache: true, validProfile: true,
      verifiedSignature: true, deviceConnected: true, installedVersionCode: 2 }),
    installedVersion: async () => 2,
    install: async () => { calls++; }
  };
  const { JobRunner } = f.load('jobs/JobRunner');
  const result = await new JobRunner(f.store, runtime).run(f.job.id);
  assert.equal(calls, 1);
  assert.equal(result.stage, f.InstallStage.INSTALLED);
  assert.equal(result.reinstallRequired, false);
});

test('device transfer has real byte percentages; system install never pretends to be at 95 percent', async () => {
  const f = fixture(), { index, detail } = pages(f), d = detail();
  f.job.stage = f.InstallStage.INSTALLING; await f.store.save(f.job);
  f.state.setRunning(f.job.id, true);
  f.state.installProgress(f.job.id, 'transfer', 25, 100);
  assert.equal(index.taskJobLabel(f.job), '传送中 25%');
  assert.equal(d.installButtonLabel(), index.taskJobLabel(f.job));
  assert.equal(f.state.determinate(f.state.snapshot()[0]), true);
  // Updating another job field must not erase the live transfer observation.
  await f.store.save(f.job); assert.equal(d.downloadPercent, 25);
  f.state.installProgress(f.job.id, 'installing', 100, 100);
  assert.match(d.installButtonLabel(), /^系统安装中/);
  assert.equal(f.state.determinate(f.state.snapshot()[0]), false);
  assert.doesNotMatch(d.installButtonLabel(), /95|100%/);
  f.state.installProgress(f.job.id, 'verifying', 0, 0);
  assert.match(index.taskJobLabel(f.job), /^确认安装结果/);
  f.job.stage = f.InstallStage.INSTALLED; await f.store.save(f.job);
  f.state.setRunning(f.job.id, false);
  assert.equal(f.state.snapshot()[0].percent, 100);
});

test('late native progress cannot revive a completed or canceled task', async () => {
  const f = fixture();
  f.job.stage = f.InstallStage.INSTALLED; await f.store.save(f.job);
  f.state.installProgress(f.job.id, 'transfer', 1, 100);
  assert.equal(f.state.snapshot()[0].percent, 100);
  f.state.remove(f.job.id); f.state.installProgress(f.job.id, 'transfer', 50, 100);
  assert.equal(f.state.snapshot().length, 0);
});


test('switching the channel keeps the active task visible', async () => {
  const f = fixture(), { detail } = pages(f), d = detail();
  f.job.stage = f.InstallStage.DOWNLOADING; await f.store.save(f.job);
  f.state.setRunning(f.job.id, true); f.state.downloadProgress(f.job.id, 35, 100);
  assert.equal(d.downloadBusy, true); assert.equal(d.downloadPercent, 35);
  const original = d.selectedAsset;
  d.selectedAsset = { ...original, name: 'other.app', bundleName: 'com.other.app' };
  d.syncInstallTask(); assert.equal(d.downloadBusy, true); assert.equal(d.downloadPercent, 35);
  assert.equal(d.activeInstallId, f.job.id);
  d.selectedAsset = original; d.syncInstallTask();
  assert.equal(d.downloadBusy, true); assert.equal(d.downloadPercent, 35);
});

test('Detail submits another selected package to the shared FIFO without starting a parallel install', async () => {
  let queued = 0, downloaded = 0;
  const d = pageClass('Detail', ['downloadSelected'], {
    getContext: () => ({}), InstallStage: { QUEUED: 'QUEUED' },
    JobStore: { open: async () => ({ enqueue: async () => ({ id: 'new', stage: 'QUEUED' }) }) },
    InstallCoordinator: { recovered: () => { queued++; } },
    JobScheduler: { requestQueue: () => { queued++; return true; }, runDownload: () => { downloaded++; } },
    errorText: e => e.message
  });
  Object.assign(d, { selectedAsset: { name: 'other.hap', url: 'https://example.com/other.hap' }, app: { id: 42 },
    currentInstallTask: () => undefined, installButtonEnabled: () => true, notify() {}, syncInstallTask() {},
    resumeInstall: () => { throw Error('parallel installation'); } });
  await d.downloadSelected(); assert.equal(queued, 1); assert.equal(downloaded, 0);
});

test('confirmed installation releases even fresh packages, retaining identity and pending task inputs', async () => {
  const f = fixture({ '@kit.CoreFileKit': { fileIo: {
    accessSync: () => true, statSync: () => ({ size: 10 }) } } });
  const now = Date.now();
  const old = { ...f.job, id: 'old', stage: f.InstallStage.INSTALLED,
    updatedAt: now - 86400001, cachePath: '/sandbox/install-jobs/old.hap', signedPath: '/sandbox/install-jobs/old.signed.hap' };
  const recent = { ...old, id: 'recent', updatedAt: now,
    cachePath: '/sandbox/install-jobs/new.hap', signedPath: '/sandbox/install-jobs/new.signed.hap' };
  const pending = { ...old, id: 'pending', stage: f.InstallStage.DOWNLOADING };
  const journal = [], saved = [];
  f.store.listAll = async () => [old, recent, pending];
  f.store.rememberCancelledFiles = async job => journal.push({ ...job });
  f.store.save = async job => saved.push({ ...job }); f.store.cleanupCancelled = async () => {};
  await f.store.pruneCompleted({ filesDir: '/sandbox' });
  assert.deepEqual(journal.map(j => j.id), ['recent', 'old']);
  assert.equal(journal[1].cachePath, '/sandbox/install-jobs/old.hap');
  assert.equal(saved[0].cachePath, ''); assert.equal(saved[0].stage, f.InstallStage.INSTALLED);
  assert.equal(saved[0].bundleName, f.job.bundleName);
  assert.equal(recent.cachePath, '');
  assert.equal(pending.cachePath, '/sandbox/install-jobs/old.hap');
});

test('an empty preview disables installation even when the app is already installed', () => {
  const f = fixture(), d = pages(f).detail();
  d.showPreviewReleases = true; d.selectedAsset = { name: '', bundleName: '', versionCode: 0 };
  d.installedJobs = [{ bundleName: 'test.bundle', versionCode: 9 }];
  assert.equal(d.installButtonLabel(), '暂无预览版本'); assert.equal(d.installButtonEnabled(), false);
});
test('channel changes allow higher builds and open installed builds at or above the channel latest', () => {
  const f = fixture(), d = pages(f).detail();
  d.installedVersion = 10; d.installedUnknown = false;
  d.installedJobs = [{ bundleName: 'test.bundle', versionCode: 8 }];
  for (const preview of [false, true]) {
    d.showPreviewReleases = preview;
    d.selectedAsset.versionCode = 11; assert.equal(d.updateAvailable(), true);
    assert.equal(d.installButtonEnabled(), true); assert.equal(d.installButtonLabel(), '更新到 2');
    d.selectedAsset.versionCode = 10; assert.equal(d.installButtonLabel(), '打开应用');
    assert.equal(d.installButtonEnabled(), true);
    d.selectedAsset.versionCode = 9; assert.equal(d.installButtonLabel(), '打开应用');
    assert.equal(d.installButtonEnabled(), true); assert.equal(d.updateAvailable(), false);
  }
  d.installedUnknown = true; d.selectedAsset.versionCode = 7;
  d.releases = [{ prerelease: true, assets: [{ bundleName: 'test.bundle', versionCode: 9 }] }];
  assert.equal(d.installButtonEnabled(), false, 'unknown system state falls back to the recorded internal build');
});

test('a local task waiting in the FIFO is queued, not falsely paused or failed', async () => {
  const f = localFixture(), ui = pages(f).local();
  f.job.stage = f.InstallStage.QUEUED; await f.store.save(f.job);
  assert.equal(ui.timeline.status, '排队中');
  assert.equal(ui.timeline.tone, 'normal');
  assert.equal(ui.timeline.running, false);
  f.state.unsubscribe(ui.subscription);
});

test('a burst of byte progress preserves published job identity and does not serialize or reorder metadata', async () => {
  const f = fixture(), { index } = pages(f);
  f.job.stage = f.InstallStage.DOWNLOADING;
  f.state.publish(f.job); f.state.setRunning(f.job.id, true);
  const before = f.state.snapshot()[0], pending = index.pendingJobs;
  const revision = f.state.jobRevision(), serializations = f.stats.serializations;
  // Simulate a runner mutation that has not been saved yet.
  f.job.versionName = 'unsaved';
  for (let bytes = 1; bytes <= 1000; bytes++) f.state.downloadProgress(f.job.id, bytes, 1000);
  assert.equal(f.stats.serializations, serializations);
  assert.equal(f.state.jobRevision(), revision);
  assert.equal(index.pendingJobs, pending);
  assert.equal(f.state.snapshot()[0].job, before.job);
  assert.notEqual(f.state.snapshot()[0], before);
  assert.equal(before.percent, 0); // historical progress is immutable
  assert.equal(f.state.snapshot()[0].percent, 100);
  assert.notEqual(f.state.snapshot()[0].job.versionName, 'unsaved');
  f.state.publish(f.job);
  assert.notEqual(f.state.jobRevision(), revision);
  assert.notEqual(index.pendingJobs, pending);
  assert.equal(index.pendingJobs[0].versionName, 'unsaved');
});

test('cached task ordering updates on durable saves, seeding and deletion; snapshot arrays remain independent', () => {
  const f = fixture(), newer = { ...f.job, id: 'newer', updatedAt: f.job.updatedAt + 10 };
  f.state.seed([f.job, newer]);
  assert.equal(f.state.snapshot()[0].job.id, 'newer');
  const rows = f.state.snapshot(); rows.reverse();
  assert.equal(f.state.snapshot()[0].job.id, 'newer');
  f.job.updatedAt = newer.updatedAt + 10; f.state.publish(f.job);
  assert.equal(f.state.snapshot()[0].job.id, f.job.id);
  f.state.remove(f.job.id);
  assert.equal(f.state.snapshot()[0].job.id, 'newer');
});
