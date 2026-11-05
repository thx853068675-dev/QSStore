const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const actions = loadEts('data/ManagementActions', { '../jobs/InstallJob': loadEts('jobs/InstallJob') });
const names = ['restoreUpdatePolicy', 'onUpdatePolicyChanged', 'toggleInstalledUpdates', 'installedActions', 'showInstalledActions'];
const code = ts.transpileModule('class Page {' + names.map(name => {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}).join('\n') + '};globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
function fixture() {
  const f = { disabled: new Set(), writes: [], reads: 0, updates: 0, rows: 0, managementRows: 0, toasts: [], renewals: [] };
  const box = { ...actions, getContext: () => ({ filesDir: '/sandbox' }), errorText: e => e.message,
    promptAction: { showToast: ({ message }) => f.toasts.push(message) },
    AlertDialog: { show: value => f.confirm = value },
    UpdatePolicy: { disabled: bundle => f.disabled.has(bundle),
      restore: async () => { f.reads++; if (f.readWait) await f.readWait; if (f.readError) throw Error('read failed'); },
      setDisabled: async (_ctx, bundle, on) => {
        f.writes.push({ bundle, on }); if (f.writeWait) await f.writeWait;
        if (f.writeError) throw Error('disk full');
        if (on) f.disabled.add(bundle); else f.disabled.delete(bundle);
        f.ui.updatePolicyRevision++; f.ui.onUpdatePolicyChanged();
      } }
  };
  vm.runInNewContext(code, box);
  f.job = { bundleName: 'com.example.offline', appId: 0 }; f.installed = [f.job];
  f.ui = Object.assign(new box.Page(), { updatePolicyReady: false, updatePolicyChanging: [],
    updatePolicyRevision: 0, updatePolicyProjectedRevision: -1, uninstallingBundle: '',
    allInstalledJobs: () => f.installed, jobTitle: () => '离线应用', renewalButtonLabel: () => '手动续签',
    checkInstalledUpdates: () => f.updates++, syncDiscoverRows: () => f.rows++,
    syncManagementRows: () => f.managementRows++,
    renewInstalled: job => f.renewals.push(job), openInstalledInformation: job => f.information = job });
  return f;
}
test('cold policy restoration coalesces, blocks premature projection, then publishes only the local update view', async () => {
  const f = fixture(); let finish; f.readWait = new Promise(done => finish = done);
  const first = f.ui.restoreUpdatePolicy(); const second = f.ui.restoreUpdatePolicy();
  f.ui.onUpdatePolicyChanged(); assert.equal(f.ui.updatePolicyReady, false); assert.equal(f.updates, 0);
  finish(); await Promise.all([first, second]);
  assert.equal(f.reads, 1); assert.equal(f.ui.updatePolicyReady, true);
  assert.equal(f.updates, 1); assert.equal(f.rows, 1);
  await f.ui.restoreUpdatePolicy(); assert.equal(f.reads, 1);
});
test('failed restoration remains safely unknown and can retry without treating saved rules as empty', async () => {
  const f = fixture(); f.readError = true; await f.ui.restoreUpdatePolicy();
  assert.equal(f.ui.updatePolicyReady, false); assert.equal(f.updates, 0);
  assert.match(f.ui.jobsError, /更新设置读取失败.*read failed/);
  f.readError = false; await f.ui.restoreUpdatePolicy();
  assert.equal(f.reads, 2); assert.equal(f.ui.updatePolicyReady, true); assert.equal(f.updates, 1);
});
test('offline swipe policy changes publish only after durable save and duplicate taps cannot reverse a pending choice', async () => {
  const f = fixture(); await f.ui.restoreUpdatePolicy(); let finish;
  f.writeWait = new Promise(done => finish = done);
  const saving = f.ui.showInstalledActions(f.job, 'stopUpdates'); await new Promise(setImmediate);
  assert.deepEqual(Array.from(f.ui.installedActions(f.job), item => item.shortLabel), ['信息', '续签', '停更', '卸载']);
  assert.equal(f.disabled.size, 0);
  await f.ui.showInstalledActions(f.job, 'stopUpdates'); assert.equal(f.writes.length, 1);
  finish(); await saving;
  assert.equal(f.disabled.has(f.job.bundleName), true); assert.equal(f.ui.updatePolicyChanging.length, 0);
  assert.deepEqual(Array.from(f.ui.installedActions(f.job), item => item.shortLabel), ['信息', '续签', '续更', '卸载']);
  assert.equal(f.updates, 2, 'the storage watcher and completion callback project once per revision');
  assert.equal(f.managementRows, 2, 'the pause badge must update even if the app already has no available update');
  await f.ui.showInstalledActions(f.job, 'resumeUpdates'); assert.equal(f.disabled.size, 0);
  assert.equal(f.updates, 3);
});
test('save failure preserves the active update policy and provides a retry instead of changing renewal or uninstall state', async () => {
  const f = fixture(); await f.ui.restoreUpdatePolicy(); f.writeError = true;
  await f.ui.showInstalledActions(f.job, 'stopUpdates');
  assert.equal(f.disabled.size, 0); assert.equal(f.updates, 1); assert.equal(f.ui.updatePolicyChanging.length, 0);
  assert.match(f.toasts[0], /保存失败.*disk full/);
  await f.ui.showInstalledActions(f.job, 'renew'); assert.equal(f.renewals.length, 1);
  await f.ui.showInstalledActions(f.job, 'uninstall'); assert.ok(f.confirm);
});
test('stale policy actions cannot affect an application removed before selection', async () => {
  const f = fixture(); f.installed = [];
  await f.ui.showInstalledActions(f.job, 'stopUpdates'); assert.equal(f.writes.length, 0);
});
test('policy UI uses valid system symbols and lazy signatures without adding long press, scans or requests', () => {
  const resources = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js').sys.symbol;
  assert.ok(resources.pause_circle); assert.ok(resources.arrow_clockwise);
  assert.match(source, /@StorageProp\('updatePolicyRevision'\) @Watch\('onUpdatePolicyChanged'\)/);
  const initialize = source.slice(source.indexOf('  private initializeBusiness()'), source.indexOf('\n  }', source.indexOf('  private initializeBusiness()')));
  assert.ok(initialize.indexOf('restoreUpdatePolicy()') < initialize.indexOf('loadJobs()'));
  const projection = source.slice(source.indexOf('  private onUpdatePolicyChanged()'), source.indexOf('\n  }', source.indexOf('  private onUpdatePolicyChanged()')));
  assert.doesNotMatch(projection, /scan|refreshCatalogInstallState|loadApps|StoreClient|Hdc/);
  assert.match(source, /String\(UpdatePolicy\.disabled\(job\.bundleName\)\)/);
  assert.match(source, /String\(UpdatePolicy\.disabled\(asset\.bundleName\)\)/);
  const card = source.slice(source.indexOf('  private managementInstalledCards('), source.indexOf('  private managementSectionToggle('));
  assert.match(card, /\.background\(this\.installedUpdatePausedBackground\(job\)/);
  assert.doesNotMatch(card, /LongPressGesture|onLongPress/);
  assert.match(source, /UpdatePolicy\.disabled\(this\.catalogBundleName\(app\.id\)\) \? I18n\.t\('已停更'\) : I18n\.t\('安装\/更新'\)/);
});
