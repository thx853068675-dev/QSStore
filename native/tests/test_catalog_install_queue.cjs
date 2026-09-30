const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const methods = ['queueTime', 'drainInstallQueue', 'installFromCatalog', 'catalogApp'].map(name => {
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

test('multiple Discover clicks enqueue immediately and install strictly in FIFO order', async () => {
  const jobs = [];
  const starts = [];
  let releaseFirst;
  const firstGate = new Promise(resolve => { releaseFirst = resolve; });
  let tick = 0;
  const store = {
    async enqueue(id, name, url, sha, mirrors, versionName, bundleName, versionCode) {
      const job = { id: String(id), appId: id, stage: 'QUEUED', stageHistory: [{ at: ++tick }],
        updatedAt: tick, catalogBundleName: bundleName };
      jobs.push(job);
      return job;
    },
    async listAll() { return jobs.slice().reverse(); },
    async get(id) { return jobs.find(job => job.id === id); }
  };
  const sandbox = {
    InstallStage: { QUEUED: 'QUEUED', INSTALLED: 'INSTALLED' },
    LocalBundles: { isSelfBundle: () => false },
    JobStore: { open: async () => store }, getContext: () => ({}), errorText: String,
    JobScheduler: { runDownload: async (_context, _store, job) => {
      starts.push(job.appId);
      if (job.appId === 1) await firstGate;
      job.stage = 'PACKAGE_INSPECTED';
    } }
  };
  vm.runInNewContext(code, sandbox);
  const ui = new sandbox.Page();
  Object.assign(ui, { apps: [app(1), app(2), app(3)], updateCatalogReady: false,
    enqueuingAppIds: [], queueRecoveryReady: true, queueDraining: false,
    activeJobId: '', signedIn: true, taskPending: () => false,
    updateApps() { return this.apps; },
    installedVersionOf: () => 0, loadJobs: async () => {},
    async continueInstall(job) { job.stage = 'INSTALLED'; } });

  await ui.installFromCatalog(ui.apps[0]);
  await eventually(() => starts.length === 1);
  await ui.installFromCatalog(ui.apps[1]);
  await ui.installFromCatalog(ui.apps[2]);
  assert.equal(jobs.length, 3);
  assert.deepEqual(starts, [1]);
  assert.equal(jobs[1].stage, 'QUEUED');
  assert.equal(jobs[2].stage, 'QUEUED');
  releaseFirst();
  await eventually(() => jobs.every(job => job.stage === 'INSTALLED'));
  assert.deepEqual(starts, [1, 2, 3]);
});
