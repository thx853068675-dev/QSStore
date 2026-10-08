const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function sourceMethods(file, names, globals = {}) {
  const source = fs.readFileSync(path.join(root, 'pages', file + '.ets'), 'utf8');
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { AppStorage: { setOrCreate() {} }, ForegroundIdle: { cancel() {} },
    displayVersion: load('data/DisplayVersion').displayVersion, ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return new box.Page();
}
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {} });
  return exports;
}
function fixture() {
  const { InstallReconnect } = load('jobs/InstallReconnect');
  const { InstallConfirmation } = load('jobs/InstallConfirmation');
  const make = file => {
    const page = sourceMethods(file, ['animateOverlay', 'observeReconnect', 'onPageHide'].concat(file === 'Index' ? ['cancelResumeMaintenance'] : []), {
      clearTimeout, InstallReconnect, InstallConfirmation, Curve: { EaseOut: 'ease-out' }
    });
    Object.assign(page, { homeVisibility: { visible: true }, managementRowsTimer: -1, reconnectSubscription: -1, confirmationSubscription: -1, resumeJobId: '', reconnectJobId: '',
      resumeMaintenancePending: false, reconnectMessage: '', showReconnect: false,
      getUIContext: () => ({ animateTo: (_options, change) => change() }) });
    return page;
  };
  return { state: InstallReconnect, index: make('Index'), detail: make('Detail') };
}
test('install started in Discover requests connection in the already opened Detail page', () => {
  const f = fixture(); f.index.observeReconnect();
  f.index.onPageHide(); f.detail.observeReconnect();
  f.state.request('job-1');
  assert.equal(f.index.showReconnect, false);
  assert.equal(f.detail.showReconnect, true);
  assert.equal(f.detail.reconnectJobId, 'job-1');
});
test('an existing connection sheet follows navigation, and connection completion closes the old sheet', () => {
  const f = fixture(); f.index.observeReconnect(); f.state.request('job-1');
  assert.equal(f.index.showReconnect, true);
  f.index.onPageHide(); f.detail.observeReconnect();
  assert.equal(f.index.showReconnect, false); assert.equal(f.detail.showReconnect, true);
  f.state.clear('job-1'); assert.equal(f.detail.showReconnect, false);
  f.detail.onPageHide(); f.index.observeReconnect();
  assert.equal(f.index.showReconnect, false);
});
test('a request in the navigation gap is retained, but a dismissed request does not reappear', () => {
  const f = fixture(); f.index.observeReconnect(); f.index.onPageHide();
  f.state.request('job-1'); f.detail.observeReconnect();
  assert.equal(f.detail.showReconnect, true);
  f.state.clear('job-1'); f.detail.onPageHide(); f.index.observeReconnect();
  assert.equal(f.index.showReconnect, false);
});
test('saved ports prefill both pages, but never overwrite text entered during the read', async () => {
  for (const name of ['Index', 'Detail']) {
    let resolve;
    const pending = new Promise(done => resolve = done);
    const ui = sourceMethods(name, ['onReconnectVisibilityChanged'], { getContext: () => ({}),
      HdcDeviceBridge: class { savedPort() { return pending; } } });
    ui.showReconnect = true; ui.reconnectPort = ''; ui.onReconnectVisibilityChanged();
    resolve(45678); await new Promise(setImmediate);
    assert.equal(ui.reconnectPort, '45678');
    ui.reconnectPort = ''; ui.onReconnectVisibilityChanged(); ui.reconnectPort = '54321';
    await new Promise(setImmediate); assert.equal(ui.reconnectPort, '54321');
  }
});
test('the extra history option loads another page without changing the selected release', () => {
  const ui = sourceMethods('Detail', ['releaseOptions', 'selectRelease']);
  ui.app = { secondaryRepo: '' };
  const { ReleaseInfo } = load('data/ReleaseInfo');
  ui.releases = [ReleaseInfo.fromJson({name:'v1',tag:'v1',published_at:'',prerelease:false})];
  ui.releaseTotal = 2; ui.selectedReleaseIndex = 0; let calls = 0;
  ui.loadMoreReleases = () => calls++;
  assert.equal(ui.releaseOptions()[1].value, '更多历史版本…');
  ui.selectRelease(1); assert.equal(calls, 1); assert.equal(ui.selectedReleaseIndex, 0);
});
test('hero size follows the selected HAP, and unknown historical sizes do not use the latest size', () => {
  const ui = sourceMethods('Detail', ['packageSizeLabel']);
  ui.app = { latestAsset: { size: 2 * 1024 * 1024 } };
  ui.selectedAsset = { url: '', size: 0 };
  assert.equal(ui.packageSizeLabel(), '安装包 2.0 MB');
  ui.selectedAsset = { url: 'https://repo/older.hap', size: 512 * 1024 };
  assert.equal(ui.packageSizeLabel(), '安装包 512 KB');
  ui.selectedAsset.size = 0;
  assert.equal(ui.packageSizeLabel(), '安装包大小待确认');
});
test('hero version uses the actual version name or selected release before falling back to the build code', () => {
  const ui = sourceMethods('Detail', ['selectedVersionLabel', 'currentRelease']);
  ui.selectedAsset = { versionName: '0.4.48', versionCode: 2026100102 };
  ui.releases = [{ tag: 'v0.4.48' }]; ui.selectedReleaseIndex = 0;
  assert.equal(ui.selectedVersionLabel(), '0.4.48');
  ui.selectedAsset.versionName = '';
  assert.equal(ui.selectedVersionLabel(), '0.4.48');
  ui.releases = []; ui.selectedAsset.versionCode = 0;
  assert.equal(ui.selectedVersionLabel(), '待确认');
});
