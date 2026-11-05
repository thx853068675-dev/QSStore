const { publicConsentModule } = require('./load_ets.cjs');
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
const registryCode = ts.transpileModule(fs.readFileSync(path.resolve(__dirname,
  '../entry/src/main/ets/jobs/InstalledAppRegistry.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture(responses, savedPort = 0, fixed = undefined) {
  const calls = [];
  let fixedText = fixed ? JSON.stringify(fixed) : '{}';
  const preference = { get: async key => key === 'fixed-config' ? fixedText : savedPort,
    put: async (key, value) => { if (key === 'fixed-config') fixedText = value; else savedPort = value; }, flush: async () => {} };
  const native = { hdcCommand: async (_root, operation, parameter) => {
    calls.push([operation, parameter]);
    if(operation===23)return '1';
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return next ?? '[Fail] offline';
  }, hdcDisconnect: () => { calls.push(['disconnect']); return 1; } };
  const exports = {};
  const registryExports = {};
  vm.runInNewContext(registryCode, { exports: registryExports, require: () => ({}) });
  vm.runInNewContext(code, { exports, setTimeout: callback => setImmediate(callback), require: name => ({
    'libhap_core.so': native,
    '@kit.ArkData': { preferences: { getPreferences: async () => preference } },
    '@kit.CoreFileKit': { fileIo: {} },
    './InstalledAppRegistry': registryExports,
    './ConnectionHint': { ConnectionHint: { closed: detail => /connection refused/i.test(detail) } }
  })[name] || publicConsentModule(name) });
  return { bridge: new exports.HdcDeviceBridge({ filesDir: '/data/app/files' }),
    Bridge: exports.HdcDeviceBridge,native,calls, get savedPort() { return savedPort; }, get fixed() { return JSON.parse(fixedText); } };
}

test('fixed settings persist separately from the last successfully connected port', async () => {
  const f = fixture([], 5555);
  await f.bridge.saveFixedPortSettings({ enabled: true, port: 45678 });
  assert.equal(f.savedPort, 5555);
  assert.deepEqual(f.fixed, { enabled: true, port: 45678 });
  await assert.rejects(() => f.bridge.saveFixedPortSettings({ enabled: true, port: 65536 }), /五位/);
});

test('a fixed port is probed before a stale system port without repeated trust waits', async () => {
  const f = fixture(['[Fail] offline', '[Info] connected', UDID], 5555, { enabled: true, port: 45678 });
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.savedPort, 45678);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 23, 16, 2]);
});

test('a thrown native offline probe still reaches the fixed-port reconnect', async () => {
  const f = fixture([new Error('HDC no target'), '[Info] connected', UDID],
    5555, { enabled: true, port: 45678 });
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.Bridge.connectedPort(), 45678);
});

test('fixed reconnect falls back to the last working port if the daemon reset its setting', async () => {
  const f = fixture(['[Fail] offline', new Error('connection refused'), '[Info] connected', UDID],
    5555, { enabled: true, port: 45678 });
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.Bridge.connectedPort(), 5555);
  assert.deepEqual(f.calls.filter(row => [1, 16].includes(row[0])).map(row => row[1]),
    ['127.0.0.1:45678', '127.0.0.1:5555']);
});

test('a system wireless toggle discovers the new local daemon and verifies its identity', async () => {
  const f = fixture(['[Fail] offline', new Error('connection refused'), '54321', '[Info] connected', UDID],
    45678, { enabled: true, port: 45678 });
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.Bridge.connectedPort(), 54321);
  assert.equal(f.savedPort, 54321);
  assert.deepEqual(f.calls.filter(row => [16, 18].includes(row[0])),
    [[16, '127.0.0.1:45678'], [18, ''], [16, '127.0.0.1:54321']]);
  assert.equal(f.fixed.port, 45678);
});

test('discovery is bounded to fixed-port recovery and rejects invalid native results', async () => {
  for (const discovered of ['', '65536', '22', 'other:54321', '54321extra']) {
    const f = fixture(['[Fail] offline', new Error('connection refused'), discovered],
      45678, { enabled: true, port: 45678 });
    assert.equal(await f.bridge.connected(), false);
    assert.equal(f.calls.filter(row => row[0] === 18).length, 1);
    assert.equal(f.calls.filter(row => row[0] === 16).length, 1);
    assert.equal(f.savedPort, 45678);
  }
  const off = fixture(['[Fail] offline', new Error('connection refused')],
    45678, { enabled: false, port: 45678 });
  assert.equal(await off.bridge.connected(), false);
  assert.equal(off.calls.some(row => row[0] === 18), false);
});

test('daemon restart and a lost setting receipt still verify and commit the new port', async () => {
  const f = fixture([UDID, new Error('peer closed'), new Error('connection refused'), '[Info] connected', UDID], 5555);
  assert.equal(await f.bridge.fixPort(45678, () => true), true);
  assert.equal(f.savedPort, 45678);
  assert.equal(f.Bridge.connectedPort(), 45678);
  assert.equal(f.calls.filter(row => row[0] === 15).length, 1);
});

test('rejected fixed port restores the original link and leaves the verified saved port unchanged', async () => {
  const f = fixture([UDID, '[Fail] permission denied', ...Array(3).fill(new Error('connection refused')),
    '[Info] connected', UDID], 5555);
  await assert.rejects(() => f.bridge.fixPort(45678, () => true), /permission denied/);
  assert.equal(f.savedPort, 5555);
  assert.equal(f.Bridge.connectedPort(), 5555);
  assert.equal(f.Bridge.busy(), false);
});

test('a running operation or withdrawn foreground permission cannot restart the daemon', async () => {
  const f = fixture([]);
  assert.equal(await f.bridge.fixPort(45678, () => false), false);
  assert.equal(f.calls.length, 0);
  const busy = fixture([new Promise(() => {})]);
  busy.bridge.connected();
  assert.equal(await busy.bridge.fixPort(45678, () => true), false);
  assert.equal(busy.calls.some(row => row[0] === 15), false);
});

test('deactivation uses the official close operation and removes the last automatic port', async () => {
  const f = fixture([UDID, ''], 45678);
  assert.equal(await f.bridge.clearFixedPort(() => true), true);
  assert.equal(f.savedPort, 0); assert.equal(f.Bridge.deviceLinked(), false);
  assert.equal(f.calls.filter(row => row[0] === 17).length, 1);
});

test('a lost deactivation receipt is reconciled only when the old endpoint refuses connections', async () => {
  const f = fixture([UDID, new Error('peer closed'), new Error('connection refused')], 45678);
  assert.equal(await f.bridge.clearFixedPort(() => true), true);
  assert.equal(f.savedPort, 0);
  const denied = fixture([UDID, '[Fail] permission denied', '[Info] connected', UDID], 45678);
  await assert.rejects(() => denied.bridge.clearFixedPort(() => true), /permission denied/);
  assert.equal(denied.savedPort, 45678); assert.equal(denied.Bridge.deviceLinked(), true);
});

test('a previously valid HDC link is probed again before installation', async () => {
  const f = fixture(['udid of current device is :\n' + UDID,
    new Error('HDC command timed out')]);
  assert.equal(await f.bridge.connected(), true);
  assert.equal(f.Bridge.deviceLinked(), true);
  assert.equal(await f.bridge.connected(), false);
  assert.equal(f.Bridge.deviceLinked(), false);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 2]);
});

const removedBundle = 'com.example.uninstalltest';
const listEnd = '__QINGQI_BUNDLE_LIST_END__\n';
const removedList = 'ID: 100:\ncom.tonghongxiang.hapstore\n' + listEnd;
const presentList = 'ID: 100:\n' + removedBundle + '\n' + listEnd;

test('system uninstall success is returned without losing the receipt', async () => {
  const f = fixture([UDID, 'uninstall bundle successfully.']);
  await f.bridge.uninstall(removedBundle);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 7]);
  assert.equal(f.Bridge.busy(), false);
});

test('lost uninstall receipt is reconciled against a complete system inventory', async () => {
  const f = fixture([UDID, new Error('HDC command: peer closed'), removedList]);
  await f.bridge.uninstall(removedBundle);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 7, 6]);
});

test('a slow uninstall waits for disappearance without submitting removal twice', async () => {
  const f = fixture([UDID, '', presentList, presentList, removedList]);
  await f.bridge.uninstall(removedBundle);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 7, 6, 6, 6]);
});

test('truncated and offline inventories never falsely confirm uninstall', async () => {
  for (const response of [removedList.replace(listEnd, ''), '[Fail] offline',
    new Error('connection reset')]) {
    const f = fixture([UDID, new Error('peer closed'), response]);
    await assert.rejects(() => f.bridge.uninstall(removedBundle), /暂时无法确认卸载结果/);
    assert.deepEqual(f.calls.map(row => row[0]), [2, 7, 6]);
    assert.equal(f.Bridge.busy(), false);
  }
});

test('a real system rejection with the app still installed remains a failure', async () => {
  const f = fixture([UDID, 'error: failed to uninstall bundle. code: 123', presentList]);
  await assert.rejects(() => f.bridge.uninstall(removedBundle), /code: 123/);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 7, 6]);
});

test('uninstalling an already absent app is idempotent after a complete inventory', async () => {
  const f = fixture([UDID, 'error: bundle not found', removedList]);
  await f.bridge.uninstall(removedBundle);
});

test('unconfirmed removal is bounded and cannot clear a still installed app', async () => {
  const f = fixture([UDID, '', ...Array(6).fill(presentList)]);
  await assert.rejects(() => f.bridge.uninstall(removedBundle), /设备上仍安装着该应用/);
  assert.equal(f.calls.filter(row => row[0] === 7).length, 1);
  assert.equal(f.calls.filter(row => row[0] === 6).length, 6);
  assert.equal(f.Bridge.busy(), false);
});

test('idle background disconnect cannot interrupt uninstall confirmation', async () => {
  let resolve;
  const pending = new Promise(yes => { resolve = yes; });
  const f = fixture([UDID, '', pending]);
  const removal = f.bridge.uninstall(removedBundle);
  await new Promise(done => setImmediate(done));
  assert.equal(f.Bridge.busy(), true);
  // releaseWhenIdle normally waits for the command queue; a separate direct
  // busy check also protects the gaps between confirmation polls.
  const release = f.Bridge.releaseWhenIdle(() => true);
  resolve(removedList);
  await removal;
  assert.equal(await release, false);
  assert.equal(f.calls.some(row => row[0] === 'disconnect'), false);
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
  assert.deepEqual(f.calls.map(row => row[0]), [23, 1, 2]);
});

test('automatic reconnect tries the saved port once and then waits for a new port', async () => {
  const f = fixture(['[Fail] disconnected', '[Fail] port closed', '[Fail] disconnected'], 5555);
  assert.equal(await f.bridge.connected(), false);
  assert.equal(f.Bridge.deviceLinked(), false);
  assert.deepEqual(f.calls.map(row => row[0]), [2, 23, 16, 2]);
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
  assert.deepEqual(f.calls.map(row => row[0]), [2, 23, 16, 2]);
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
  assert.equal(f.calls.filter(row => row[0] === 23).length, 1);
  assert.equal(f.calls.some(row=>row[0]==='disconnect'),false);
  assert.deepEqual(f.calls.filter(row => row[0] === 1).map(row => row[1]), ['127.0.0.1:6666']);
});

test('a busy native disconnect preserves local and remote session bookkeeping until a later success',async()=>{
 const f=fixture([]);f.Bridge.linked=true;f.Bridge.activePort=54321;f.Bridge.sessions.add('remote');f.native.hdcDisconnect=()=>-2;
 assert.equal(f.Bridge.releaseDevice(),false);assert.equal(f.Bridge.deviceLinked(),true);assert.equal(f.Bridge.hasSessions(),true);assert.equal(f.Bridge.releasePending,true);
 f.native.hdcDisconnect=()=>2;assert.equal(f.Bridge.releaseDevice(),true);assert.equal(f.Bridge.hasSessions(),false);assert.equal(f.Bridge.connectedPort(),0);assert.equal(f.Bridge.releasePending,false);
});
test('a cancelled automatic restore never starts late saved-port connection or discovery work',async()=>{
 let resolve,allowed=true;const gate=new Promise(done=>resolve=done),f=fixture([gate],54321,{enabled:true,port:54321});
 const work=f.bridge.restoreSavedLink(()=>allowed);await new Promise(done=>setImmediate(done));allowed=false;resolve('[Fail] offline');
 assert.equal(await work,false);assert.deepEqual(f.calls.map(row=>row[0]),[2]);
});

test('revoked consent blocks discovery starts but still allows native cancellation',async()=>{
 const {loadEts}=require('./load_ets.cjs'),calls=[];
 const {HdcDeviceBridge:B}=loadEts('jobs/HdcDeviceBridge',{
  './PrivacyConsent':{PrivacyConsent:{assertBusinessAllowed(){throw Error('consent required');}}},
  '../data/PrivacyConsent':{PrivacyConsent:{assertBusinessAllowed(){throw Error('consent required');}}},
  'libhap_core.so':{hdcCommand:async(_root,operation,value)=>{calls.push([operation,value]);return '';}}
 });
 await assert.rejects(B.discoveryCommand({filesDir:'/data'},21,'start:privacy-id'),/consent/);
 await B.discoveryCommand({filesDir:'/data'},21,'stop:privacy-id');await B.discoveryCommand({filesDir:'/data'},25,'peers');
 assert.deepEqual(calls,[[21,'stop:privacy-id'],[25,'peers']]);assert.equal(B.busy(),false);
});
