const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function load(name, http) {
  const file = path.join(__dirname, '../entry/src/main/ets/data', name + '.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: id => id === '@kit.NetworkKit' ? { http } : {} });
  return exports[name];
}

function transport(result) {
  const calls = [];
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' },
    createHttp: () => ({
      request: async (url, options) => {
        calls.push({ url, options });
        return { responseCode: 200, result: JSON.stringify(result) };
      },
      destroy: () => {}
    })
  };
  return { calls, http };
}

test('an empty AGC certificate list is a valid bodyless GET', async () => {
  const t = transport({ ret: { code: 0 }, certList: [] });
  const Client = load('AgcClient', t.http);
  const list = await new Client({ accessToken: 'token', teamId: 'team', userId: 'user' })
    .certificates();
  assert.equal(list.length, 0);
  assert.equal(t.calls[0].options.method, 'GET');
  assert.equal(t.calls[0].options.extraData, undefined);
});

test('AGC certificate creation keeps its JSON body', async () => {
  const t = transport({ ret: { code: 0 }, harmonyCert: { id: '42' } });
  const Client = load('AgcClient', t.http);
  await new Client({ accessToken: 'token', teamId: 'team', userId: 'user' })
    .createCertificate('-----BEGIN CERTIFICATE REQUEST-----\nfixture', 'test');
  assert.equal(t.calls[0].options.method, 'POST');
  assert.equal(JSON.parse(t.calls[0].options.extraData).certType, 1);
});

test('first login GET does not send empty extraData', async () => {
  const t = transport({ userInfo: { accessToken: 'a', userId: 'u' } });
  const Login = load('DevEcoLogin', t.http);
  await Login.requestJson('https://example.invalid/login', 'GET');
  assert.equal(t.calls[0].options.extraData, undefined);
});

test('public profile POST retains its form body', async () => {
  const t = transport({});
  const Login = load('DevEcoLogin', t.http);
  await Login.requestJson('https://example.invalid/profile', 'POST',
    { 'Content-Type': 'application/x-www-form-urlencoded' }, 'access_token=x');
  assert.equal(t.calls[0].options.extraData, 'access_token=x');
});
