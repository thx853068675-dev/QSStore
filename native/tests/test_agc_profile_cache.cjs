const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/AgcProfile.ets'), 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
function fixture() {
  const f = { now: 1800000000000, files: new Map(), reads: 0, posts: [], rows: [],
    deviceId: 'device-1', error: '', omitAcl: false };
  f.context = { filesDir: '/sandbox' }; f.account = { userId: '42', teamId: 'team-1' };
  f.udid = 'A'.repeat(64);
  f.identity = { accountId: '42', certId: '123', certificatePath: '/sandbox/cert.cer' };
  class AgcClient {
    async devices() { f.reads++; return [{ id: f.deviceId, udid: f.udid }]; }
    async registerDevice() { throw Error('already registered'); }
    async createProfile(_name, _cert, ids, acls, bundle) {
      f.posts.push({ ids: [...ids], acls: [...acls], bundle });
      if (f.error) throw Error(f.error);
      if (ids[0] !== f.deviceId) throw Error('device not exist');
      return JSON.stringify({ type: 'debug', 'bundle-info': { 'bundle-name': bundle },
        validity: { 'not-before': f.now / 1000 - 60, 'not-after': f.now / 1000 + 86400 },
        'debug-info': { 'device-ids': [f.udid] },
        acls: { 'allowed-acls': f.omitAcl ? [] : [...acls] } });
    }
    async download(url) { return url; }
  }
  const exports = {};
  vm.runInNewContext(code, { exports, Date: class extends Date { static now() { return f.now; } },
    require: name => ({
      '@kit.CoreFileKit': { fileIo: { accessSync: p => f.files.has(p),
        mkdirSync: p => f.files.set(p, ''), unlinkSync: p => f.files.delete(p),
        renameSync: (a, b) => { f.files.set(b, f.files.get(a)); f.files.delete(a); } } },
      'libhap_core.so': { readSignedProfile: p => f.files.get(p), profileMatchesCertificate: () => true },
      './AgcClient': { AgcClient }, './SigningIdentity': { SigningIdentityRecovery: {
        writeFile: (p, bytes) => f.files.set(p, bytes)
      } }
    })[name] || {} });
  f.profile = exports.AgcProfile;
  f.ensure = (bundle, permissions = []) => f.profile.ensure(f.context, f.account,
    f.identity, bundle, f.udid, permissions);
  return f;
}
test('a verified existing Profile avoids all AGC requests', async () => {
  const f = fixture(); const p = await f.ensure('com.example.first');
  assert.equal(await f.ensure('com.example.first'), p);
  assert.equal(f.reads, 1); assert.equal(f.posts.length, 1);
});
test('consecutive applications reuse a confirmed device registration but receive separate valid Profiles', async () => {
  const f = fixture(); const a = await f.ensure('com.example.first');
  const b = await f.ensure('com.example.second');
  assert.notEqual(a, b); assert.equal(f.reads, 1); assert.equal(f.posts.length, 2);
  assert.equal(JSON.parse(f.files.get(b))['bundle-info']['bundle-name'], 'com.example.second');
});
test('registration reuse is isolated by account team and full device UDID', async () => {
  const f = fixture(); await f.ensure('com.example.first');
  f.account.teamId = 'team-2'; await f.ensure('com.example.second');
  f.udid = 'B'.repeat(64); await f.ensure('com.example.third');
  f.account.userId = '43'; f.identity.accountId = '43'; await f.ensure('com.example.fourth');
  assert.equal(f.reads, 4);
});
test('an expired registration is checked again before creating another Profile', async () => {
  const f = fixture(); await f.ensure('com.example.first');
  f.now += 10 * 60 * 1000; await f.ensure('com.example.second');
  assert.equal(f.reads, 2);
});
test('a deleted registration is refreshed and only its replacement ID is retried', async () => {
  const f = fixture(); await f.ensure('com.example.first');
  f.deviceId = 'device-2'; await f.ensure('com.example.second');
  assert.equal(f.reads, 2); assert.equal(f.posts.length, 3);
  assert.deepEqual(f.posts[2].ids, ['device-2']);
});
test('a certificate error is not turned into repeated Profile creation with unchanged device IDs', async () => {
  const f = fixture(); await f.ensure('com.example.first'); f.error = 'cert not exist';
  await assert.rejects(() => f.ensure('com.example.second'), /cert not exist/);
  assert.equal(f.posts.length, 2); assert.equal(f.reads, 2);
  f.error = ''; await f.ensure('com.example.third'); assert.equal(f.reads, 3);
});
test('cached device registration never bypasses the returned Profile ACL validation', async () => {
  const f = fixture(); await f.ensure('com.example.first'); f.omitAcl = true;
  await assert.rejects(() => f.ensure('com.example.second', ['ohos.permission.SYSTEM_FLOAT_WINDOW']), /不匹配/);
  assert.equal([...f.files.keys()].some(p => p.includes('com.example.second')), false);
  f.omitAcl = false; await f.ensure('com.example.third'); assert.equal(f.reads, 2);
});
