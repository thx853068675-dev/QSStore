// Run: node --test native/tests/test_store_client_http.cjs
//
// 盯住 StoreClient 交给 HarmonyOS http 模块的请求参数。
//
// 起因：下架（DELETE /me/apps/{id}）在真机上报「parameter error」，而服务端日志里
// **根本没有这条 DELETE** —— 说明请求在客户端就被参数校验拒了，没发出去。
// 无 body 的请求走的是 `extraData: ''`，而 ArkTS 的 http 并不接受空 extraData
// （代码里本来就为 POST 记过这个坑，见 EmptyBody 的注释）。
//
// 这里用假的 http 适配器把真实请求参数抓下来，断言「没有 body 时不能带 extraData」。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const sourcePath = path.join(__dirname, '../entry/src/main/ets/data/StoreClient.ets');
const source = fs.readFileSync(sourcePath, 'utf8');

// requestData 是 private，但转译后就是普通方法；连同它依赖的 getData 一起取。
function method(name) {
  // 方法可能是 private，也可能没有修饰符（public）
  const start = source.search(new RegExp(`^  (?:private |public )?(?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, `production method ${name} exists`);
  const end = source.indexOf('\n  }', start);
  assert.notEqual(end, -1);
  return source.slice(start, end + 4);
}

const code = ts.transpileModule(`class StoreClient {
  static BASE_URL = 'https://example.invalid';
  static PUBLIC_KEY_SHA256 = 'x';
  caData = '';
  ${['requestData', 'getData', 'removeMyApp'].map(method).join('\n')}
}; globalThis.StoreClient = StoreClient;`,
{ compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;

/** 抓取每次 request() 的 (url, options)，并返回一个成功信封。 */
function harness(payload = { ok: true, data: {} }) {
  const calls = [];
  const sandbox = {
    ServiceFailure: class extends Error { constructor(kind, message) { super(message); this.failureKind = kind; } },
    FailureKind: { ACCOUNT: 'account', INTERNAL: 'internal', NETWORK: 'network' },
    console,
    JSON,
    Error,
    String,
    Number,
    Promise,
    Object,
    Array,
    http: {
      createHttp: () => ({
        request: (url, options) => {
          calls.push({ url, options });
          return Promise.resolve({ result: JSON.stringify(payload), responseCode: 200 });
        },
        destroy: () => {}
      }),
      RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE', PUT: 'PUT' }
    },
    setTimeout,
    clearTimeout
  };
  vm.runInNewContext(code, sandbox);
  sandbox.StoreClient.responses = new Map();
  sandbox.StoreClient.remember = () => {};
  return { client: new sandbox.StoreClient(), calls };
}

test('a bodyless DELETE must not send an empty extraData', async () => {
  const { client, calls } = harness();
  await client.removeMyApp(7, { jwtToken: 'j', accessToken: 'a' });
  assert.equal(calls.length, 1);
  const options = calls[0].options;
  assert.equal(options.method, 'DELETE');
  assert.match(calls[0].url, /\/api\/v1\/me\/apps\/7$/);
  // 空字符串会被 http 模块当成非法参数（401 Parameter error）
  assert.notEqual(options.extraData, '', 'extraData 不能是空字符串');
});

test('a bodyless GET must not send an empty extraData either', async () => {
  const { client, calls } = harness();
  await client.getData('/api/v1/apps');
  assert.equal(calls.length, 1);
  assert.notEqual(calls[0].options.extraData, '', 'extraData 不能是空字符串');
});

test('a request with a body still sends JSON and a content type', async () => {
  const { client, calls } = harness();
  await client.requestData('/api/v1/submit/prepare', 'POST', undefined, { repo_url: 'a/b' });
  const options = calls[0].options;
  assert.equal(options.extraData, JSON.stringify({ repo_url: 'a/b' }));
  assert.equal(options.header['Content-Type'], 'application/json');
});

test('a bodyless request does not claim a JSON content type', async () => {
  const { client, calls } = harness();
  await client.removeMyApp(7, { jwtToken: 'j', accessToken: 'a' });
  assert.equal(calls[0].options.header['Content-Type'], undefined);
});

test('authorization headers are only sent when an account is given', async () => {
  const withAccount = harness();
  await withAccount.client.removeMyApp(7, { jwtToken: 'jwt-x', accessToken: 'acc-y' });
  assert.equal(withAccount.calls[0].options.header['Authorization'], 'Bearer jwt-x');
  assert.equal(withAccount.calls[0].options.header['X-Huawei-Access-Token'], 'acc-y');

  const without = harness();
  await without.client.getData('/api/v1/apps');
  assert.equal(without.calls[0].options.header['Authorization'], undefined);
});

test('a signed-out account is rejected before any request goes out', async () => {
  const { client, calls } = harness();
  await assert.rejects(() => client.removeMyApp(7, { jwtToken: '', accessToken: '' }),
    /请先登录/);
  assert.deepEqual(calls, [], '不该发出请求');
});

test('a server error envelope surfaces its message', async () => {
  const { client } = harness({ ok: false, error: { code: 'X', message: '下架失败', hint: '稍后再试' } });
  await assert.rejects(() => client.getData('/api/v1/apps'), /下架失败 · 稍后再试/);
});
