const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'));
  assert(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function fixture() {
  const f = { probe: deferred(), identity: deferred(), probes: 0, reads: 0, linked: false, timers: new Map(), synced: 0 };
  let timerId = 0;
  const box = { getContext: () => ({}), errorText: e => e.message, setTimeout: fn => { f.timers.set(++timerId, fn); return timerId; }, clearTimeout: id => f.timers.delete(id),
    HdcDeviceBridge: class { static deviceLinked() { return f.linked; } static releaseDevice() { f.linked = false; return true; } connected() { f.probes++; return f.probe.promise; } },
    SigningIdentityRecovery: { restore() { f.reads++; return f.identity.promise; }, load: async () => undefined } };
  vm.runInNewContext(ts.transpileModule('class Page {' + ['checkDevice', 'readDeviceStatus', 'releaseDeviceLink', 'recoverSigningIdentity', 'readSigningIdentity'].map(method).join('\n') + '};globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  f.ui = Object.assign(new box.Page(), { deviceConnected: true, deviceStatusKnown: true, deviceBusy: false, deviceCheckGeneration: 0,
    signedIn: true, account: { userId: 'user1', teamId: 'team1' }, signingIdentityRevision: 1, identityBusy: false, identityMessage: '', certReady: true,
    clearCertificateDetail() { this.certLabel = ''; }, loadCertificateDetail: async function(row) { this.certLabel = row.name; }, syncIdentityToCloud: async () => { f.synced++; } });
  return f;
}
test('revisiting Mine keeps confirmed connection text and Wi-Fi icon while one shared probe is pending', async () => {
  const f = fixture(); const first = f.ui.checkDevice(), second = f.ui.checkDevice();
  assert.equal(first, second); assert.equal(f.probes, 1); assert.equal(f.ui.deviceBusy, false); assert.equal(f.ui.deviceConnected, true);
  f.probe.resolve(true); await first; assert.equal(f.ui.deviceConnected, true); assert.equal(f.ui.deviceBusy, false);
});
test('first unknown connection shows progress; a conclusive disconnected result updates state', async () => {
  const f = fixture(); f.ui.deviceStatusKnown = false; f.ui.deviceConnected = false;
  const work = f.ui.checkDevice(); assert(f.ui.deviceBusy); f.probe.resolve(false); await work;
  assert(!f.ui.deviceBusy); assert(f.ui.deviceStatusKnown); assert(!f.ui.deviceConnected);
});
test('timeout and transport exceptions retain the previously confirmed connection and end waiting', async () => {
  for (const timeout of [true, false]) {
    const f = fixture(); const work = f.ui.checkDevice();
    if (timeout) f.timers.values().next().value(); else f.probe.reject(Error('transport unavailable'));
    await work; assert(f.ui.deviceConnected); assert(!f.ui.deviceBusy); assert.equal(f.timers.size, 0);
    if (timeout) { f.probe.resolve(false); await Promise.resolve(); assert(f.ui.deviceConnected); }
  }
});
test('releasing the link invalidates an older successful probe', async () => {
  const f = fixture(); const work = f.ui.checkDevice(); f.ui.releaseDeviceLink();
  f.probe.resolve(true); await work; assert(!f.ui.deviceConnected); assert(!f.ui.deviceBusy);
});
test('passive certificate recovery does not relabel reset or erase the paired state', async () => {
  const f = fixture(); const work = f.ui.recoverSigningIdentity();
  assert.equal(work, f.ui.recoverSigningIdentity()); assert.equal(f.reads, 1); assert(!f.ui.identityBusy);
  assert(f.ui.certReady); assert.equal(f.ui.identityMessage, '');
  f.identity.resolve({ name: 'same certificate' }); await work;
  assert.equal(f.ui.certLabel, 'same certificate'); assert(!f.ui.identityBusy); assert(f.ui.certReady); assert.equal(f.synced, 1);
});
test('account/revision changes and a manual mutation invalidate old certificate display updates', async () => {
  for (const changed of ['account', 'revision', 'manual']) {
    const f = fixture(); f.ui.certLabel = 'current'; const work = f.ui.recoverSigningIdentity();
    if (changed === 'account') f.ui.account = { userId: 'user2', teamId: 'team1' };
    if (changed === 'revision') f.ui.signingIdentityRevision++;
    if (changed === 'manual') f.ui.identityBusy = true;
    f.identity.resolve({ name: 'stale' }); await work;
    assert.equal(f.ui.certLabel, 'current'); assert.equal(f.synced, 0);
  }
});
