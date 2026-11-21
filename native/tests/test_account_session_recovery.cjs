const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { loadEts } = require('./load_ets.cjs');
const { FailureKind, InstallStage } = loadEts('jobs/InstallJob');
const failures = loadEts('data/ServiceFailure', { '../jobs/InstallJob': { FailureKind } });

function recovery() {
  const storage = new Map(), events = [];
  const { InstallAccountRecovery: bus } = loadEts('jobs/InstallAccountRecovery', {},
    { AppStorage: { setOrCreate: (key, value) => storage.set(key, value) } });
  const owner = bus.subscribe(id => events.push(id)); bus.activate(owner);
  return { bus, storage, events };
}
function accountFixture(response = { responseCode: 200, result: JSON.stringify({ userInfo: { userId: 'u' } }) }) {
  const f = recovery();
  const model = loadEts('data/DeveloperAccount');
  f.account = model.DeveloperAccount.fromJson({ userId: 'u', teamId: 't', jwtToken: 'old', accessToken: 'a' });
  f.current = f.account; f.requests = 0; f.writes = 0; f.allowed = true;
  f.session = { load: async () => f.current, save: async (_context, account) => { f.current = account; f.writes++; } };
  const privacy = { isBusinessAllowed: () => f.allowed, assertBusinessAllowed: () => { if (!f.allowed) throw Error('consent revoked'); } };
  const login = loadEts('data/DevEcoLogin', {
    './DeveloperAccount': model, './PrivacyConsent': { PrivacyConsent: privacy },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST' }, createHttp: () => ({
      destroy() {}, request: async () => { f.requests++; if (f.gate) await f.gate; return response; }
    }) } }
  });
  f.service = loadEts('data/AccountService', {
    './DeveloperAccount': { AccountSession: f.session }, './DevEcoLogin': login,
    './PrivacyConsent': { PrivacyConsent: privacy }, './ServiceFailure': failures,
    '../jobs/InstallJob': { FailureKind }, '../jobs/InstallAccountRecovery': { InstallAccountRecovery: f.bus }
  }).AccountService;
  f.service.configure({});
  return f;
}
test('incomplete Huawei userInfo from backup/certificate refresh opens one foreground prompt without an install job', async () => {
  const f = accountFixture();
  const errors = await Promise.allSettled([f.service.refresh(f.account, true),
    f.service.refresh(f.account, true), f.service.refresh(f.account, true)]);
  for (const row of errors) {
    assert.equal(row.status, 'rejected'); assert.equal(row.reason.failureKind, FailureKind.ACCOUNT);
    assert.match(row.reason.message, /华为账号返回的信息不完整/);
  }
  assert.equal(f.requests, 1); assert.equal(f.writes, 0);
  assert.equal(f.storage.get('accountReauthRequired'), true);
  const request = f.events.at(-1);
  assert.equal(f.bus.isSession(request), true); assert.equal(f.bus.scope(request), '["u","t"]');
  f.bus.request('waiting-install', '["u","t"]');
  assert.equal(f.events.filter(id => id).length, 1, 'parallel install failures share the existing prompt');
});
test('network errors and HTTP 403 do not ask for re-login; HTTP 401 does', async () => {
  for (const status of [401, 403, 503]) {
    const f = accountFixture({ responseCode: status, result: '' });
    await assert.rejects(f.service.refresh(f.account, true));
    assert.equal(f.events.filter(Boolean).length, status === 401 ? 1 : 0);
    assert.equal(f.storage.get('accountReauthRequired') === true, status === 401);
    assert.equal(f.writes, 0);
  }
});
test('late failures cannot prompt after logout, account switch, a newer login or privacy withdrawal', async () => {
  for (const change of ['logout', 'other-user', 'new-token', 'privacy']) {
    const f = accountFixture(); let release; f.gate = new Promise(resolve => { release = resolve; });
    const work = f.service.refresh(f.account, true); const rejected = assert.rejects(work);
    if (change === 'logout') f.current = undefined;
    if (change === 'other-user') f.current = { ...f.account, userId: 'other' };
    if (change === 'new-token') f.current = { ...f.account, jwtToken: 'new' };
    if (change === 'privacy') f.allowed = false;
    release(); await rejected;
    assert.equal(f.events.filter(Boolean).length, 0, change);
    assert.equal(f.writes, 0);
  }
});
test('dismissing retains reauth status and can transfer to another visible page; success resolves both', () => {
  const f = recovery(); f.bus.requestSession('["u","t"]'); const id = f.events.at(-1);
  const second = []; const owner = f.bus.subscribe(id => second.push(id)); f.bus.activate(owner);
  assert.equal(second.at(-1), id); assert.equal(f.events.at(-1), '');
  f.bus.clear(id); assert.equal(f.storage.get('accountReauthRequired'), true);
  f.bus.requestSession('["u","t"]'); f.bus.resolved();
  assert.equal(second.at(-1), ''); assert.equal(f.storage.get('accountReauthRequired'), false);
});

function promptFixture(job = false) {
  const f = recovery(); f.old = { userId: 'u', teamId: 't', jwtToken: 'old' };
  f.fresh = { ...f.old, jwtToken: 'new' }; f.current = f.old; f.writes = 0; f.jobReads = 0; f.resume = [];
  f.task = { id: 'job-1', stage: InstallStage.WAITING_ACCOUNT, lastError: 'expired' };
  if (job) f.bus.request(f.task.id, '["u","t"]'); else f.bus.requestSession('["u","t"]');
  const source = fs.readFileSync(`${__dirname}/../entry/src/main/ets/components/InstallAccountPrompt.ets`, 'utf8');
  const start = source.indexOf('  private async login()'), end = source.indexOf('\n  build()', start);
  const box = { getContext: () => ({}), InstallAccountRecovery: f.bus, InstallStage,
    PrivacyConsent: { assertBusinessAllowed() {} }, I18n: { t: x => x }, errorText: String,
    DevEcoLogin: { login: async () => { if (f.loginGate) await f.loginGate; return f.fresh; } },
    AccountSession: { load: async () => f.current, save: async (_context, account) => { f.writes++; f.current = account; } },
    JobStore: { open: async () => { f.jobReads++; return { get: async () => f.task, save: async task => { f.savedTask = task; } }; } },
    InstallCoordinator: { run: async (_context, id) => f.resume.push(id),
      conditionReady: async (_context, stage) => f.resume.push(stage) } };
  vm.runInNewContext(ts.transpileModule(`class Prompt { ${source.slice(start, end)} };globalThis.Prompt=Prompt;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  f.prompt = Object.assign(new box.Prompt(), { jobId: f.events.at(-1), busy: false, disposed: false, message: '' });
  return f;
}
test('session re-login saves the same account and resumes waiting work without fabricating a queue job', async () => {
  const f = promptFixture(); await f.prompt.login();
  assert.equal(f.current.jwtToken, 'new'); assert.equal(f.writes, 1); assert.equal(f.jobReads, 0);
  assert.deepEqual(f.resume, [InstallStage.WAITING_ACCOUNT]); assert.equal(f.prompt.busy, false);
  assert.equal(f.storage.get('accountReauthRequired'), false);
});
test('wrong-account login leaves credentials and waiting installs unchanged', async () => {
  const f = promptFixture(); f.fresh = { userId: 'other', teamId: 'different', jwtToken: 'new' };
  await f.prompt.login(); assert.equal(f.current, f.old); assert.equal(f.writes, 0);
  assert.equal(f.jobReads, 0); assert.deepEqual(f.resume, []);
  assert.match(f.prompt.message, /请登录原华为开发者账号/); assert.equal(f.storage.get('accountReauthRequired'), true);
});
test('logout while the browser is authorizing discards its late result', async () => {
  const f = promptFixture(); let release; f.loginGate = new Promise(resolve => { release = resolve; });
  const work = f.prompt.login(); f.current = undefined; f.bus.resolved(); release(); await work;
  assert.equal(f.writes, 0); assert.equal(f.jobReads, 0); assert.deepEqual(f.resume, []);
});
test('the original job-specific re-login still resumes exactly the paused task', async () => {
  const f = promptFixture(true); await f.prompt.login();
  assert.equal(f.writes, 1); assert.equal(f.savedTask.stage, InstallStage.QUEUED);
  assert.equal(f.savedTask.lastError, ''); assert.deepEqual(f.resume, ['job-1']);
});

test('a cloud backup session error keeps local certificate state and offers actionable copy instead of raw Error wrappers', async () => {
  const f = recovery();
  const source = fs.readFileSync(`${__dirname}/../entry/src/main/ets/pages/Index.ets`, 'utf8');
  const start = source.indexOf('  private async syncIdentityToCloud('),
    end = source.indexOf('\n  /** 读取账号下所有调试证书', start);
  assert.ok(start >= 0 && end > start);
  const box = { InstallAccountRecovery: f.bus, PrivacyConsent: { isBusinessAllowed: () => true },
    CloudBackupConsent: { allowed: async () => true }, fileIo: { readTextSync: () => 'fixture-local-key' },
    StoreClient: class { async publishSigningIdentity() { throw Error('Error: 华为账号返回的信息不完整'); } },
    errorText: String, I18n: { t: x => x } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${source.slice(start, end)} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Page(), { account: { userId: 'u' }, certId: 'cert', certReady: true,
    certLabel: 'existing-certificate', certExpiry: '2027-10-08', backupWarning: '' });
  const result = await page.syncIdentityToCloud({}, { accountId: 'u', certId: 'cert', privateKeyPath: '/local-key' });
  assert.equal(result, false); assert.equal(page.certReady, true); assert.equal(page.certId, 'cert');
  assert.equal(page.certLabel, 'existing-certificate'); assert.equal(page.certExpiry, '2027-10-08');
  assert.match(page.backupWarning, /请重新登录/); assert.match(page.backupWarning, /本机签名材料已保留/);
  assert.doesNotMatch(page.backupWarning, /Error:/);
});
test('completed re-login reloads the root account; background refresh does not replace the page with the login gate on known session errors', async () => {
  const source = fs.readFileSync(`${__dirname}/../entry/src/main/ets/pages/Index.ets`, 'utf8');
  const start = source.indexOf('  private onAccountReauthChanged()'), end = source.indexOf('\n  private async login()', start);
  const f = recovery();
  const box = { PrivacyConsent: { isBusinessAllowed: () => true }, InstallAccountRecovery: f.bus,
    AccountService: { configure() {}, refresh: async () => { throw { failureKind: FailureKind.ACCOUNT,
      toString: () => 'Error: 华为账号返回的信息不完整' }; } }, FailureKind, I18n: { t: x => x }, errorText: String };
  vm.runInNewContext(ts.transpileModule(`class Page { ${source.slice(start, end)} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  let reloads = 0; const saved = { userId: 'u' };
  const page = Object.assign(new box.Page(), { account: saved, signedIn: true, accountChecked: true, loginBusy: false,
    accountReauthRequired: true, restoreAccount: () => reloads++ });
  page.onAccountReauthChanged(); assert.equal(reloads, 0);
  await page.refreshRestoredAccount(saved, {});
  assert.equal(page.signedIn, true); assert.equal(page.account, saved); assert.match(page.sessionNotice, /需要重新核验/);
  page.accountReauthRequired = false; page.onAccountReauthChanged(); assert.equal(reloads, 1);
  page.loginBusy = true; page.onAccountReauthChanged(); assert.equal(reloads, 1, 'direct sign-in already updates the root account');
});
