const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function fixture() {
  const modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {}; modules.set(name, exports);
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText, { exports, require: dep => load(path.posix.join(path.posix.dirname(name), dep)),
      setInterval: () => 1, clearInterval() {} });
    return exports;
  }
  const { InstallJob, InstallStage } = load('jobs/InstallJob');
  const { CatalogInstallIdentity } = load('jobs/CatalogInstallIdentity');
  const { InstallTaskState } = load('jobs/InstallTaskState');
  const f = { actual: -1, probes: [], identity: CatalogInstallIdentity, stage: InstallStage, state: InstallTaskState };
  f.record = Object.assign(new InstallJob(), { id: 'xhs-installed', appId: 41,
    bundleName: 'com.hmos.collection', assetName: 'collection-1.21.0-unsigned.hap',
    versionCode: 1000022, stage: InstallStage.INSTALLED, moduleName: 'entry', mainAbility: 'EntryAbility' });
  const source = fs.readFileSync(path.join(root, 'pages/Detail.ets'), 'utf8');
  const names = ['selectedBundleName', 'refreshInstalledVersion', 'installedForApp', 'updateAvailable',
    'selectedDowngrade', 'installButtonLabel', 'installButtonEnabled', 'observeInstallTasks',
    'currentInstallTask', 'syncInstallTask'];
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { InstallJob, InstallStage, CatalogInstallIdentity, InstallTaskState,
    ReleaseUpdate: load('jobs/ReleaseUpdate').ReleaseUpdate,
    InstalledAppRegistry: { versionName: () => '', signingIdentity: () => undefined },
    LocalBundles: { installedVersion: () => f.actual, isKnown: v => v >= 0 },
    isPending: load('jobs/RecoveryPlanner').isPending };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  f.ui = Object.assign(new box.Page(), { app: { id: 41 }, detailAppId: 41,
    selectedAsset: { name: f.record.assetName, bundleName: '', versionCode: 1000022, sha256: '' },
    installedJobs: [f.record], installTasks: [], installedVersion: 0, installedUnknown: false,
    releases: [], showPreviewReleases: false, downloadBusy: false, installSubscription: -1,
    confirmInstalledViaDevice: bundle => f.probes.push(bundle), selectedVersionLabel: () => '1.21.1', notify() {} });
  return f;
}
test('Detail opens a successfully installed HAP even before server package identity is enriched', () => {
  const f = fixture(); f.ui.refreshInstalledVersion();
  assert.equal(f.ui.selectedBundleName(), 'com.hmos.collection');
  assert.equal(f.ui.installedForApp().mainAbility, 'EntryAbility');
  assert.equal(f.ui.installButtonLabel(), '打开应用');
  assert.deepEqual(f.probes, ['com.hmos.collection']);
});
test('the successful task publication immediately changes an initially unknown Detail to open', () => {
  const f = fixture(); f.ui.installedJobs = []; f.ui.observeInstallTasks();
  f.ui.refreshInstalledVersion(); assert.equal(f.ui.installButtonLabel(), '安装/更新');
  f.state.publish(f.record);
  assert.equal(f.ui.installedForApp().bundleName, f.record.bundleName);
  assert.equal(f.ui.installButtonLabel(), '打开应用');
});
test('a confirmed uninstall defeats success history and switching to another HAP cannot borrow its identity', () => {
  const f = fixture(); f.actual = 0; f.ui.refreshInstalledVersion();
  assert.equal(f.ui.installedForApp(), undefined);
  assert.equal(f.ui.installButtonLabel(), '安装应用');
  f.actual = -1; f.ui.selectedAsset.name = 'different-app.hap'; f.ui.refreshInstalledVersion();
  assert.equal(f.ui.selectedBundleName(), '');
  assert.equal(f.ui.installButtonLabel(), '安装/更新');
});
test('after enrichment, a genuinely newer XHS package offers update; the same version opens', () => {
  const f = fixture(); f.actual = 1000022;
  f.ui.selectedAsset = { name: 'collection-1.21.1-unsigned.hap', bundleName: 'com.hmos.collection', versionCode: 1000023 };
  f.ui.refreshInstalledVersion(); assert.equal(f.ui.installButtonLabel(), '更新到 1.21.1');
  f.actual = 1000023; f.ui.refreshInstalledVersion();
  assert.equal(f.ui.installButtonLabel(), '打开应用');
});
test('only unique successful online records can recover an absent catalog identity', () => {
  const f = fixture(), record = f.record;
  for (const jobs of [[], [{ ...record, appId: 0 }], [{ ...record, stage: f.stage.INSTALLING }],
    [{ ...record, versionCode: 0 }], [record, { ...record, bundleName: 'com.other.app' }]]) {
    assert.equal(f.identity.bundle(41, undefined, jobs), '');
  }
  assert.equal(f.identity.bundle(41, undefined, [record]), record.bundleName);
  assert.equal(f.identity.bundle(41, { name: 'other.hap', bundleName: '' }, [record]), '');
  assert.equal(f.identity.bundle(41, { name: record.assetName, bundleName: '' }, [record]), record.bundleName);
  assert.equal(f.identity.bundle(41, { bundleName: 'com.actual.catalog' }, [record]), 'com.actual.catalog');
});
