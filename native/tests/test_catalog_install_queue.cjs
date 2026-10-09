const { CatalogLookup } = require('./load_ets.cjs').loadEts('data/CatalogLookup');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const methods = ['catalogLookup', 'drainInstallQueue', 'installFromCatalog', 'catalogApp', 'startUpdate', 'assetForBundle', 'latestAssets'].map(name => {
  const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
});
const code = ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;

function app(id) {
  return { id, displayName: `应用${id}`, latestAsset: { bundleName: `app.${id}`,
    versionCode: id, versionName: String(id), name: `${id}.hap`,
    url: `https://example.com/${id}.hap`, sha256: String(id).repeat(64), mirrorUrls: [] } };
}

async function eventually(check) {
  for (let n = 0; n < 100; n++) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 2));
  }
  assert.fail('queue did not advance');
}

function coordinator(store, run) {
  const exports = {};
  const mocks = { './RecoveryPlanner': { retryDelayMs: () => 0 }, './LocalImport': { LocalImport: { cleanupOldPreviews: () => {} } }, './JobStore': { JobStore: { open: async () => store } },
    '../data/AccountService': { AccountService: { current: async () => ({ userId: 'u' }) } },
    './InstallJob': { InstallStage: { QUEUED: 'QUEUED', INSTALLED: 'INSTALLED' } },
    './LocalBundles': { LocalBundles: { isSelfBundle: () => false } },
    './JobScheduler': { JobScheduler: { isRunning: () => false, setQueueWakeup: () => {}, runningJobIds: () => [] } },
    './NativeJobRuntime': { NativeJobRuntime: class {} }, './HdcDeviceBridge': { HdcDeviceBridge: class {} },
    './JobRunner': { JobRunner: class { async run(id) { return run(await store.get(id)); } } } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/InstallCoordinator.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {} });
  return exports.InstallCoordinator;
}

test('multiple Discover clicks enqueue immediately; execution belongs to process FIFO', async () => {
  const jobs = [], starts = [];
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const store = { async enqueue(id, name, url, sha, mirrors, versionName, bundleName) {
    const job = { id: String(id), appId: id, sourceUrl: url, stage: 'QUEUED',
      stageHistory: [{ at: jobs.length + 1 }], catalogBundleName: bundleName };
    jobs.push(job); return job;
  }, listAll: async () => jobs.slice().reverse(), get: async id => jobs.find(j => j.id === id) };
  store.pruneCompleted = async () => {};
  const owner = coordinator(store, async job => {
    starts.push(job.appId); if (job.appId === 1) await gate;
    job.stage = 'INSTALLED'; return job;
  });
  const box = { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate({INSTALLED:'INSTALLED'}), InstalledAppRegistry: {versionName:()=>'',signingIdentity:()=>undefined}, CatalogPackageVariant: require('./load_ets.cjs').loadEts('data/CatalogPackageVariant').CatalogPackageVariant, CatalogLookup, ReleaseChannelRegistry: { apply: app => app }, InstallStage: { QUEUED: 'QUEUED', INSTALLED: 'INSTALLED' }, InstallCoordinator: owner, getContext: () => ({}), errorText: String,
    LocalBundles: { isSelfBundle: () => false }, JobStore: { open: async () => store } };
  vm.runInNewContext(code, box);
  const ui = new box.Page();
  Object.assign(ui, { apps: [app(1), app(2), app(3)], updateCatalogReady: false,
    enqueuingAppIds: [], queueRecoveryReady: true, signedIn: true,
    taskPending: () => false, updateApps() { return this.apps; },
    installedVersionOf: () => 0, loadJobs: async () => {} });
  await ui.installFromCatalog(ui.apps[0]); await eventually(() => starts.length === 1);
  await ui.installFromCatalog(ui.apps[1]); await ui.installFromCatalog(ui.apps[2]);
  assert.equal(jobs.length, 3); assert.deepEqual(starts, [1]);
  // Destroying the page cannot destroy its process-owned executor.
  ui.queueRecoveryReady = false;
  release(); await eventually(() => jobs.every(j => j.stage === 'INSTALLED'));
  assert.deepEqual(starts, [1, 2, 3]);
});

test('local and online packages share FIFO, while manual duplicate requests coalesce', async () => {
  const jobs = [{ id: 'local:test', appId: 0, sourceUrl: 'local', stage: 'QUEUED', stageHistory: [{ at: 1 }] },
    { id: 'online', appId: 1, sourceUrl: 'https://repo/app.hap', stage: 'QUEUED', stageHistory: [{ at: 2 }] }];
  const starts = [], store = { listAll: async () => jobs, get: async id => jobs.find(j => j.id === id) };
  store.pruneCompleted = async () => {};
  const owner = coordinator(store, async job => { starts.push(job.id); job.stage = 'INSTALLED'; return job; });
  const first = owner.run({}, jobs[0].id), duplicate = owner.run({}, jobs[0].id);
  assert.equal(first, duplicate); await first; await owner.recovered({});
  assert.deepEqual(starts, ['local:test', 'online']);
});

// A repository can publish independent bundles; Management must retain its selected target.
test('Management updates the secondary bundle even when the primary package is current', async () => {
  const primary = app(1);
  const helper = { ...primary.latestAsset, bundleName: 'com.example.helper', name: 'helper.hap',
    url: 'https://example.com/helper.hap', versionCode: 9 };
  primary.latestAssets = [primary.latestAsset, helper];
  const enqueued = [];
  const box = { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate({INSTALLED:'INSTALLED'}), InstalledAppRegistry: {versionName:()=>'',signingIdentity:()=>undefined}, CatalogPackageVariant: require('./load_ets.cjs').loadEts('data/CatalogPackageVariant').CatalogPackageVariant, CatalogLookup, ReleaseChannelRegistry: { apply: app => app }, InstallStage: { QUEUED: 'QUEUED', INSTALLED: 'INSTALLED' }, LocalBundles: { isSelfBundle: () => false, installedVersion: () => 8 },
    JobStore: { open: async () => ({ enqueue: async (...args) => enqueued.push(args) }) },
    getContext: () => ({}), errorText: String };
  vm.runInNewContext(code, box);
  const ui = new box.Page();
  Object.assign(ui, { apps: [primary], updateCatalogReady: false,
    enqueuingAppIds: [], installedJobs: [], signedIn: true, taskPending: () => false,
    updateApps() { return this.apps; }, installedVersionOf: () => 100,
    checkInstalledUpdates: () => {}, drainInstallQueue: () => {}, loadJobs: async () => {} });
  await ui.startUpdate({ bundleName: helper.bundleName },
    { appId: primary.id, bundleName: helper.bundleName, assetName: helper.name });
  assert.equal(enqueued.length, 1);
  assert.equal(enqueued[0][1], helper.name);
  assert.equal(enqueued[0][6], helper.bundleName);
});

test('Discover explicit reinstall requeues a completed journal at the tail instead of stalling', async () => {
  const chosen = app(1), job = { id: 'completed', stage: 'INSTALLED', stageHistory: [{ at: 1 }] };
  let saved = false;
  const box = { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate({INSTALLED:'INSTALLED'}), InstalledAppRegistry: {versionName:()=>'',signingIdentity:()=>undefined}, CatalogPackageVariant: require('./load_ets.cjs').loadEts('data/CatalogPackageVariant').CatalogPackageVariant, CatalogLookup, ReleaseChannelRegistry: { apply: app => app }, InstallStage: { QUEUED: 'QUEUED', INSTALLED: 'INSTALLED' },
    LocalBundles: { isSelfBundle: () => false }, getContext: () => ({}), errorText: String,
    JobStore: { open: async () => ({ enqueue: async () => job, save: async () => { saved = true; } }) } };
  vm.runInNewContext(code, box);
  const ui = new box.Page();
  Object.assign(ui, { apps: [chosen], updateCatalogReady: false, enqueuingAppIds: [],
    signedIn: true, taskPending: () => false, updateApps() { return this.apps; },
    installedVersionOf: () => 0, drainInstallQueue: () => {}, loadJobs: async () => {} });
  await ui.installFromCatalog(chosen);
  assert.equal(saved, true); assert.equal(job.stage, 'QUEUED'); assert.equal(job.stageHistory.length, 0);
});
