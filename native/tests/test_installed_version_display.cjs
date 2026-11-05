const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const jobs = loadEts('jobs/InstallJob');
const versions = loadEts('data/DisplayVersion');
const ReleaseUpdate = require('./release_update_fixture.cjs').releaseUpdate();
const { InstalledVersionDisplay } = loadEts('data/InstalledVersionDisplay', {
  './DisplayVersion': versions, '../jobs/ReleaseUpdate': { ReleaseUpdate }
});
const bundle = 'com.example.app', code = 1000000;
function receipt(extra = {}) {
  return { bundleName: bundle, versionCode: code, versionName: '1.0.0', releaseTag: 'v1.2.6',
    stage: jobs.InstallStage.INSTALLED, installedUpdateTime: 5000, updatedAt: 5500, ...extra };
}
function label(rows, time = 5000, name = '1.0.0', vc = code, selectedBundle = bundle) {
  return InstalledVersionDisplay.label(selectedBundle, vc, name, time, rows, '应用');
}
test('matching installed receipt displays its release label while manifest version remains raw', () => {
  const row = receipt(); assert.equal(label([row]), '1.2.6');
  assert.equal(row.versionName, '1.0.0'); assert.equal(row.versionCode, code);
});
test('wrong identity, code, completed state or install timestamp cannot present another release', () => {
  for (const row of [receipt({ bundleName: 'com.other.app' }), receipt({ versionCode: code + 1 }),
    receipt({ stage: jobs.InstallStage.DOWNLOADING }), receipt({ installedUpdateTime: 4000 })]) {
    assert.equal(label([row]), '1.0.0');
  }
  assert.equal(label([receipt()], 0), '1.0.0');
});
test('same-code external replacement with a changed manifest name invalidates release evidence', () => {
  assert.equal(label([receipt()], 5000, '1.0.1'), '1.0.1');
  assert.equal(label([receipt({ versionName: '' })], 5000, '1.0.1'), '1.0.1');
});
test('legacy receipts still require a real installation time within their completion window', () => {
  const row = receipt({ installedUpdateTime: 0 });
  assert.equal(label([row]), '1.2.6');
  assert.equal(label([row], 7600), '1.0.0');
  assert.equal(label([row], 0), '1.0.0');
});
test('installed selection carries separate presentation evidence and preserves raw version fields', () => {
  const { InstalledInspection } = loadEts('data/InstalledInspection', {
    './AppDisplayName': { AppDisplayName: { forBundle: (_bundle, title) => title } }
  });
  const selected = InstalledInspection.selection({ ...receipt(), sourceUrl: 'local', id: 'local',
    moduleName: 'entry', mainAbility: 'MainAbility' }, '应用', 7, '1.2.6', 5000);
  assert.equal(selected.versionName, '1.0.0'); assert.equal(selected.versionCode, code);
  assert.equal(selected.displayReleaseLabel, '1.2.6'); assert.equal(selected.displayReleaseVersionCode, code);
  assert.equal(selected.displayReleaseUpdateTime, 5000);
});

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/InstalledDetail.ets'), 'utf8');
const methods = ['aboutToAppear', 'read', 'refreshVersionLabel'].map(name => {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'));
  assert.notEqual(start, -1); return source.slice(start, source.indexOf('\n  }', start) + 4);
});
function page() {
  const state = { time: 5000, name: '1.0.0', rows: [receipt()], data: { name: bundle,
    versionCode: code, versionName: '1.0.0', updateTime: 5000 } };
  const box = { InstalledVersionDisplay, displayVersion: versions.displayVersion, getContext: () => ({}),
    setTimeout: () => 0, router: { getParams: () => ({ selection: JSON.stringify(state.selection) }) },
    InstalledInspection: { sections: data => data, read: async () => {
      if (state.readError) throw Error('offline'); return state.data;
    } },
    InstalledAppRegistry: { installationTime: () => state.time, signingIdentity: () => state.identity,
      versionName: () => state.name },
    JobStore: { open: async () => ({ listAll: async () => { if (state.wait) await state.wait; return state.rows; } }) }
  };
  vm.runInNewContext(ts.transpileModule('class Page { ' + methods.join('\n') + ' }; globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { info: { bundleName: bundle, title: '应用',
    versionCode: code, versionName: '1.0.0', displayReleaseLabel: '1.2.6',
    displayReleaseVersionCode: code, displayReleaseUpdateTime: 5000 }, versionLabel: '1.2.6',
    sections: [], displayReadRevision: 0, disposed: false, busy: false, initialRead: false,
    applySearch() {}, readRenewalExpiry() {}, readIcon() {} });
  return { ui, state };
}
test('fresh details reconcile the release header without replacing raw information', async () => {
  const f = page(); f.ui.versionLabel = '1.2.5'; await f.ui.read();
  assert.equal(f.ui.versionLabel, '1.2.6'); assert.equal(f.ui.info.versionName, '1.0.0');
  assert.equal(f.ui.sections.versionName, '1.0.0'); assert.equal(f.ui.sections.versionCode, code);
});
test('offline information read preserves the verified selection label', async () => {
  const f = page(); f.state.readError = true; await f.ui.read();
  assert.equal(f.ui.versionLabel, '1.2.6'); assert.match(f.ui.notice, /offline/);
});
test('fresh same-code external installation invalidates an old selected release by timestamp', async () => {
  const f = page(); f.state.time = 8000; f.state.data.updateTime = 8000; await f.ui.read();
  assert.equal(f.ui.versionLabel, '1.0.0');
});
test('changed raw name without a timestamp cannot reuse the old same-code receipt', async () => {
  const f = page(); f.state.data.versionName = '1.0.1'; delete f.state.data.updateTime;
  f.state.name = '1.0.1'; await f.ui.read(); assert.equal(f.ui.versionLabel, '1.0.1');
});
test('a missing raw timestamp falls back to the actual registry signing installation time', async () => {
  const f = page(); delete f.state.data.updateTime; f.state.time = 0; f.state.identity = { updateTime: 5000 };
  await f.ui.read(); assert.equal(f.ui.versionLabel, '1.2.6');
  const unknown = page(); delete unknown.state.data.updateTime; unknown.state.time = 0;
  await unknown.ui.read(); assert.equal(unknown.ui.versionLabel, '1.0.0');
});
test('a newer real version cannot be labelled by an old receipt or a catalog latest tag', async () => {
  const f = page(); f.state.data.versionCode = code + 1; f.state.data.versionName = '1.0.1';
  f.state.data.updateTime = 8000; f.state.time = 8000; f.state.name = '1.0.1';
  await f.ui.read(); assert.equal(f.ui.versionLabel, '1.0.1');
});
test('late history lookup cannot reinstate a release after a newer registry observation', async () => {
  const f = page(); let resolve; f.state.wait = new Promise(done => resolve = done);
  const read = f.ui.read(); await new Promise(setImmediate); f.state.time = 8000;
  resolve(); await read; assert.equal(f.ui.versionLabel, '1.0.0');
});
test('leaving during an asynchronous history read does not update the header', async () => {
  const f = page(); let resolve; f.state.wait = new Promise(done => resolve = done);
  const read = f.ui.read(); await new Promise(setImmediate); f.ui.disposed = true;
  f.ui.versionLabel = 'leaving'; resolve(); await read; assert.equal(f.ui.versionLabel, 'leaving');
});
test('initial selection rejects a display label carried with another installed version code', () => {
  const f = page(); f.state.selection = { ...f.ui.info, displayReleaseVersionCode: code - 1 };
  f.ui.read = () => {}; f.ui.aboutToAppear(); assert.equal(f.ui.versionLabel, '1.0.0');
});

function inspectionCache() {
  const state = { vc: code, time: 5000, name: '1.0.0', cached: { name: bundle,
    versionCode: code, versionName: '1.0.0', updateTime: 5000 } };
  const registry = { version: () => state.vc, installationTime: () => state.time,
    signingIdentity: () => state.identity, versionName: () => state.name };
  const { InstalledInspection } = loadEts('data/InstalledInspection', {
    '@kit.AbilityKit': { bundleManager: { getBundleInfoSync: () => { throw Error('201'); }, BundleFlag: {} } },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({ get: async () => JSON.stringify(state.cached) }) } },
    '../jobs/HdcDeviceBridge': { HdcDeviceBridge: class { connected() { return false; } } },
    '../jobs/InstalledAppRegistry': { InstalledAppRegistry: registry }
  });
  return { state, read: () => InstalledInspection.read({}, bundle) };
}
test('offline same-code cache is rejected after a different installation time or raw name is observed', async () => {
  const valid = inspectionCache(); assert.equal((await valid.read()).versionName, '1.0.0');
  const newer = inspectionCache(); newer.state.time = 8000; await assert.rejects(newer.read(), /保留已知安装信息/);
  const renamed = inspectionCache(); renamed.state.name = '1.0.1'; await assert.rejects(renamed.read(), /保留已知安装信息/);
});
