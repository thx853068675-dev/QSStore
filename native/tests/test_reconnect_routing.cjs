const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
const tick = () => new Promise(setImmediate);
function sourceFor(file) {
  return fs.readFileSync(path.join(root, (file.includes('/') ? file : 'pages/' + file) + '.ets'), 'utf8');
}
function sourceMethods(file, names, globals = {}) {
  const source = sourceFor(file);
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  (?:private\\s+)?(?:async\\s+)?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    const parsed = ts.createSourceFile('method.ts', `class Page {\n${source.slice(start)}`, ts.ScriptTarget.ES2020, true);
    const method = parsed.statements[0].members[0];
    assert.ok(ts.isMethodDeclaration(method), name);
    return method.getText(parsed);
  });
  const box = { AppStorage: { setOrCreate() {} }, ForegroundIdle: { cancel() {} },
    ...load('data/DisplayVersion'), ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return new box.Page();
}
function portInputHandler(file, field) {
  const source = sourceFor(file);
  const callbacks = [...source.matchAll(/\.onChange\(/g)].map(match => {
    const parsed = ts.createSourceFile('callback.ts', `const input = ${source.slice(match.index + match[0].length)}`,
      ts.ScriptTarget.ES2020, true);
    const input = parsed.statements[0].declarationList.declarations[0].initializer;
    return ts.isArrowFunction(input) ? input.body.getText(parsed) : '';
  });
  const callback = callbacks.find(body => body.includes(`this.${field}`));
  assert.ok(callback, file + ' port input callback');
  const body = callback.startsWith('{') ? callback : `{ ${callback}; }`;
  const box = {};
  vm.runInNewContext(ts.transpileModule(`function input(value: string) ${body}; globalThis.input = input;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return box.input;
}
function portFixture(file, bridgeType) {
  const prompt = file === 'components/InstallPrompts';
  const reads = [];
  const HdcDeviceBridge = bridgeType || class {
    savedPort() {
      return new Promise((resolve, reject) => reads.push({ resolve, reject }));
    }
  };
  const ui = sourceMethods(file, [prompt ? 'restorePort' : 'onReconnectVisibilityChanged'], {
    getContext: () => ({}), HdcDeviceBridge
  });
  Object.assign(ui, prompt ? {
    active: true, showing: false, disposed: false, connecting: false, port: '45678',
    portReadGeneration: 0, portInputRevision: 0
  } : {
    showReconnect: false, reconnectBusy: false, reconnectPort: '45678',
    reconnectPortReadGeneration: 0, reconnectPortInputRevision: 0
  });
  const field = prompt ? 'port' : 'reconnectPort';
  const input = portInputHandler(file, field);
  return {
    ui, reads,
    get value() { return ui[field]; },
    open() {
      if (prompt) { ui.showing = true; return ui.restorePort(); }
      ui.showReconnect = true; return ui.onReconnectVisibilityChanged();
    },
    close() {
      if (prompt) ui.showing = false;
      else { ui.showReconnect = false; ui.onReconnectVisibilityChanged(); }
    },
    edit(value) { input.call(ui, value); },
    connecting() { ui[prompt ? 'connecting' : 'reconnectBusy'] = true; },
    async resolve(port, index = reads.length - 1) {
      assert.ok(reads[index], file + ' reads the latest saved port');
      reads[index].resolve(port); await tick();
    }
  };
}
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {} });
  return exports;
}
function fixture(remote=false) {
  const { InstallReconnect } = load('jobs/InstallReconnect');
  const { InstallConfirmation } = load('jobs/InstallConfirmation');
  const make = file => {
    const page = sourceMethods(file, ['animateOverlay', 'observeReconnect', 'onPageHide'].concat(file === 'Index' ? ['cancelResumeMaintenance'] : []), {
      clearTimeout, InstallReconnect, InstallConfirmation, PrivacyConsent:{isBusinessAllowed:()=>true}, getContext:()=>({}), JobStore:{open:async()=>({get:async()=>({installTarget:remote?'remote-device':''})})}, Curve: { EaseOut: 'ease-out' }
    });
    Object.assign(page, { homeVisibility: { visible: true }, managementRowsTimer: -1, reconnectSubscription: -1, confirmationSubscription: -1, resumeJobId: '', reconnectJobId: '',
      pageVisible:true,showMultiDevice:false,resumeMaintenancePending: false, reconnectMessage: '', showReconnect: false,
      getUIContext: () => ({ animateTo: (_options, change) => change() }) });
    return page;
  };
  return { state: InstallReconnect, index: make('Index'), detail: make('Detail') };
}
test('local signing routes a remote pause to device discovery and ignores a stale page read',async()=>{
  const {InstallReconnect}=load('jobs/InstallReconnect');
  let resolve,reads=0;
  const job=new Promise(done=>resolve=done);
  const page=sourceMethods('components/InstallPrompts',['prepareReconnect'],{
    getContext:()=>({}),InstallReconnect,DeviceInstallTarget:load('jobs/DeviceInstallTarget').DeviceInstallTarget,InstallStage:{WAITING_DEVICE:'waiting_device'},
    JobStore:{open:async()=>({get:async()=>job})}
  });
  Object.assign(page,{disposed:false,active:true,jobId:'',showing:false,remote:false,
    restorePort:()=>reads++});
  page.reconnectId=InstallReconnect.subscribe(()=>{});InstallReconnect.activate(page.reconnectId);
  InstallReconnect.request('remote');const opening=page.prepareReconnect('remote');
  resolve({stage:'waiting_device',installTarget:JSON.stringify({key:'a'.repeat(64),udid:'a'.repeat(64),host:'192.168.3.8',port:54321,name:'Phone',kind:'phone',apiVersion:26})});await opening;
  assert.equal(page.remote,true);assert.equal(page.showing,true);assert.equal(reads,0);
  page.active=false;await page.prepareReconnect('remote');assert.equal(page.showing,false);
});
test('install started in Discover requests connection in the already opened Detail page', async () => {
  const f = fixture(); f.index.observeReconnect();
  f.index.onPageHide(); f.detail.observeReconnect();
  f.state.request('job-1');await tick();
  assert.equal(f.index.showReconnect, false);
  assert.equal(f.detail.showReconnect, true);
  assert.equal(f.detail.reconnectJobId, 'job-1');
});
test('an existing connection sheet follows navigation, and connection completion closes the old sheet', async () => {
  const f = fixture(); f.index.observeReconnect(); f.state.request('job-1');await tick();
  assert.equal(f.index.showReconnect, true);
  f.index.onPageHide(); f.detail.observeReconnect();await tick();
  assert.equal(f.index.showReconnect, false); assert.equal(f.detail.showReconnect, true);
  f.state.clear('job-1'); assert.equal(f.detail.showReconnect, false);
  f.detail.onPageHide(); f.index.observeReconnect();
  assert.equal(f.index.showReconnect, false);
});
test('a request in the navigation gap is retained, but a dismissed request does not reappear', async () => {
  const f = fixture(); f.index.observeReconnect(); f.index.onPageHide();
  f.state.request('job-1'); f.detail.observeReconnect();await tick();
  assert.equal(f.detail.showReconnect, true);
  f.state.clear('job-1'); f.detail.onPageHide(); f.index.observeReconnect();
  assert.equal(f.index.showReconnect, false);
});
for (const file of ['Index', 'Detail', 'components/InstallPrompts']) {
  test(file + ' refreshes a nonempty previous port each time the connection sheet opens', async () => {
    const f = portFixture(file);
    f.open(); await f.resolve(54321);
    assert.equal(f.value, '54321');
    f.close(); f.open(); await f.resolve(56789);
    assert.equal(f.reads.length, 2);
    assert.equal(f.value, '56789');
  });
  test(file + ' ignores an unchanged initialization callback while the saved port is loading', async () => {
    const f = portFixture(file);
    f.open(); f.edit('45678'); await f.resolve(54321);
    assert.equal(f.value, '54321');
  });
  test(file + ' accepts a later read when the input echoes the current programmatic value', async () => {
    const f = portFixture(file);
    f.open(); await f.resolve(54321);
    f.edit('54321');
    f.close(); f.open(); f.edit('54321'); await f.resolve(56789);
    assert.equal(f.value, '56789');
  });
  test(file + ' clears a stale port after deactivation or an invalid saved value', async () => {
    for (const port of [0, 1023, 65536, 12345.5, NaN, Infinity]) {
      const f = portFixture(file);
      f.open(); await f.resolve(port);
      assert.equal(f.value, '', 'saved port ' + port);
    }
  });
  test(file + ' accepts both valid saved port boundaries', async () => {
    for (const port of [1024, 65535]) {
      const f = portFixture(file);
      f.open(); await f.resolve(port);
      assert.equal(f.value, String(port));
    }
  });
  test(file + ' preserves edits made while the saved port is loading', async () => {
    const f = portFixture(file);
    f.open(); f.edit('56789'); await f.resolve(54321);
    assert.equal(f.value, '56789');
  });
  test(file + ' preserves an intentional clear after an edit during the saved port read', async () => {
    const f = portFixture(file);
    f.open(); f.edit('56789'); f.edit(''); await f.resolve(54321);
    assert.equal(f.value, '');
  });
  test(file + ' rejects a late read from an earlier opening of the connection sheet', async () => {
    const f = portFixture(file);
    f.open(); f.close(); f.open();
    assert.equal(f.reads.length, 2);
    await f.resolve(56789, 1); await f.resolve(54321, 0);
    assert.equal(f.value, '56789');
  });
  test(file + ' ignores a saved port read completed after the sheet closes', async () => {
    const f = portFixture(file);
    f.open(); f.close(); await f.resolve(54321);
    assert.equal(f.value, '45678');
  });
  test(file + ' preserves the submitted port while a connection is running', async () => {
    const f = portFixture(file);
    f.open(); f.connecting(); await f.resolve(54321);
    assert.equal(f.value, '45678');
  });
  test(file + ' uses the last verified endpoint while a new fixed port is only saved', async () => {
    const settings = new Map([['port', 45678], ['fixed-config', '{}']]);
    const preference = { get: async (key, fallback) => settings.get(key) ?? fallback,
      put: async (key, value) => settings.set(key, value), flush: async () => {} };
    const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
      '@kit.ArkData': { preferences: { getPreferences: async () => preference } }
    });
    await new HdcDeviceBridge({}).saveFixedPortSettings({ enabled: true, port: 54321 });
    assert.equal(settings.get('port'), 45678);
    const f = portFixture(file, HdcDeviceBridge);
    f.open(); await tick();
    assert.equal(f.value, '45678');
    assert.equal(JSON.parse(settings.get('fixed-config')).port, 54321);
  });
}
test('InstallPrompts ignores a saved port read after losing prompt ownership or disposal', async () => {
  for (const state of ['active', 'disposed']) {
    const f = portFixture('components/InstallPrompts');
    f.open(); f.ui[state] = state === 'disposed'; await f.resolve(54321);
    assert.equal(f.value, '45678', state);
  }
});
test('the extra history option loads another page without changing the selected release', () => {
  const ui = sourceMethods('Detail', ['releaseOptions', 'releaseVersionLabel', 'selectRelease']);
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
test('hero version follows the selected release and retains the actual package version for installation', () => {
  const ui = sourceMethods('Detail', ['selectedVersionLabel', 'currentRelease']);
  ui.app = { displayName: '轻启·安装器' };
  ui.selectedAsset = { versionName: '0.4.48', versionCode: 2026100102 };
  ui.releases = [{ tag: 'v0.4.48' }]; ui.selectedReleaseIndex = 0;
  assert.equal(ui.selectedVersionLabel(), '0.4.48');
  ui.selectedAsset.versionName = '';
  assert.equal(ui.selectedVersionLabel(), '0.4.48');
  ui.releases = []; ui.selectedAsset.versionCode = 0;
  assert.equal(ui.selectedVersionLabel(), '待确认');
  ui.app.displayName = 'LNGA';
  ui.releases = [{ name: 'v1.2.5', tag: '1.2.6' }];
  ui.selectedAsset = { versionName: '1.0.0', versionCode: 1000000 };
  assert.equal(ui.selectedVersionLabel(), '1.2.6');
  assert.equal(ui.selectedAsset.versionName, '1.0.0');
  assert.equal(ui.selectedAsset.versionCode, 1000000);
});

test('a remote task opens device discovery on the visible page instead of connecting to this phone',async()=>{
 const f=fixture(true);f.index.observeReconnect();f.state.request('remote-task');await tick();
 assert.equal(f.index.showMultiDevice,true);assert.equal(f.index.showReconnect,false);
 f.index.onPageHide();f.detail.observeReconnect();await tick();
 assert.equal(f.index.showMultiDevice,false);assert.equal(f.detail.showMultiDevice,true);assert.equal(f.detail.showReconnect,false);
 f.state.clear('remote-task');assert.equal(f.detail.showMultiDevice,false);
});
