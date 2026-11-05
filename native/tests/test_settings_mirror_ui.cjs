const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
const source = fs.readFileSync(path.join(root, 'pages/Settings.ets'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function method(name) {
  const start = source.search(new RegExp('^  (?:@Builder )?(?:private )?(?:async )?' + name + '\\(', 'm'));
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const defaults = source.match(/MIRROR_DEFAULTS: string\[\] = (\[[^\n]+\]);/)[1];
function fixture() {
  const f = { disk: { enabled: false, address: '' }, writes: [], probes: [], timers: new Map(), routes: [], dialogs: [] };
  let timerId = 0;
  const timeout = (callback, delay) => { const id = ++timerId; f.timers.set(id, { callback, delay }); return id; };
  class Setting { enabled = false; address = ''; }
  const prefs = {
    normalize(value) {
      if (!value) return '';
      if (!/^https:\/\/[^\s?#]+$/.test(value)) throw Error('invalid address');
      return value.endsWith('/') ? value : value + '/';
    },
    load: async () => ({ ...f.disk }),
    save: async (_ctx, setting) => { f.writes.push({ ...setting }); f.disk = { ...setting }; return { ...setting }; }
  };
  class Probe {
    cancel() {}
    check(_ctx, address) {
      let resolve;
      const promise = new Promise(done => resolve = done);
      f.probes.push({ address, resolve }); return promise;
    }
  }
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data/GitHubMirrorEditor.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => ({
    './GitHubMirrorPreferences': { GitHubMirrorPreferences: prefs, GitHubMirrorSetting: Setting },
    './GitHubMirrorProbe': { GitHubMirrorProbe: Probe }
  })[name], setTimeout: timeout, clearTimeout: id => f.timers.delete(id) });
  const names = ['aboutToAppear', 'aboutToDisappear', 'onPageHide', 'back', 'openMirrorChoices',
    'editMirrorAddress', 'selectMirrorChoice', 'mirrorChoiceSelected', 'toggleMirror', 'mirrorStatusLabel',
    'mirrorIssueAvailable', 'showMirrorIssue'];
  const box = { ...exports, DownloadProxyPreferences:{load:async()=>({enabled:false})}, DownloadProxyProbe:class{cancel(){}}, Curve: { EaseInOut: 'ease-in-out' }, Settings: { MIRROR_DEFAULTS: vm.runInNewContext(defaults) },
    getContext: () => ({ filesDir: '/sandbox' }), PrivacyConsent: { isManaged: () => false, unsubscribe() {} },
    bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
      getBundleInfoForSelf: async () => ({ versionName: '0.4.58', versionCode: 10 }) },
    StorePageMotion: { prepare() {} }, router: { back: route => f.routes.push(route.url) },
    promptAction: { showDialog: async options => {
      f.dialogs.push(options); if (f.dialogWait) await f.dialogWait; return { index: 0 };
    } },
    setTimeout: timeout, clearTimeout: id => f.timers.delete(id) };
  vm.runInNewContext(ts.transpileModule('class Page {' + names.map(method).join('\n') +
    '};globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  f.ui = Object.assign(new box.Page(), { mirror: new exports.GitHubMirrorView(), visible: true,
    mirrorChoicesOpen: false, privacySubscription: -1, backTimer: -1,
    mirrorIssueOpen: false, colors: () => ({ accent: '#007DFF' }),
    readCache() {}, getUIContext: () => ({ animateTo: (_opts, action) => action() }) });
  f.defaults = Array.from(box.Settings.MIRROR_DEFAULTS);
  f.load = async () => { f.ui.aboutToAppear(); await tick(); };
  f.debounce = async () => {
    const pending = [...f.timers.values()]; f.timers.clear(); pending.forEach(item => item.callback()); await tick();
  };
  return f;
}

test('default candidates never prefill or enable the mirror and only open for a visible enabled editor', async () => {
  const f = fixture(); await f.load();
  assert.deepEqual(f.defaults, ['https://gh-proxy.org/', 'https://ghfast.top/']);
  f.ui.openMirrorChoices(); f.ui.selectMirrorChoice(f.defaults[0]);
  assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.ui.mirror.address, '');
  assert.equal(f.disk.enabled, false); assert.equal(f.writes.length, 0); assert.equal(f.probes.length, 0);
  f.ui.toggleMirror(); await tick(); f.ui.openMirrorChoices(); assert.equal(f.ui.mirrorChoicesOpen, true);
});

test('selecting a candidate fills via the real editor and waits for its existing 600 ms save and check', async () => {
  const f = fixture(); await f.load(); f.ui.toggleMirror(); await tick();
  f.ui.openMirrorChoices(); const writes = f.writes.length;
  f.ui.selectMirrorChoice(f.defaults[1]);
  assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.ui.mirror.address, f.defaults[1]);
  assert.equal(f.ui.mirror.enabled, true); assert.equal(f.writes.length, writes); assert.equal(f.probes.length, 0);
  assert.equal(f.timers.size, 1); assert.equal([...f.timers.values()][0].delay, 600);
  assert.equal(f.ui.mirrorChoiceSelected('https://ghfast.top/'), true);
  await f.debounce(); assert.equal(f.disk.address, f.defaults[1]); assert.equal(f.probes.length, 1);
  assert.equal(f.ui.mirrorStatusLabel(), '正在检验镜像连接');
  f.probes[0].resolve({ state: 'success', message: '通过' }); await tick();
  assert.equal(f.ui.mirrorStatusLabel(), '镜像连接检查通过');
});

test('custom input replaces the candidate without enabling the switch or leaving an obsolete pending check', async () => {
  const f = fixture(); await f.load(); f.ui.toggleMirror(); await tick();
  f.ui.openMirrorChoices(); f.ui.selectMirrorChoice(f.defaults[0]);
  f.ui.openMirrorChoices(); f.ui.editMirrorAddress('https://custom.example/proxy');
  assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.timers.size, 1);
  assert.equal(f.ui.mirrorChoiceSelected(f.defaults[0]), false);
  await f.debounce(); assert.equal(f.disk.address, 'https://custom.example/proxy/');
  assert.equal(f.probes.length, 1); assert.equal(f.probes[0].address, 'https://custom.example/proxy/');
  f.probes[0].resolve({ state: 'warning', message: '失败，自动回退' }); await tick();
  assert.match(f.ui.mirrorStatusLabel(), /未确认.*自动回退/);
});

test('the first Back closes candidates, while hide, disable and disposal cannot retain or reopen them', async () => {
  const f = fixture(); await f.load(); f.ui.toggleMirror(); await tick(); f.ui.openMirrorChoices();
  f.ui.back(); assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.ui.visible, true); assert.equal(f.routes.length, 0);
  f.ui.openMirrorChoices(); f.ui.toggleMirror(); await tick(); assert.equal(f.ui.mirrorChoicesOpen, false);
  f.ui.toggleMirror(); await tick(); f.ui.openMirrorChoices(); f.ui.onPageHide();
  assert.equal(f.ui.mirrorChoicesOpen, false); f.ui.openMirrorChoices(); assert.equal(f.ui.mirrorChoicesOpen, false);
  f.ui.visible = true; f.ui.openMirrorChoices(); f.ui.aboutToDisappear();
  assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.ui.mirrorEditor, undefined);
  f.ui.openMirrorChoices(); f.ui.selectMirrorChoice(f.defaults[0]); assert.equal(f.ui.mirrorChoicesOpen, false);
});

test('all status states use the input slot and explanation is available only from its transparent issue button', () => {
  const row = method('githubMirrorRow'), status = method('mirrorInputStatus');
  const stack = row.slice(row.indexOf('Stack({ alignContent: Alignment.End })'), row.indexOf(".id('settings-github-mirror-input')"));
  assert.match(stack, /TextInput\(/); assert.match(stack, /this\.mirrorInputStatus\(\)/);
  assert.match(stack, /padding\(\{ left: 12, right: 48 \}\)/);
  assert.match(status, /width\(36\)\.height\(44\)/);
  assert.match(status, /this\.mirror\.checking/); assert.match(status, /this\.mirror\.state === 'success'/);
  assert.match(status, /this\.mirror\.state === 'warning'/); assert.match(status, /questionmark_circle/);
  assert.match(status, /accessibilityText\(this\.mirrorStatusLabel\(\)/);
  assert.match(status, /Button\(\{ type: ButtonType.Normal \}\)/);
  assert.match(status, /backgroundColor\(Color.Transparent\)/);
  assert.match(status, /enabled\(this\.mirrorIssueAvailable\(\)\)/);
  assert.match(status, /onClick\(\(\) => \{ this\.showMirrorIssue\(\); \}\)/);
  assert.doesNotMatch(row, /Text\(this\.mirror\.message\)|settings-github-mirror-result/);
  assert.doesNotMatch(row, /\.onBlur\(/, 'losing input focus must not remove the option before its tap reaches it');
  assert.match(row, /\.onFocus\(\(\) => this\.openMirrorChoices\(\)\)/);
  const choices = method('mirrorDefaultChoices');
  assert.match(choices, /this\.colors\(\)\.surface/); assert.match(choices, /this\.colors\(\)\.text/);
  assert.match(choices, /mirrorChoiceSelected\(address\)/); assert.match(choices, /maxLines\(1\)/);
});

test('warning and unconfirmed icons reveal the actual message once; normal states and stale pages cannot open dialogs', async () => {
  const f = fixture(); assert.equal(f.ui.mirrorStatusLabel(), '尚未填写镜像地址');
  f.ui.mirror.ready = true; f.ui.mirror.enabled = true;
  f.ui.mirror.address = f.defaults[0]; assert.equal(f.ui.mirrorStatusLabel(), '镜像连接尚未确认');
  f.ui.mirror.state = 'success'; f.ui.mirror.checking = true;
  assert.equal(f.ui.mirrorStatusLabel(), '正在检验镜像连接');
  f.ui.mirror.message = '已有结果';
  for (const state of ['idle', 'success', 'warning', 'unconfirmed']) {
    f.ui.mirror.state = state;
    assert.equal(f.ui.mirrorIssueAvailable(), false, 'checking must suppress an older issue');
    await f.ui.showMirrorIssue();
  }
  f.ui.mirror.checking = false;
  for (const state of ['idle', 'success']) {
    f.ui.mirror.state = state; assert.equal(f.ui.mirrorIssueAvailable(), false);
    await f.ui.showMirrorIssue();
  }
  f.ui.mirror.state = 'warning'; f.ui.mirror.message = '';
  assert.equal(f.ui.mirrorIssueAvailable(), false); await f.ui.showMirrorIssue();
  assert.equal(f.dialogs.length, 0);
  f.ui.mirror.message = '连接检查未通过（HTTP 403），下载时自动回退';
  assert.match(f.ui.mirrorStatusLabel(), /自动回退/); assert.equal(f.ui.mirrorIssueAvailable(), true);
  f.ui.mirrorChoicesOpen = true;
  let finish; f.dialogWait = new Promise(resolve => finish = resolve);
  const open = f.ui.showMirrorIssue(); await tick();
  assert.equal(f.ui.mirrorChoicesOpen, false); assert.equal(f.ui.mirrorIssueOpen, true);
  await f.ui.showMirrorIssue(); assert.equal(f.dialogs.length, 1);
  assert.equal(f.dialogs[0].title, '镜像状态'); assert.equal(f.dialogs[0].message, f.ui.mirror.message);
  assert.equal(f.dialogs[0].buttons.length, 1); assert.equal(f.dialogs[0].buttons[0].text, '知道了');
  finish(); await open; f.dialogWait = undefined; assert.equal(f.ui.mirrorIssueOpen, false);
  f.ui.mirror.state = 'unconfirmed'; f.ui.mirror.message = '地址格式有效，下载时检验';
  await f.ui.showMirrorIssue(); assert.equal(f.dialogs.length, 2); assert.equal(f.dialogs[1].message, f.ui.mirror.message);
  for (const [key, value] of [['disposed', true], ['visible', false], ['returning', true]]) {
    const previous = f.ui[key]; f.ui[key] = value; await f.ui.showMirrorIssue(); f.ui[key] = previous;
  }
  assert.equal(f.dialogs.length, 2); assert.equal(f.ui.mirrorIssueOpen, false);
});
