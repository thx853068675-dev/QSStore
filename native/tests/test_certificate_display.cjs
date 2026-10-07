const { test } = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('  private ' + name);
  assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function fixture(identity) {
  const f = { restore: undefined, calls: [], backup: [] }, now = 1800000000000;
  const box = { getContext: () => ({}), Date: class extends Date { static now() { return now; } },
    errorText: e => e.message, AgcClient: class { async certificates() { return []; } },
    SigningIdentityRecovery: { restore: async () => f.restore, load: async (_ctx, _account, allowExpired) => {
      f.calls.push(allowExpired); return identity;
    } } };
  const code = ['applyCertificateDetail', 'clearCertificateDetail', 'static formatDay', 'recoverSigningIdentity', 'async readSigningIdentity']
    .map(method).join('\n');
  vm.runInNewContext(ts.transpileModule('class Index {' + code + '};globalThis.Page=Index;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  f.page = new box.Page(); Object.assign(f.page, { signedIn: true, identityBusy: false, account: { userId: 'a' },
    loadCertificateDetail: async value => f.page.applyCertificateDetail(value),
    syncIdentityToCloud: async (_ctx, value) => f.backup.push(value) });
  f.now = now / 1000; return f;
}
test('a certificate remains valid through its final second, without the former thirty-day warning', () => {
  const f = fixture(); f.page.applyCertificateDetail({ certId: '1', certName: 'test', certExpiry: f.now + 1 });
  assert.equal(f.page.certExpired, false); assert.ok(f.page.certExpiry);
  f.page.applyCertificateDetail({ certId: '1', certName: 'test', certExpiry: f.now });
  assert.equal(f.page.certExpired, true); assert.ok(f.page.certExpiry);
  f.page.applyCertificateDetail({ certId: '1', certName: 'test', certExpiry: 0 });
  assert.equal(f.page.certExpired, false); assert.equal(f.page.certExpiry, '');
});
test('an expired local identity is still displayed, without being accepted for signing or backed up as usable', async () => {
  const f = fixture({ certId: '1', certName: 'old', certExpiry: 1700000000 });
  await f.page.recoverSigningIdentity(); assert.deepEqual(f.calls, [true]);
  assert.equal(f.page.certReady, false); assert.equal(f.page.certExpired, true);
  assert.equal(f.page.certLabel, 'old'); assert.ok(f.page.certExpiry);
  assert.equal(f.page.identityMessage, ''); assert.equal(f.backup.length, 0);
});
test('a missing identity clears the preceding account certificate; a valid identity avoids the expired-material read', async () => {
  const f = fixture(); Object.assign(f.page, { certId: 'old', certExpiry: 'old', certExpired: true });
  await f.page.recoverSigningIdentity(); assert.equal(f.page.certId, ''); assert.equal(f.page.certExpiry, '');
  assert.equal(f.page.certExpired, false); assert.equal(f.page.certReady, false);
  f.restore = { certId: 'new', certName: 'current', certExpiry: f.now + 14 * 86400 }; f.calls = [];
  await f.page.recoverSigningIdentity(); assert.equal(f.page.certReady, true); assert.equal(f.page.certExpired, false);
  assert.equal(f.calls.length, 0); assert.equal(f.backup.length, 1);
});
