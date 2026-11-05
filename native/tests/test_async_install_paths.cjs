const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

async function checkpoint() {
  await new Promise(resolve => setImmediate(resolve));
}

// Real Runtime -> AssetDownload -> JobRunner planning; only platform directory
// authorization and the later signing/device operations are deterministic adapters.
function fixture(assetName = 'example.hap') {
  const jobModule = loadEts('jobs/InstallJob');
  const cancellation = loadEts('jobs/JobCancellation');
  const recovery = loadEts('jobs/RecoveryPlanner', { './InstallJob': jobModule });
  const runnerModule = loadEts('jobs/JobRunner', {
    './InstallJob': jobModule, './RecoveryPlanner': recovery,
    './JobCancellation': cancellation,
    './JobScheduler': { JobScheduler: { runInstall: (_id, work) => work() } }
  });
  const calls = { directories: 0, mkdir: [], saves: [], failures: [], events: [] };
  let directoryGate = deferred();
  const assetModule = loadEts('jobs/AssetDownload', {
    './JobCancellation': cancellation,
    './DownloadLibrary': { DownloadLibrary: { directory: async () => {
      calls.directories++;
      await directoryGate.promise;
      return '/storage/Users/currentUser/Download/轻启·安装器';
    } } },
    '@kit.CoreFileKit': { fileIo: {
      accessSync: () => false, mkdirSync: directory => calls.mkdir.push(directory)
    } }
  });
  const runtimeModule = loadEts('jobs/NativeJobRuntime', {
    './AssetDownload': assetModule, './JobRunner': runnerModule,
    './InstallJob': jobModule, './JobCancellation': cancellation
  });
  const context = { filesDir: '/sandbox' };
  const job = jobModule.InstallJob.create('async-path-job', 7, assetName,
    'https://github.com/owner/repo/releases/download/v1.0.0/' + assetName, 'a'.repeat(64));
  const store = {
    get: async () => job,
    save: async value => calls.saves.push({ ...value }),
    recordFailure: async (value, kind, message) => {
      calls.failures.push({ kind, message });
      value.stage = recovery.stageForFailure(kind);
      value.lastError = message;
    }
  };
  const runtime = new runtimeModule.NativeJobRuntime(context, store, undefined, {});
  let installed = false;
  runtime.inspectEvidence = async value => {
    assert.ok(value.cachePath.length > 0 && value.signedPath.length > 0);
    assert.equal(calls.saves[0].cachePath, value.cachePath);
    calls.events.push('inspect');
    return new jobModule.RecoveryEvidence();
  };
  runtime.downloadAndVerify = async value => {
    assert.match(value.cachePath, /^\/sandbox\/install-jobs\//);
    calls.events.push('download');
  };
  runtime.inspectPackage = async () => ({ bundleName: 'com.example.app', versionCode: 7 });
  runtime.ensureProfile = runtime.sign = runtime.verifySignature = async () => {};
  runtime.ensureDevice = async () => true;
  runtime.installedVersion = async () => installed ? 7 : 0;
  runtime.confirmReplacement = async () => installed;
  runtime.install = async value => {
    assert.match(value.signedPath, /^\/sandbox\/install-jobs\/.+\.signed\.(hap|app)$/);
    calls.events.push('install');
    installed = true;
  };
  runtime.rememberInstalledAuthorization = async () => {};
  return { job, calls, runtime, cancellation, jobModule,
    runner: new runnerModule.JobRunner(store, runtime),
    gate: () => directoryGate, nextGate: () => directoryGate = deferred() };
}

test('real runtime waits for public-directory initialization before returning private HAP/APP install paths', async () => {
  for (const extension of ['hap', 'app']) {
    const f = fixture('example.' + extension);
    let settled = false;
    const pending = f.runtime.planPaths(f.job).then(value => { settled = true; return value; });
    await checkpoint();
    assert.equal(settled, false, 'planning must not return empty paths while authorization is pending');
    assert.equal(f.job.cachePath, ''); assert.equal(f.job.signedPath, '');
    assert.deepEqual(f.calls.mkdir, []);
    f.gate().resolve();
    const paths = await pending;
    assert.equal(paths.cachePath, '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.' + extension);
    assert.equal(paths.signedPath, '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.signed.' + extension);
    assert.equal(paths.cachePath, f.job.cachePath); assert.equal(paths.signedPath, f.job.signedPath);
    assert.deepEqual(f.calls.mkdir, ['/sandbox/install-jobs']);
  }
});

test('real runner persists valid paths before advancing and plans only once after delayed authorization', async () => {
  const f = fixture();
  const pending = f.runner.run(f.job.id);
  await checkpoint();
  assert.equal(f.job.stage, f.jobModule.InstallStage.QUEUED);
  assert.deepEqual(f.calls.saves, []); assert.deepEqual(f.calls.events, []);
  assert.deepEqual(f.calls.failures, []);
  f.gate().resolve();
  const result = await pending;
  assert.equal(result.stage, f.jobModule.InstallStage.INSTALLED);
  assert.equal(f.calls.directories, 1);
  assert.deepEqual(f.calls.events, ['inspect', 'download', 'install']);
  assert.deepEqual(f.calls.failures, []);
  assert.ok(f.calls.saves.every(value => value.cachePath.length > 0 && value.signedPath.length > 0));
});

test('directory rejection is awaited by runtime and journaled by runner without late path writes; retry uses one fresh plan', async () => {
  const direct = fixture();
  const rejection = assert.rejects(direct.runtime.planPaths(direct.job), /directory authorization denied/);
  direct.gate().reject(new Error('directory authorization denied'));
  await rejection;
  assert.equal(direct.job.cachePath, ''); assert.equal(direct.job.signedPath, '');
  assert.deepEqual(direct.calls.mkdir, []);

  const f = fixture();
  const pending = f.runner.run(f.job.id);
  await checkpoint();
  f.gate().reject(new Error('directory authorization denied'));
  const failed = await pending;
  await checkpoint(); // Unhandled planning rejections fail node:test, including after the runner resolves.
  assert.equal(failed.stage, f.jobModule.InstallStage.RETRYABLE_ERROR);
  assert.match(failed.lastError, /directory authorization denied/);
  assert.equal(f.calls.failures.length, 1);
  assert.doesNotMatch(failed.lastError, /安装工作目录无效/);
  assert.equal(f.job.cachePath, ''); assert.equal(f.job.signedPath, '');
  assert.deepEqual(f.calls.events, []); assert.deepEqual(f.calls.mkdir, []);
  f.nextGate();
  const retry = f.runner.run(f.job.id);
  await checkpoint();
  assert.equal(f.calls.directories, 2); assert.deepEqual(f.calls.saves, []);
  f.gate().resolve();
  assert.equal((await retry).stage, f.jobModule.InstallStage.INSTALLED);
  assert.equal(f.calls.directories, 2, 'retry must not start an extra path plan in the download step');
  assert.equal(f.calls.failures.length, 1);
});

test('cancelled real runner cannot persist paths or start installation after pending authorization completes', async () => {
  const f = fixture();
  const rejection = assert.rejects(f.runner.run(f.job.id), /安装任务已取消/);
  await checkpoint();
  f.cancellation.JobCancellation.cancel(f.job.id);
  f.gate().resolve();
  await rejection;
  assert.equal(f.job.cachePath, ''); assert.equal(f.job.signedPath, '');
  assert.deepEqual(f.calls.saves, []); assert.deepEqual(f.calls.failures, []);
  assert.deepEqual(f.calls.mkdir, []); assert.deepEqual(f.calls.events, []);
});
