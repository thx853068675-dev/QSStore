const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/AgcProfile.ets'), 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
function fixture() {
  const f = { now: 1800000000000, files: new Map(), reads: 0, posts: [], rows: [],
    deviceId: 'device-1', error: '', errorStatus: 0, omitAcl: false, releases: [], recovery: 0, recoveryCalls: 0, limited: false, limits: 0, managedCalls: 0, managedWorks: false };
  f.context = { filesDir: '/sandbox' }; f.account = { userId: '42', teamId: 'team-1' };
  f.udid = 'A'.repeat(64);
  f.identity = { accountId: '42', certId: '123', certificatePath: '/sandbox/cert.cer' };
  f.identity.certExpiry = f.now / 1000 + 2 * 86400;
  class AgcClient {
    async devices() { f.reads++; return [{ id: f.deviceId, udid: f.udid }]; }
    async registerDevice() { throw Error('already registered'); }
    async createProfile(name, _cert, ids, acls, bundle) {
      f.posts.push({ name, ids: [...ids], acls: [...acls], bundle });
      if (f.error) { const error = Error(f.error); error.status = f.errorStatus; throw error; }
      if (ids[0] !== f.deviceId) throw Error('device not exist');
      return { id: f.noReceipt ? '' : String(f.posts.length), downloadUrl: JSON.stringify({ type: 'debug', 'bundle-info': { 'bundle-name': bundle },
        validity: { 'not-before': f.now / 1000 - 60, 'not-after': f.responseExpiry ?? f.now / 1000 + 86400 },
        'debug-info': { 'device-ids': [f.udid] },
        acls: { 'allowed-acls': f.omitAcl ? [] : [...acls] } }) };
    }
    async download(url) { return url; }
  }
  const exports = {};
  vm.runInNewContext(code, { exports, Error, Date: class extends Date { static now() { return f.now; } },
    require: name => ({
      './AgcManagedProfile': { AgcManagedProfile: { automaticLimited: () => f.limited,
        rememberLimit: () => { f.limited = true; f.limits++; },
        obtain: async (_agc, _account, _cert, _ids, acls, bundle, p, valid) => {
          f.managedCalls++;
          if (!f.managedWorks) { const e = Error('最近 30 天最多 150 次；删除授权不会恢复次数'); e.status = 205389938; throw e; }
          f.files.set(p, JSON.stringify({ type: 'debug', 'bundle-info': { 'bundle-name': bundle },
            validity: { 'not-before': f.now/1000-60, 'not-after': f.now/1000+86400 },
            'debug-info': { 'device-ids': [f.udid] }, acls: { 'allowed-acls': acls } }));
          assert.ok(valid(p));
        } } },
      './AgcProfileLease': { AgcProfileLease: { remember: (_ctx, _account, id) => { (f.remembered ??= []).push(id); },
        recover: async () => { f.recoveryCalls++; return f.recovery; }, release: async (_ctx, _acct, _client, id) => { f.releases.push(id); return true; } } },
      '@kit.CoreFileKit': { fileIo: { accessSync: p => f.files.has(p),
        OpenMode: { READ_WRITE: 2 }, openSync: p => ({ fd: p }),
        fsyncSync: () => {}, closeSync: () => {},
        listFileSync: p => [...f.files.keys()].filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)),
        copyFileSync: (a, b) => f.files.set(b, f.files.get(a)),
        mkdirSync: p => f.files.set(p, ''), unlinkSync: p => f.files.delete(p),
        renameSync: (a, b) => { f.files.set(b, f.files.get(a)); f.files.delete(a); } },
        hash: { hash: async p => crypto.createHash('sha256').update(f.files.get(p)).digest('hex') } },
      'libhap_core.so': { readSignedProfile: p => f.files.get(p), profileMatchesCertificate: () => true },
      '../jobs/InstallJob': { FailureKind: { ACCOUNT: 'account', NETWORK: 'network', INVALID_PACKAGE: 'invalid_package' } },
      './ServiceFailure': { ServiceFailure: class extends Error {
        constructor(kind, message, status) { super(message); this.failureKind = kind; this.status = status; }
      } },
      './AgcClient': { AgcClient }, './SigningIdentity': { SigningIdentityRecovery: {
        writeFile: (p, bytes) => f.files.set(p, bytes)
      } }
    })[name] || {} });
  f.profile = exports.AgcProfile;
  f.ensure = (bundle, permissions = [], refresh) => f.profile.ensure(f.context, f.account,
    f.identity, bundle, f.udid, permissions, refresh);
  f.refresh = (requestId, minimumExpiry) => Object.assign(new exports.ProfileRefreshOptions(),
    { requestId, minimumExpiry });
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
test('renewal obtains a distinct Profile, retries reuse it, and the next renewal has its own request', async () => {
  const f = fixture(), bundle = 'com.example.first';
  const old = await f.ensure(bundle), oldBytes = f.files.get(old);
  const oldExpiry = f.profile.profileExpiry(old);
  f.now += 120000;
  const request = f.refresh('request1', oldExpiry);
  const renewed = await f.ensure(bundle, [], request);
  assert.notEqual(renewed, old);
  assert.match(renewed, /-p-[0-9a-f]{64}\.p7b$/);
  assert.ok(f.profile.effectiveExpiry(renewed, f.identity.certExpiry) > oldExpiry);
  assert.equal(f.files.get(old), oldBytes);
  assert.equal(await f.ensure(bundle, [], request), renewed);
  assert.equal(f.posts.length, 2, 'retry must not request another Profile');
  f.now += 120000;
  const next = await f.ensure(bundle, [], f.refresh('request2', f.profile.profileExpiry(renewed)));
  assert.notEqual(next, renewed);
  assert.equal(f.posts.length, 3);
  assert.equal(f.reads, 1, 'verified device registration remains reusable');
  assert.ok(f.posts.every(p => p.name.length <= 64));
  assert.equal(f.releases.length, 3, 'all temporary AGC records are released');
});
test('unchanged expiry and certificate-capped expiry never replace the old Profile', async () => {
  for (const capped of [false, true]) {
    const f = fixture(), bundle = 'com.example.first', old = await f.ensure(bundle);
    const before = f.files.get(old), expiry = f.profile.profileExpiry(old);
    f.now += 120000;
    if (capped) f.identity.certExpiry = expiry; else f.responseExpiry = expiry;
    await assert.rejects(() => f.ensure(bundle, [], f.refresh('notextended', expiry)), /有效期未延长|有效期不足/);
    assert.equal(f.posts.length, capped ? 1 : 2, 'a known certificate cap must not consume an AGC request');
    assert.equal(f.files.get(old), before);
    assert.equal([...f.files.keys()].some(p => p.includes('-r-notextended')), false);
  }
});
test('renewal failures retain the previous Profile and clean partial files', async () => {
  const f = fixture(), bundle = 'com.example.first', old = await f.ensure(bundle);
  const before = f.files.get(old), expiry = f.profile.profileExpiry(old);
  f.error = 'AGC offline';
  await assert.rejects(() => f.ensure(bundle, [], f.refresh('offline', expiry)), /AGC offline/);
  assert.equal(f.files.get(old), before);
  assert.equal([...f.files.keys()].some(p => p.endsWith('.part')), false);
});
test('renewal cannot report an effective expiry without a known certificate expiry', async () => {
  const f = fixture(), bundle = 'com.example.first', old = await f.ensure(bundle);
  const expiry = f.profile.profileExpiry(old);
  f.now += 120000; f.identity.certExpiry = 0;
  await assert.rejects(() => f.ensure(bundle, [], f.refresh('unknown', expiry)), /证书有效期/);
  assert.equal(f.posts.length, 1, 'unknown certificate expiry must not cause repeated authorization requests');
  assert.equal([...f.files.keys()].some(p => p.includes('-r-unknown')), false);
});

test('a newer verified local Profile satisfies a new renewal request without another AGC allocation', async () => {
  const f = fixture(), bundle = 'com.example.first';
  const first = await f.ensure(bundle), expiry = f.profile.profileExpiry(first);
  f.now += 120000;
  const newer = await f.ensure(bundle, [], f.refresh('first', expiry));
  const retry = await f.ensure(bundle, [], f.refresh('second', expiry));
  assert.equal(newer, retry, 'renewal journals reuse the same immutable material');
  assert.equal(f.files.get(newer), f.files.get(retry));
  assert.equal(f.posts.length, 2);
});
test('a rejected returned Profile still releases its created cloud record', async () => {
  const f = fixture(); f.omitAcl = true;
  await assert.rejects(() => f.ensure('com.example.first', ['ohos.permission.SYSTEM_FLOAT_WINDOW']), /不匹配/);
  assert.deepEqual(f.releases, ['1']);
});
test('quota exhaustion does not retry allocations or delete signing certificates', async () => {
  const f = fixture(); f.error = 'Sign ide test provision number exceeds limit.';
  await assert.rejects(() => f.ensure('com.example.first'), /最近 30 天最多 150 次/);
  assert.equal(f.posts.length, 1);
  assert.equal(f.releases.length, 0);
});
test('successful receipt cleanup cannot reset the rolling automatic signing limit', async () => {
  const f = fixture(); f.error = 'Provision number exceeds limit'; f.errorStatus = 205389938;
  f.recovery = 3;
  await assert.rejects(() => f.ensure('com.example.first'), error =>
    error.status === 205389938 && /删除授权不会恢复次数/.test(error.message));
  assert.equal(f.posts.length, 1, 'cleaned records do not restore automatic signing usage');
  assert.equal(f.recoveryCalls, 1, 'quota failure must not trigger another cleanup');
  assert.equal(f.releases.length, 0);
});
test('an existing valid authorization remains usable while the cloud signing quota is exhausted', async () => {
  const f = fixture(); const profile = await f.ensure('com.example.first');
  f.error = 'Sign ide test provision number exceeds limit.'; f.recovery = 3;
  assert.equal(await f.ensure('com.example.first'), profile);
  assert.equal(f.posts.length, 1); assert.equal(f.recoveryCalls, 1);
});
test('concurrent identical requests serialize and reuse the verified result', async () => {
  const f = fixture();
  const [a, b] = await Promise.all([f.ensure('com.example.first'), f.ensure('com.example.first')]);
  assert.equal(a, b); assert.equal(f.posts.length, 1); assert.equal(f.releases.length, 1);
});

test('quota fallback obtains and persists an ordinary Profile without treating it as a temporary lease', async () => {
  const f = fixture(); f.error = 'automatic limit'; f.errorStatus = 205389938; f.managedWorks = true;
  const p = await f.ensure('com.example.first');
  assert.equal(f.posts.length, 1); assert.equal(f.managedCalls, 1); assert.equal(f.limits, 1);
  assert.equal(f.releases.length, 0);
  assert.equal(await f.ensure('com.example.first'), p);
  assert.equal(f.posts.length, 1); assert.equal(f.managedCalls, 1);
  await f.ensure('com.example.second');
  assert.equal(f.posts.length, 1, 'another application skips the known exhausted IDE path');
  assert.equal(f.managedCalls, 2);
});

test('valid disk authorization is reused after loading a fresh client process', async () => {
  const first=fixture(),path=await first.ensure('com.example.first');
  const restarted=fixture();restarted.files=new Map(first.files);restarted.error='quota exhausted';
  assert.equal(await restarted.ensure('com.example.first'),path);
  assert.equal(restarted.posts.length,0);assert.equal(restarted.reads,0);assert.equal(restarted.recoveryCalls,0);
});

test('receipt-free IDE authorization is verified, persisted and reused without cloud deletion', async () => {
  const f=fixture();f.noReceipt=true;
  const p=await f.ensure('com.example.first');
  assert.ok(f.files.has(p));assert.equal(f.profile.valid(p,'com.example.first',f.udid,f.identity.certificatePath,[]),true);
  assert.equal((f.remembered||[]).length,0);assert.equal(f.releases.length,0);
  assert.equal(await f.ensure('com.example.first'),p);assert.equal(f.posts.length,1);
});
test('new ACL variants never overwrite the Profile pinned by an earlier installation', async () => {
  const f=fixture(),bundle='com.example.first',first=await f.ensure(bundle),before=f.files.get(first);
  const second=await f.ensure(bundle,['ohos.permission.SYSTEM_FLOAT_WINDOW']);
  assert.notEqual(second,first);assert.equal(f.files.get(first),before);
  assert.equal(f.profile.valid(second,bundle,f.udid,f.identity.certificatePath,['ohos.permission.SYSTEM_FLOAT_WINDOW']),true);
  assert.equal(await f.ensure(bundle,['ohos.permission.SYSTEM_FLOAT_WINDOW']),second);
  assert.equal(f.posts.length,2);assert.equal([...f.files.keys()].filter(p=>p.endsWith('.p7b')).length,2);
});
test('expired files are retained but a valid replacement is selected for future signing', async () => {
  const f=fixture(),bundle='com.example.first',first=await f.ensure(bundle),before=f.files.get(first);
  f.now+=86400000;
  const second=await f.ensure(bundle);assert.notEqual(second,first);assert.equal(f.files.get(first),before);
  assert.equal(f.profile.valid(first,bundle,f.udid,f.identity.certificatePath,[]),false);
  assert.equal(await f.ensure(bundle),second);assert.equal(f.posts.length,2);
});
test('legacy authorization migrates atomically and keeps its original job reference', async () => {
  const f=fixture(),bundle='com.example.first',first=await f.ensure(bundle),bytes=f.files.get(first);
  const legacy='/sandbox/signing-profiles/'+bundle+'-123-'+f.udid.slice(0,12).toLowerCase()+'.p7b';
  f.files.delete(first);f.files.set(legacy,bytes);
  const restarted=fixture();restarted.files=new Map(f.files);
  assert.equal(await restarted.ensure(bundle),first);assert.equal(restarted.files.get(legacy),bytes);
  assert.equal(restarted.posts.length,0);assert.equal(restarted.reads,0);
  assert.equal([...restarted.files.keys()].some(p=>p.endsWith('.part')),false);
});
test('ordinary installation chooses the longest matching local authorization without AGC calls', async () => {
  const f=fixture(),bundle='com.example.first',first=await f.ensure(bundle),expiry=f.profile.profileExpiry(first);
  f.now+=120000;const newer=await f.ensure(bundle,[],f.refresh('renew',expiry));
  const restarted=fixture();restarted.now=f.now;restarted.files=new Map(f.files);
  assert.equal(await restarted.ensure(bundle),newer);assert.equal(restarted.posts.length,0);
});
test('same shortened UDID cannot reuse a Profile issued to another full device UDID', async () => {
  const f=fixture(),bundle='com.example.first',first=await f.ensure(bundle),before=f.files.get(first);
  f.udid='A'.repeat(12)+'B'.repeat(52);
  const second=await f.ensure(bundle);assert.notEqual(first,second);assert.equal(f.files.get(first),before);
  assert.equal(f.posts.length,2);
});
test('download rejection of a receipt-free response leaves no signed material to reuse', async () => {
  const f=fixture();f.noReceipt=true;f.omitAcl=true;
  await assert.rejects(()=>f.ensure('com.example.first',['ohos.permission.SYSTEM_FLOAT_WINDOW']),/不匹配/);
  assert.equal(f.releases.length,0);assert.equal([...f.files.keys()].some(p=>p.endsWith('.p7b')||p.endsWith('.part')),false);
});
