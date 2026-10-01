const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync(path.resolve(__dirname,
  '../entry/src/main/ets/jobs/HdcDeviceBridge.ets'), 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const UDID = '4D32998F6E8174CAABD6EF5B2527D35F1D983EC7067970B52E8F865E0D8B92FC';

function fixture(responses, savedPort = 0) {
  const calls = [];
  const preference = { get: async () => savedPort,
    put: async (_key, value) => { savedPort = value; }, flush: async () => {} };
  const native = { hdcCommand: async (_root, operation, parameter) => {
    calls.push([operation, parameter]);
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return next ?? '[Fail] offline';
  }, hdcDisconnect: () => { calls.push(['disconnect']); return 1; } };
  const exports = {};
  vm.runInNewContext(code, { exports, require: name => ({
    'libhap_core.so': native,
    '@kit.ArkData': { preferences: { getPreferences: async () => preference } },
    '@kit.CoreFileKit': { fileIo: {} },
    './InstalledAppRegistry': { InstalledAppRegistry: {} },
    './ConnectionHint': { ConnectionHint: { closed: detail => /connection refused/i.test(detail) } }
  })[name] || {} });
  return { bridge: new exports.HdcDeviceBridge({ filesDir: '/data/app/files' }),
    Bridge: exports.HdcDeviceBridge, calls, get savedPort() { return savedPort; } };
}

test('a previously valid HDC link is probed again before installation', async () => {
  const f = fixture(['udid of current device is :\n' + UDID,
    new Error('HDC command timed out')]);
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.Bridge.deviceLinked(), true);
  assert.equal(await f.bridge.connected(), false);
  assert.equal(f.Bridge.deviceLinked(), false);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 2]);
});

test('a failed UDID query does not become a false positive link', async () => {
  const f = fixture(['[Fail] device disconnected']);
  assert.equal(await f.bridge.connected(), false);
  assert.equal(f.Bridge.deviceLinked(), false);
});

test('explicit reconnect drops the stale session and verifies the new port', async () => {
  const f = fixture(['[Info] connected', 'udid of current device is :\n' + UDID]);
  assert.equal(await f.bridge.connect(5555), true);
  assert.equal(f.savedPort, 5555);
  assert.equal(f.Bridge.deviceLinked(), true);
  assert.deepEqual(f.calls.map(row => row[0]), ['disconnect', 1, 2]);
});

test('automatic reconnect tries the saved port once and then waits for a new port', async () => {
  const f = fixture(['[Fail] disconnected', '[Fail] port closed', '[Fail] disconnected'], 5555);
  assert.equal(await f.bridge.connected(), false);
  assert.equal(f.Bridge.deviceLinked(), false);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 'disconnect', 1, 2]);
});

test('requesting a live UDID uses one verified probe rather than probing twice', async () => {
  const f = fixture(['udid of current device is :\n' + UDID]);
  assert.equal(await f.bridge.udid(), UDID);
  assert.deepEqual(f.calls.map(row => row[0]), [2]);
});

test('UDID recovery returns the identity verified by the new connection', async () => {
  const f = fixture(['[Fail] disconnected', '[Info] connected',
    'udid of current device is :\n' + UDID], 5555);
  assert.equal(await f.bridge.udid(), UDID);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 'disconnect', 1, 2]);
});

test('a former successful UDID must not be returned after the link is lost', async () => {
  const f = fixture(['udid of current device is :\n' + UDID, new Error('offline')]);
  assert.equal(await f.bridge.udid(), UDID);
  await assert.rejects(() => f.bridge.udid(), /尚未连接/);
  assert.equal(f.Bridge.deviceLinked(), false);
});

test('concurrent silent and install link checks share a single verified probe', async () => {
  let resolve; const response = new Promise(yes => { resolve = yes; });
  const f = fixture([response]);
  const one = f.bridge.connected(), two = f.bridge.connected();
  await new Promise(done => setImmediate(done));
  assert.deepEqual(f.calls.map(row => row[0]), [2]);
  resolve(UDID); assert.deepEqual(await Promise.all([one, two]), [true, true]);
});

test('silent restoration without a saved port does not query or pair a device', async () => {
  const f = fixture([], 0);
  assert.equal(await f.bridge.restoreSavedLink(() => true), false);
  assert.equal(f.calls.length, 0);
});

test('automatic fallback queued behind a manual connection preserves the newly verified port', async () => {
  const f = fixture(['[Info] connected', UDID, UDID], 5555);
  const manual = f.bridge.connect(6666, true, false);
  const automatic = f.bridge.connect(5555, false, false);
  assert.deepEqual(await Promise.all([manual, automatic]), [true, true]);
  assert.equal(f.savedPort, 6666);
  assert.equal(f.calls.filter(row => row[0] === 'disconnect').length, 1);
  assert.deepEqual(f.calls.filter(row => row[0] === 1).map(row => row[1]), ['127.0.0.1:6666']);
});
