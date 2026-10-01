const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, console, ...globals });
  return exports;
}
const { ConnectionHint } = load('jobs/ConnectionHint');
test('closed, occupied, trust and timeout failures have distinct actionable hints', () => {
  assert.match(ConnectionHint.message('Connection refused (os error 111)'), /没有接受连接/);
  assert.match(ConnectionHint.message('address already in use'), /已被占用/);
  assert.match(ConnectionHint.message('TCP authentication rejected by daemon'), /尚未授权/);
  assert.match(ConnectionHint.message('TCP authentication timeout'), /端口可以访问/);
  assert.match(ConnectionHint.message('HDC command timed out'), /连接超时/);
  assert.doesNotMatch(ConnectionHint.message('Unexpected EOF'), /已被占用/);
  assert.doesNotMatch(ConnectionHint.message('unknown failure'), /已被占用/);
});
test('explicit connection refusal stops retries; the last successful port is retained', async () => {
  let attempts = 0, written = 0;
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    './ConnectionHint': { ConnectionHint },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({ get: async () => 45678,
      put: async () => written++, flush: async () => {} }) } }
  });
  const bridge = new HdcDeviceBridge({ filesDir: '/sandbox' });
  bridge.command = async () => { attempts++; return '[Fail]Connection refused (os error 111)'; };
  assert.equal(await bridge.savedPort(), 45678);
  assert.equal(await bridge.connect(45679), false);
  assert.equal(attempts, 1); assert.equal(written, 0);
  assert.match(bridge.connectionFailureMessage(), /端口已变化/);
});
test('install progress observes the active command without taking the HDC queue and always stops polling', async () => {
  let timer, stopped = 0, reset = 0, resolve;
  let current = { phase: 'transfer', sent: 40, total: 100 };
  const command = new Promise(done => resolve = done);
  const { HdcDeviceBridge } = load('jobs/HdcDeviceBridge', {
    '@kit.CoreFileKit': { fileIo: { accessSync: () => true } },
    'libhap_core.so': { hdcCommand: () => command,
      hdcInstallProgress: (_path, clear) => { if (clear) reset++; return JSON.stringify(current); } }
  }, { setInterval: fn => { timer = fn; return 1; }, clearInterval: () => stopped++ });
  const bridge = new HdcDeviceBridge({ filesDir: '/sandbox' }); bridge.connected = async () => true;
  const observed = [];
  const work = bridge.install('/sandbox/test.hap', (...args) => observed.push(args));
  await new Promise(setImmediate); timer();
  current = { phase: 'installing', sent: 100, total: 100 }; timer();
  resolve('install bundle successfully'); await work;
  assert.equal(reset, 1); assert.equal(stopped, 1);
  assert.deepEqual(observed[0], ['transfer', 40, 100]);
  assert.deepEqual(observed.at(-1), ['installing', 100, 100]);
});
