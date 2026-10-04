const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, require: dep => mocks[dep] || {}, setTimeout, clearTimeout });
  return exports;
}
const { FailureKind } = load('jobs/InstallJob', {});
const failures = load('data/ServiceFailure', { '../jobs/InstallJob': { FailureKind } });
function httpFixture(responses) {
  const calls = [];
  return { calls, http: { RequestMethod: { GET: 'GET', POST: 'POST' },
    createHttp: () => ({ destroy() {}, request: async (url, options) => {
      calls.push({ url, options });
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response;
    } }) } };
}
function storeFixture(responses, refresh = async () => {}) {
  const f = httpFixture(responses);
  const { StoreClient } = load('data/StoreClient', {
    '@kit.NetworkKit': { http: f.http }, '@kit.ArkTS': { util: { TextDecoder: class { decodeToString(bytes) { return new TextDecoder().decode(bytes); } } } },
    './AccountService': { AccountService: { configure() {}, refresh } },
    './ServiceFailure': failures, '../jobs/InstallJob': { FailureKind }
  });
  f.client = new StoreClient({ resourceManager: { getRawFileContentSync: () => new Uint8Array() } });
  return f;
}
test('public catalog ETag produces a conditional request and reuses a 304 body', async () => {
  const f = storeFixture([{ responseCode: 200, header: { ETag: '"rev1"' },
    result: JSON.stringify({ ok: true, data: { items: [42] } }) },
    { responseCode: 304, result: '' }]);
  const first = await f.client.getData('/api/v1/apps');
  const second = await f.client.getData('/api/v1/apps');
  assert.equal(first, second);
  assert.equal(f.calls[1].options.header['If-None-Match'], '"rev1"');
});
test('private identity responses never enter conditional public cache', async () => {
  const f = storeFixture(Array.from({ length: 2 }, () => ({ responseCode: 200, header: { ETag: '"private"' },
    result: JSON.stringify({ ok: true, data: {} }) })));
  const account = { userId: 'u', jwtToken: 'jwt', accessToken: 'old' };
  await f.client.getData('/api/v1/me/identity', account);
  await f.client.getData('/api/v1/me/identity', account);
  assert.equal(f.calls[1].options.header['If-None-Match'], undefined);
});
test('Store 401 silently refreshes once; a second 401 retains account failure classification', async () => {
  let refreshes = 0;
  const denied = { responseCode: 401, result: JSON.stringify({ ok: false, error: { message: '请重新登录' } }) };
  const f = storeFixture([denied, denied], async account => { refreshes++; account.accessToken = 'new'; });
  await assert.rejects(f.client.getData('/api/v1/me/apps', { userId: 'u', jwtToken: 'j', accessToken: 'old' }),
    error => error.failureKind === FailureKind.ACCOUNT && error.status === 401);
  assert.equal(refreshes, 1); assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].options.header['X-Huawei-Access-Token'], 'new');
});
test('AGC 401 refreshes once, while 403 and 429 have distinct messages and states', async () => {
  for (const [code, kind] of [[401, FailureKind.ACCOUNT], [403, FailureKind.INTERNAL], [429, FailureKind.NETWORK]]) {
    let refreshed = 0;
    const f = httpFixture([{ responseCode: code, result: '{}' }, { responseCode: 401, result: '{}' }]);
    const { AgcClient } = load('data/AgcClient', { '@kit.NetworkKit': { http: f.http },
      './ServiceFailure': failures, '../jobs/InstallJob': { FailureKind },
      './AccountService': { AccountService: { refresh: async () => { refreshed++; } } } });
    await assert.rejects(new AgcClient({ accessToken: 'a', userId: 'u', teamId: 't' }).certificates(),
      error => error.failureKind === kind && error.status === code);
    assert.equal(refreshed, code === 401 ? 1 : 0);
  }
});
test('account refresh singleflight coalesces calls, respects TTL and never restores logout', async () => {
  let count = 0, writes = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const saved = { userId: 'u', jwtToken: 'j', accessToken: 'old' };
  let session = saved;
  const { AccountService } = load('data/AccountService', {
    './DeveloperAccount': { AccountSession: { load: async () => session, save: async () => { writes++; } } },
    './DevEcoLogin': { DevEcoLogin: { refresh: async () => {
      count++; await gate; return { ...saved, accessToken: 'new', teamId: 't', displayName: '昵称', avatarUrl: '', realNameVerified: false };
    } }, isTransientAuthError: () => false, authErrorText: String },
    './ServiceFailure': failures, '../jobs/InstallJob': { FailureKind }
  });
  AccountService.configure({});
  const a = AccountService.refresh({ ...saved, realNameVerified: true }), b = AccountService.refresh({ ...saved });
  session = undefined; release();
  const refreshed = await a;
  assert.equal(refreshed.accessToken, 'new'); assert.equal(refreshed.realNameVerified, false); await b;
  assert.equal(count, 1); assert.equal(writes, 0);
  await AccountService.refresh(saved); assert.equal(count, 1);
});

test('Huawei realName is a status flag, and missing legacy evidence is not treated as unverified', () => {
  const accountModule = load('data/DeveloperAccount', {});
  const { DevEcoLogin } = load('data/DevEcoLogin', { './DeveloperAccount': accountModule });
  for (const flag of [true, false, undefined, null, 'false', '姓名']) {
    const account = DevEcoLogin.fromUserInfo({ accessToken: 'a', userId: 'u', nickName: '昵称', realName: flag }, 'j');
    const expected = typeof flag === 'boolean' ? flag : undefined;
    assert.equal(account.realNameVerified, expected);
    assert.equal(account.displayName, '昵称', 'the flag must never replace the public nickname');
    const restored = accountModule.DeveloperAccount.fromJson(JSON.parse(account.toJson()));
    assert.equal(restored.realNameVerified, expected);
  }
  assert.equal(accountModule.DeveloperAccount.fromJson({ userId: 'u', jwtToken: 'j' }).realNameVerified, undefined);
});

test('refresh preserves the last real-name status on missing evidence and accepts an explicit changed status', async () => {
  const accountModule = load('data/DeveloperAccount', {});
  for (const flag of [undefined, false, true]) {
    const f = httpFixture([
      { responseCode: 200, result: JSON.stringify({ userInfo: { accessToken: 'a', userId: 'u', realName: flag } }) },
      { responseCode: 200, result: JSON.stringify({ userID: 'u', displayName: '昵称' }) }
    ]);
    const { DevEcoLogin } = load('data/DevEcoLogin', { './DeveloperAccount': accountModule, '@kit.NetworkKit': { http: f.http } });
    const saved = accountModule.DeveloperAccount.fromJson({ userId: 'u', jwtToken: 'j', realNameVerified: true });
    const refreshed = await DevEcoLogin.refresh(saved);
    assert.equal(refreshed.realNameVerified, flag === undefined ? true : flag);
    assert.equal(f.calls.length, 2, 'status comes from the existing login check without another request');
  }
});
test('storage preflight fails before work with a recoverable storage message', async () => {
  const { StorageBudget } = load('jobs/StorageBudget', {
    '@kit.CoreFileKit': { statfs: { getFreeSize: async () => 32 * 1024 * 1024 } },
    '../data/ServiceFailure': failures, './InstallJob': { FailureKind }
  });
  await assert.rejects(StorageBudget.require('/sandbox', 1024),
    error => error.failureKind === FailureKind.TRANSIENT && error.message.includes('存储不足'));
});
