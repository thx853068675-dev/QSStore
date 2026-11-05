const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}, values = {}, transform = source => source) {
  mocks = {'../data/DownloadProxyPreferences':{DownloadProxyPreferences:{load:async()=>({enabled:false})}},...mocks};
  const exports = {};
  const source = transform(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'));
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, require: name => mocks[name] || {}, console, ...values });
  return exports;
}
class Failure extends Error { constructor(kind, message) { super(message); this.failureKind = kind; } }
function fixture(managed = true) {
  const f = { calls: [], result: 0, error: undefined, resultVersion: 7, resultId: 'privacy',
    links: [{ type: 1, id: 'privacy', versionCode: 7, url: 'https://example.com/privacy' }], callback: undefined };
  const api = {
    AppPrivacyMgmtType: { UNSUPPORTED: 0, FULL_MODE: 1 },
    AppPrivacyResultType: { DISAGREED: 0, FULL_MODE_AGREED: 1, REQUIRE_RESIGNING_VERSION_UPDATE: 2 },
    AppPrivacyLinkType: { PRIVACY_STATEMENT_LINK: 1, USER_AGREEMENT_LINK: 2 },
    AppPrivacyType: { PRIVACY_AGREEMENT: 1, USER_AGREEMENT: 2 },
    getAppPrivacyMgmtInfo() { f.calls.push('links'); if (f.error) throw f.error;
      return { type: f.type ?? 1, privacyInfo: f.links }; },
    getAppPrivacyResult() { f.calls.push('result'); return f.results ||
      [{ type: 1, id: f.resultId, versionCode: f.resultVersion, result: f.result }]; },
    requestAppPrivacyConsent() { f.calls.push('dialog'); return f.dialog ? f.dialog() : Promise.resolve({ results: [] }); },
    disableService() { f.calls.push('withdraw'); if (f.withdrawError) throw f.withdrawError; f.result = 0; }
  };
  f.privacy = load('data/PrivacyConsent', {
    '@kit.AppGalleryKit': { privacyManager: api }, '@kit.BasicServicesKit': { commonEventManager: {
      async createSubscriber() { f.calls.push('subscribe'); return {}; },
      subscribe(_subscriber, callback) { f.callback = callback; }
    } }, './ServiceFailure': { ServiceFailure: Failure }, '../jobs/InstallJob': { FailureKind: { ACCOUNT: 'account' } }
  }, {}, source => managed ? source.replace('export const INVITE_PRIVACY_MANAGED = false;',
    'export const INVITE_PRIVACY_MANAGED = true;') : source).PrivacyConsent;
  return f;
}
function toggle() {
  const f = { allowed: true, listener: undefined };
  f.privacy = { isManaged: () => true, isBusinessAllowed: () => f.allowed,
    assertBusinessAllowed() { if (!f.allowed) throw new Failure('account', 'consent required'); },
    subscribe(fn) { f.listener = fn; return 1; }, unsubscribe() { f.listener = undefined; } };
  return f;
}
const turn = () => new Promise(setImmediate);

test('public build preserves business behavior without consulting or subscribing to hosted privacy', async () => {
  const f = fixture(false), p = f.privacy;
  p.configure({}); assert.equal(p.isManaged(), false); assert.equal(p.refresh(), true);
  assert.equal(await p.ensureConsent({}), true); p.withdraw(); p.assertBusinessAllowed();
  assert.equal(p.isBusinessAllowed(), true); assert.equal(p.links().length, 0); assert.deepEqual(f.calls, []);
});
test('managed startup blocks until the current privacy ID and version are explicitly agreed', () => {
  const f = fixture(), p = f.privacy;
  assert.equal(p.isBusinessAllowed(), false); assert.equal(p.refresh(), false);
  assert.throws(() => p.assertBusinessAllowed(), error => error.failureKind === 'account');
  f.result = 1; assert.equal(p.refresh(), true);
  f.resultVersion = 6; assert.equal(p.refresh(), false);
  f.resultVersion = 7; f.resultId = 'another-privacy'; assert.equal(p.refresh(), false);
});
test('requires-resigning value 2 never passes a truthiness check and malformed current metadata stays blocked', () => {
  const f = fixture(); f.result = 2; assert.equal(f.privacy.refresh(), false);
  f.result = 1; f.links[0].versionCode = NaN; assert.equal(f.privacy.refresh(), false);
  f.links[0].versionCode = 7; f.links[0].url = 'http://example.com'; assert.equal(f.privacy.refresh(), false);
  f.links = []; assert.equal(f.privacy.refresh(), false);
});
test('configured user agreements must also match current IDs and versions, unrelated rows cannot authorize them', () => {
  const f = fixture(); f.links.push({ type: 2, id: 'terms', versionCode: 3, url: 'https://example.com/terms' });
  f.results = [{ type: 1, id: 'privacy', versionCode: 7, result: 1 }];
  assert.equal(f.privacy.refresh(), false);
  f.results.push({ type: 2, id: 'terms', versionCode: 3, result: 1 }); assert.equal(f.privacy.refresh(), true);
  f.results[1].result = 0; assert.equal(f.privacy.refresh(), false);
});
test('missing hosted service 1006700003 never becomes consent; an actual corrected configuration can recover', () => {
  const f = fixture(); f.error = { code: 1006700003 };
  assert.equal(f.privacy.refresh(), false); assert.equal(f.privacy.links().length, 0);
  f.error = undefined; f.result = 1; assert.equal(f.privacy.refresh(), true);
});
test('official dialog requests coalesce and its returned data does not override an unsigned authoritative state', async () => {
  const f = fixture(); let resolve;
  f.dialog = () => new Promise(done => { resolve = done; });
  const one = f.privacy.ensureConsent({}), two = f.privacy.ensureConsent({});
  assert.equal(one, two); assert.equal(f.calls.filter(item => item === 'dialog').length, 1);
  resolve({ results: [{ type: 1, id: 'privacy', versionCode: 7, result: 1 }] });
  assert.equal(await one, false);
  f.dialog = async () => { f.result = 1; }; assert.equal(await f.privacy.ensureConsent({}), true);
});
test('withdrawing during an official dialog prevents its late result from reopening business', async () => {
  const f = fixture(); let resolve;
  f.dialog = () => new Promise(done => { resolve = done; });
  const request = f.privacy.ensureConsent({}); f.privacy.withdraw(); f.result = 1;
  resolve({ results: [] }); assert.equal(await request, false);
  assert.equal(f.privacy.refresh(), false);
  f.dialog = async () => { f.result = 1; }; assert.equal(await f.privacy.ensureConsent({}), true);
});
test('failed system withdrawal still stops business locally until an explicit new consent request', async () => {
  const f = fixture(); f.result = 1; f.privacy.refresh(); f.withdrawError = Error('offline');
  assert.throws(() => f.privacy.withdraw()); assert.equal(f.privacy.refresh(), false);
  f.withdrawError = undefined; assert.equal(await f.privacy.ensureConsent({}), true);
});
test('system event refreshes this app actual agreement state rather than trusting the broadcast result', async () => {
  const f = fixture(), p = f.privacy; let notifications = 0;
  p.subscribe(() => { notifications++; }); p.subscribe(() => { throw Error('disposed observer'); });
  p.configure({}); await turn(); assert.equal(typeof f.callback, 'function');
  f.callback(undefined, { data: '{"resultType":1}' }); assert.equal(p.isBusinessAllowed(), false);
  f.result = 1; f.callback(); assert.equal(p.isBusinessAllowed(), true); assert(notifications >= 1);
});

test('external file grants remain pending while blocked and enter preview after consent', async () => {
  const f = toggle(), routes = []; f.allowed = false;
  const open = load('jobs/ExternalInstallOpen', {
    '../data/PrivacyConsent': { PrivacyConsent: f.privacy },
    './LocalImport': { LocalImport: { supportsName: () => true } },
    '@kit.ArkUI': { router: { getState: () => ({ path: 'pages/Index', name: 'Index' }), RouterMode: { Single: 1 } } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    '../theme/StorePageMotion': { StorePageMotion: { pushUrl: async options => routes.push(options) } }
  }, { AppStorage: { setOrCreate() {} } }).ExternalInstallOpen;
  assert.equal(open.receive({ uri: 'file://sender/example.hap' }), true);
  open.openPending(); assert.equal(open.take(), ''); assert.equal(routes.length, 0);
  f.allowed = true; open.openPending(); await turn(); assert.equal(routes.length, 1);
  assert.equal(open.take(), 'file://sender/example.hap');
});
test('queued HDC commands stop before native dispatch after revocation, while an in-flight atomic commit completes', async () => {
  const f = toggle(); let resolve, calls = 0;
  const Bridge = load('jobs/HdcDeviceBridge', {
    '../data/PrivacyConsent': { PrivacyConsent: f.privacy },
    'libhap_core.so': { hdcCommand() { calls++; return new Promise(done => { resolve = done; }); } }
  }).HdcDeviceBridge;
  const bridge = new Bridge({ filesDir: '/sandbox' });
  const committing = bridge.command(11, 'staged'); await turn();
  const queued = bridge.command(6); f.allowed = false; resolve('success');
  assert.equal(await committing, 'success'); await assert.rejects(queued, error => error.failureKind === 'account');
  assert.equal(calls, 1); assert.equal(Bridge.busy(), false);
});
test('AGC and developer-login requests cannot dispatch before consent or consume late responses after withdrawal', async () => {
  const f = toggle(); let calls = 0, resolve;
  const http = { RequestMethod: { GET: 0, POST: 1 }, createHttp() { return {
    request() { calls++; return new Promise(done => { resolve = done; }); }, destroy() {}
  }; } };
  const shared = { '@kit.NetworkKit': { http }, './PrivacyConsent': { PrivacyConsent: f.privacy },
    './ServiceFailure': { ServiceFailure: Failure }, '../jobs/InstallJob': { FailureKind: { ACCOUNT: 'account' } } };
  const Agc = load('data/AgcClient', shared).AgcClient;
  const Login = load('data/DevEcoLogin', shared).DevEcoLogin;
  f.allowed = false;
  await assert.rejects(new Agc({}).certificates(), error => error.failureKind === 'account');
  await assert.rejects(Login.requestJson('https://example.com', 0, {}), error => error.failureKind === 'account');
  assert.equal(calls, 0);
  f.allowed = true; const request = new Agc({}).certificates(); f.allowed = false;
  resolve({ responseCode: 200, result: '{"ret":{"code":0},"certList":[]}' });
  await assert.rejects(request, error => error.failureKind === 'account'); assert.equal(calls, 1);
});
test('withdrawing a live download pauses its agent and preserves the partial package and journal for consent recovery', async () => {
  const f = toggle(); let paused = 0, started = 0, removed = 0, deleted = 0;
  const state = { RUNNING: 1, WAITING: 2, RETRYING: 3, INITIALIZED: 4, PAUSED: 5, FAILED: 6,
    STOPPED: 7, COMPLETED: 8, REMOVED: 9 };
  const task = { tid: 'existing', config: { url: 'https://example.com/a.hap', saveas: '/cache.hap.part' },
    async pause() { paused++; }, async start() { started++; } };
  const Download = load('jobs/AssetDownload', {
    '../data/PrivacyConsent': { PrivacyConsent: f.privacy },
    '@kit.BasicServicesKit': { request: { agent: { State: state, async getTask() { return task; },
      async show() { return { progress: { state: state.RUNNING, sizes: [100], processed: 10 } }; },
      async remove() { removed++; } } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, unlinkSync() { deleted++; } } },
    './JobCancellation': { JobCancellation: { assertActive() {} } }
  }, { setTimeout: callback => { f.allowed = false; f.listener?.(); callback(); } }).AssetDownload;
  const job = { id: 'one', transferTaskId: 'existing', sourceUrl: task.config.url,
    cachePath: '/cache.hap', expectedSha256: '' };
  await assert.rejects(new Download({}, { async save() {} }).downloadCurrentSource(job),
    error => error.failureKind === 'account');
  assert(paused > 0); assert.equal(started, 0); assert.equal(removed, 0); assert.equal(deleted, 0);
  assert.equal(job.transferTaskId, 'existing'); assert.equal(f.listener, undefined);
});

test('system package scans stay unknown without consent and late replies cannot mutate reliable installation evidence', async () => {
  const f = toggle(); let calls = 0, writes = 0, resolve;
  const manager = { BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
    async getBundleInfoForSelf() { calls++; return { name: 'com.example.installer', versionCode: 56 }; },
    getBundleInfo() { calls++; return new Promise(done => { resolve = done; }); } };
  const registry = { observationRevision: () => 0, rememberApplicationInfo() { writes++; return true; } };
  const Bundles = load('jobs/LocalBundles', {
    '../data/PrivacyConsent': { PrivacyConsent: f.privacy },
    '@kit.AbilityKit': { bundleManager: manager }, './InstalledAppRegistry': { InstalledAppRegistry: registry }
  }).LocalBundles;
  f.allowed = false; assert.equal((await Bundles.liveInstalledState('com.example.app')).versionCode, -1);
  assert.equal(calls, 0); assert.equal(writes, 0);
  f.allowed = true; const pending = Bundles.liveInstalledState('com.example.app'); await turn();
  f.allowed = false; resolve({ name: 'com.example.app', versionCode: 2, versionName: '2' });
  assert.equal((await pending).versionCode, -1); assert.equal(writes, 0);
});
