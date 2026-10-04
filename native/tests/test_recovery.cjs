// Run: node --test native/tests/test_recovery.cjs
// Executes the production ArkTS service classes with deterministic SDK adapters.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const KEY = '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----';
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}, globals = {}) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, { exports, require: n => mocks[n] || (n === './InstallTaskState' ?
    load('jobs/InstallTaskState.ets', { './InstallJob': load('jobs/InstallJob.ets') }) :
    n === './ServiceFailure' ? load('data/ServiceFailure.ets') :
    n === '../jobs/InstallJob' ? load('jobs/InstallJob.ets') :
    n === './JobCancellation' ? load('jobs/JobCancellation.ets') :
    n === './BackgroundInstallTask' ? load('jobs/BackgroundInstallTask.ets') : {}),
    setTimeout, clearTimeout, console, AppStorage: { get: () => 0, setOrCreate() {} }, ...globals });
  return exports;
}
function preferences() {
  const stores = new Map();
  return { async getPreferences(_context, name) {
    if (!stores.has(name)) stores.set(name, new Map());
    const data = stores.get(name);
    return { get: async (k, fallback) => data.has(k) ? data.get(k) : fallback,
      put: async (k, v) => data.set(k, v), clear: async () => data.clear(), flush: async () => {} };
  } };
}
async function fixture({ expiry = 1, backup = true, key = true,
  allowGeneration = false } = {}) {
  const context = { filesDir: '/sandbox' }, account = { userId: '42' };
  const dir = '/sandbox/signing-identity', keyPath = dir + '/identity.pem';
  const identity = { accountId: '42', certId: '100', privateKeyPath: keyPath,
    certificatePath: dir + '/identity.cer', certExpiry: expiry };
  const files = new Map([[dir, ''], [identity.certificatePath, 'cert100']]);
  if (key) files.set(keyPath, KEY);
  const prefs = preferences();
  await (await prefs.getPreferences(context, 'signing-identity')).put('identity', JSON.stringify(identity));
  const state = { creates: 0, generated: 0, cloudReads: 0, acknowledged: [], published: [], certNames: [],
    rows: [{ id: '100', certType: 1, expireTime: expiry, certObjectId: 'cert100' }],
    backup: backup ? { certId: '100', privateKeyPem: KEY, revision: 1 } : undefined };
  const io = { OpenMode: { CREATE: 64, WRITE_ONLY: 1, TRUNC: 512 },
    accessSync: p => files.has(p), mkdirSync: p => files.set(p, ''),
    readTextSync: p => { if (!files.has(p)) throw Error('missing file'); return files.get(p); },
    openSync: p => ({ fd: p }), writeSync: (p, bytes) => files.set(p, bytes),
    fsyncSync: () => {}, closeSync: () => {}, unlinkSync: p => files.delete(p),
    copyFile: async (a, b) => { if (!files.has(a)) throw Error('missing source'); files.set(b, files.get(a)); },
    renameSync: (a, b) => { if (!files.has(a)) throw Error('missing source'); files.set(b, files.get(a)); files.delete(a); } };
  class StoreClient {
    async signingIdentity(_account, certId = '') { state.cloudReads++; state.requestedCert = certId;
      if (state.cloudError) throw Error('offline'); if (state.cloudGate) await state.cloudGate;
      return !certId || state.backup?.certId === certId ? state.backup : undefined; }
    async rememberSigningIdentity(_account, data) { state.acknowledged.push(data.revision); }
    async publishSigningIdentity(certId, pem) { state.published.push(certId);
      if (state.publishErrorAt === certId) throw Error('backup unavailable');
      state.backup = { certId, privateKeyPem: pem, revision: 1 }; }
  }
  class AgcClient {
    async certificates() { if(state.listError)throw state.listError;return state.rows; }
    async certificateUrl(id) { return id; }
    async download(id) { if (state.downloadError) throw Error('offline'); return id; }
    async createCertificate(_csr, name) {
      state.createRequests = (state.createRequests || 0) + 1;
      if (state.createError) throw state.createError;
      if (state.rows.some(row => row.certName === name)) throw Error('duplicate certificate name');
      state.certNames.push(name);
      state.creates++;
      const created = { id: '102', certName: name, certType: 1, certObjectId: 'cert102', expireTime: 4102444800 };
      state.rows.push(created); return created;
    }
  }
  const { SigningIdentityRecovery: R, EnrollmentOptions } = load('data/SigningIdentity.ets', {
    '@kit.ArkData': { preferences: prefs }, '@kit.CoreFileKit': { fileIo: io },
    'libhap_core.so': { certificateFingerprint: cert => {
      const value = String(files.get(cert) || '');
      return value.includes('cert101') ? 'B'.repeat(64) : 'A'.repeat(64);
    }, keyMatchesCertificate: (_key, cert) => {
      if (state.probeError) throw Error('certificate unreadable');
      return files.get(cert) !== 'unrelated' && files.get(cert) !== state.unpaired;
    } }, './StoreClient': { StoreClient, BackedUpIdentity: class {} }, './AgcClient': { AgcClient },
    './DeviceIdentity': { DeviceIdentity: {
      csrFor: async pem => { assert.equal(pem, KEY); return 'csr'; },
      certNameFor: async () => 'test-cert', generate: async () => {
        state.generated++;
        if (!allowGeneration) throw Error('must preserve key');
        return { privateKeyPem: KEY, csrPem: 'csr' };
      }
    } }
  });
  return { R, EnrollmentOptions, context, account, identity, keyPath, files, state, prefs };
}

test('update selects another AGC certificate only when its leaf matches and the local key pairs', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800,
    certObjectId: 'cert101' });
  const matched = await f.R.matchingInstalledCertificate(f.context, f.account, 'B'.repeat(64));
  assert.equal(matched.certId, '101');
  assert.equal(matched.privateKeyPath, f.keyPath);
  assert.equal(f.state.creates, 0);
  const pinned = await f.R.pinForJob(f.context, matched);
  assert.equal(pinned.certificatePath, '/sandbox/signing-identity/cert-101.cer');
  assert.equal((await f.R.forJob(f.context, f.account, '101')).certId, '101');
});
test('a certificate without its private key is not a reusable update identity', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800,
    certObjectId: 'cert101' });
  f.state.unpaired = 'cert101';
  assert.equal(await f.R.matchingInstalledCertificate(f.context, f.account, 'B'.repeat(64)), undefined);
  assert.equal(f.state.creates, 0);
});
test('an unavailable certificate list is unknown rather than approval to erase data', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800,
    certObjectId: 'cert101' });
  f.state.downloadError = true;
  await assert.rejects(() => f.R.matchingInstalledCertificate(f.context, f.account,
    'B'.repeat(64)), /部分证书暂时无法核实/);
});

test('first enrollment generates a CSR without exporting the EC public key', async () => {
  const exported = [];
  const privateDer = Uint8Array.from([1, 2, 3]);
  const { DeviceIdentity } = load('data/DeviceIdentity.ets', {
    '@kit.CryptoArchitectureKit': { cryptoFramework: {
      createAsyKeyGenerator: algorithm => {
        assert.equal(algorithm, 'ECC256');
        return { generateKeyPair: async () => ({
          priKey: { getEncodedDer: format => {
            exported.push(format);
            return { data: privateDer };
          } },
          pubKey: { getEncodedDer: () => { throw Error('getEncodedDer fail401'); } }
        }) };
      }
    } },
    'libhap_core.so': { generateCsr: key => {
      assert.match(key, /^-----BEGIN PRIVATE KEY-----/);
      return '-----BEGIN CERTIFICATE REQUEST-----\nfixture';
    } },
    '@kit.ArkTS': { util: { Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    } } }
  });
  const material = await DeviceIdentity.generate();
  assert.deepEqual(exported, ['PKCS8']);
  assert.match(material.privateKeyPem, /^-----BEGIN PRIVATE KEY-----/);
  assert.match(material.csrPem, /^-----BEGIN CERTIFICATE REQUEST-----/);
  assert.match(await DeviceIdentity.csrFor(material.privateKeyPem),
    /^-----BEGIN CERTIFICATE REQUEST-----/);
});

test('reset: expired certificate is renewed with retained private key even without backup', async () => {
  const f = await fixture({ backup: false });
  await f.R.reset(f.context, f.account);
  assert.equal((await f.R.load(f.context, f.account)).certId, '102');
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.state.cloudReads, 0, 'expired local material is preserved without reading another device backup');
});
test('empty AGC certificate list: reset creates one certificate and later enrollment reuses it', async () => {
  const f = await fixture({ backup: false, key: false, allowGeneration: true });
  f.state.rows = [];
  await f.R.reset(f.context, f.account);
  assert.equal(f.state.creates, 1);
  const result = await f.R.enroll(f.context, f.account);
  assert.equal(result.identity.certId, '102');
  assert.equal(f.state.generated, 1);
  assert.equal(f.state.creates, 1);
});
test('reset: AGC failure or unpaired downloaded certificate preserves original material', async () => {
  for (const offline of [true, false]) {
    const f = await fixture({ expiry: 4102444800 }); const before = [...f.files];
    if (offline) f.state.downloadError = true; else f.state.unpaired = 'cert100';
    await assert.rejects(f.R.reset(f.context, f.account));
    assert.deepEqual([...f.files], before);
  }
});
test('reset: remotely deleted local certificate is renewed without touching other device certificates', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows = [{ id: '999', certType: 1, expireTime: 4102444800, certObjectId: 'unrelated' }];
  f.state.backup = { certId: '999', privateKeyPem: 'other-device-key', revision: 1 };
  await f.R.reset(f.context, f.account);
  assert.equal((await f.R.load(f.context, f.account)).certId, '102');
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.state.creates, 1);
  assert.equal(f.state.generated, 0);
  assert.equal(f.state.rows[0].id, '999');
});
test('reset: valid local identity refreshes through AGC without cloud backup', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.cloudError = true;
  await f.R.reset(f.context, f.account);
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.deepEqual(f.state.acknowledged, []);
  assert.equal(f.state.cloudReads, 0);
});
test('reset: another device cloud key never changes the local certificate or key', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.backup = { certId: '999', privateKeyPem: 'other-device-key', revision: 7 };
  await f.R.reset(f.context, f.account);
  assert.equal((await f.R.load(f.context, f.account)).certId, '100');
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.state.creates, 0);
  assert.equal(f.state.cloudReads, 0);
});
test('recovery: retained key with a missing index can match AGC despite another device backup', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await (await f.prefs.getPreferences(f.context, 'signing-identity')).put('identity', '');
  f.state.backup = { certId: '999', privateKeyPem: 'other-device-key', revision: 7 };
  const result = await f.R.enroll(f.context, f.account);
  assert.equal(result.identity.certId, '100');
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.state.creates, 0);
});
test('expiry: reuses another certificate without generating a key or issuing', async () => {
  const f = await fixture();
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800, certObjectId: 'cert101' });
  const result = await f.R.enroll(f.context, f.account);
  assert.equal(result.identity.certId, '101');
  assert.equal(f.state.creates, 0); assert.equal(f.state.generated, 0);
});
test('expiry: enrollment renews with retained key when no replacement exists', async () => {
  const f = await fixture();
  const result = await f.R.enroll(f.context, f.account);
  assert.equal(result.identity.certId, '102'); assert.equal(f.state.creates, 1);
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('manual renewal retains the key and issues only when no certificate can extend authorization', async () => {
  const f = await fixture({ expiry: 2000000000 });
  f.state.rows[0].certName = 'test-cert';
  const renewed = await f.R.ensureForRenewal(f.context, f.account, 2000000000);
  assert.equal(renewed.certId, '102'); assert.equal(f.state.creates, 1);
  assert.equal(f.state.generated, 0); assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.state.certNames.length, 1); assert.notEqual(f.state.certNames[0], 'test-cert');
  assert.ok(f.state.certNames[0].length <= 64); assert.match(f.state.certNames[0], /-r-/);
  const reused = await f.R.ensureForRenewal(f.context, f.account, 2000000000);
  assert.equal(reused.certId, '102'); assert.equal(f.state.creates, 1);
});
test('manual renewal reuses a sufficiently long matching certificate without occupying another slot', async () => {
  const f = await fixture({ expiry: 4102444800 });
  assert.equal((await f.R.ensureForRenewal(f.context, f.account, 2000000000)).certId, '100');
  assert.equal(f.state.creates, 0); assert.equal(f.state.generated, 0);
});
test('an AGC certificate-quota rejection during renewal leaves existing certificate and key intact', async () => {
  const f = await fixture({ expiry: 2000000000 });
  f.state.rows.push({ id: '998', certType: 1, expireTime: 2000000000, certObjectId: 'unrelated' },
    { id: '999', certType: 1, expireTime: 2000000000, certObjectId: 'unrelated' });
  f.state.createError = Error('AGC 调试证书槽位已满');
  await assert.rejects(f.R.ensureForRenewal(f.context, f.account, 2000000000), /槽位已满/);
  assert.equal(f.state.createRequests, 1);
  assert.equal(f.state.creates, 0); assert.equal(f.state.generated, 0);
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal((await f.R.load(f.context, f.account)).certId, '100');
});

async function firstInstallFixture(slotsUsed = 0) {
  const f = await fixture({ backup: false, key: false, allowGeneration: true });
  f.state.rows = Array.from({ length: slotsUsed }, (_, i) => ({ id: String(200 + i),
    certType: 1, certObjectId: 'unrelated', expireTime: 4102444800 }));
  return f;
}
test('first installation automatically creates one identity and subsequent applications reuse it', async () => {
  const f = await firstInstallFixture();
  const first = await f.R.ensureForInstall(f.context, f.account);
  const second = await f.R.ensureForInstall(f.context, f.account);
  assert.equal(first.certId, '102'); assert.equal(second.certId, '102');
  assert.equal(f.state.generated, 1); assert.equal(f.state.creates, 1);
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('automatic preparation can use the final free slot without an extra user confirmation', async () => {
  const f = await firstInstallFixture(2);
  const identity = await f.R.ensureForInstall(f.context, f.account);
  assert.equal(identity.certId, '102'); assert.equal(f.state.creates, 1);
  assert.equal(f.state.rows.length, 3);
});
test('a rejected request is reported without deleting unrelated certificates or changing the key', async () => {
  const f = await firstInstallFixture(3); const before = JSON.stringify(f.state.rows);
  f.state.createError = Error('AGC 调试证书槽位已满');
  await assert.rejects(() => f.R.ensureForInstall(f.context, f.account), /槽位已满/);
  assert.equal(f.state.creates, 0); assert.equal(JSON.stringify(f.state.rows), before);
  assert.equal(f.state.createRequests, 1); assert.equal(f.files.get(f.keyPath), KEY);
});
test('four existing certificates do not impose a client-invented quota on a permitted AGC request', async () => {
  const f = await firstInstallFixture(4);
  assert.equal((await f.R.ensureForInstall(f.context, f.account)).certId, '102');
  assert.equal(f.state.creates, 1); assert.equal(f.state.rows.length, 5);
  assert.equal(f.state.generated, 1);
});
test('concurrent automatic preparation shares one generated key and one certificate', async () => {
  const f = await firstInstallFixture();
  const identities = await Promise.all([f.R.ensureForInstall(f.context, f.account),
    f.R.ensureForInstall(f.context, f.account)]);
  assert.equal(identities[0].certId, identities[1].certId);
  assert.equal(f.state.creates, 1); assert.equal(f.state.generated, 1);
});
test('installation waits for manual preparation and reuses its completed identity', async () => {
  const f = await firstInstallFixture();
  const [manual, automatic] = await Promise.all([f.R.enroll(f.context, f.account),
    f.R.ensureForInstall(f.context, f.account)]);
  assert.equal(manual.identity.certId, automatic.certId);
  assert.equal(f.state.creates, 1); assert.equal(f.state.generated, 1);
});
test('uncertain backup availability during automatic preparation never consumes a certificate slot', async () => {
  const f = await firstInstallFixture(); f.state.cloudError = true;
  await assert.rejects(() => f.R.ensureForInstall(f.context, f.account), /暂时无法核实/);
  assert.equal(f.state.creates, 0); assert.equal(f.state.generated, 0);
});
test('retry after a newly issued certificate download fails recovers that certificate without issuing twice', async () => {
  const f = await firstInstallFixture(); f.state.downloadError = true;
  await assert.rejects(() => f.R.ensureForInstall(f.context, f.account), /offline/);
  assert.equal(f.state.creates, 1); assert.equal(f.state.generated, 1);
  f.state.downloadError = false;
  const identity = await f.R.ensureForInstall(f.context, f.account);
  assert.equal(identity.certId, '102'); assert.equal(f.state.creates, 1);
  assert.equal(f.state.generated, 1);
});
test('renewal before expiry skips the expiring certificate', async () => {
  const expiry = Math.floor(Date.now() / 1000) + 3600;
  const f = await fixture({ expiry }); const options = new f.EnrollmentOptions();
  options.renewBeforeSeconds = expiry + 1;
  const result = await f.R.enroll(f.context, f.account, options);
  assert.equal(result.identity.certId, '102');
  assert.deepEqual(f.state.published, ['100']);
});
test('temporary backup/download/probe errors never allocate a slot', async () => {
  for (const field of ['cloudError', 'downloadError', 'probeError']) {
    const f = await fixture();
    f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800, certObjectId: 'cert101' });
    f.state[field] = true;
    await assert.rejects(f.R.enroll(f.context, f.account));
    assert.equal(f.state.creates, 0);
  }
});
test('delete flow: a certificate without a local private key can still free a slot', async () => {
  const f = await fixture({ key: false, expiry: 4102444800 });
  assert.equal(await f.R.prepareCertificateDeletion(f.context, f.account, '100'), undefined);
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  await f.R.finishCertificateDeletion(f.context, f.account, '100');
  assert.equal(f.files.has(f.identity.certificatePath), false);
});
test('activation: can replace expired local certificate while retaining private key', async () => {
  const f = await fixture();
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800, certObjectId: 'cert101' });
  const result = await f.R.activate(f.context, f.account, '101');
  assert.equal(result.certId, '101'); assert.deepEqual(f.state.published, ['100']);
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('delete flow: expired cached in-use identity can release a slot without deleting its key', async () => {
  const f = await fixture();
  const current = await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  assert.equal(current.certId, '100');
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  await f.R.finishCertificateDeletion(f.context, f.account, '100');
  assert.equal(await f.R.load(f.context, f.account, true), undefined);
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('delete flow: last active certificate can be removed and renewed with the same private key', async () => {
  const f = await fixture({ expiry: 4102444800 });
  const current = await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  assert.equal(current.certId, '100');
  assert.deepEqual(f.state.published, ['100']);
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  assert.equal(await f.R.load(f.context, f.account), undefined);
  f.state.rows = []; // AGC confirmed the deletion.
  await f.R.finishCertificateDeletion(f.context, f.account, '100');
  assert.equal(f.files.get(f.keyPath), KEY);
  assert.equal(f.files.has(f.identity.certificatePath), false);
  const renewed = await f.R.enroll(f.context, f.account);
  assert.equal(renewed.identity.certId, '102');
  assert.equal(f.state.generated, 0);
  assert.equal(f.state.creates, 1);
});
test('delete flow: stale AGC listings cannot revive a deleted certificate', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  await f.R.finishCertificateDeletion(f.context, f.account, '100');
  // AGC 的读取接口仍短暂返回旧证书，删除墓碑必须继续挡住它。
  assert.equal(await f.R.restore(f.context, f.account), undefined);
  const renewed = await f.R.enroll(f.context, f.account);
  assert.equal(renewed.identity.certId, '102');
  assert.equal(f.state.creates, 1);
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('delete flow: interrupted deletion never allocates a second slot while old cert remains', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  f.R.deletingCert = ''; // Simulate a process restart before AGC confirms deletion.
  await assert.rejects(f.R.enroll(f.context, f.account), /删除尚未确认/);
  assert.equal(f.state.creates, 0);
  f.state.rows = [];
  const renewed = await f.R.enroll(f.context, f.account);
  assert.equal(renewed.identity.certId, '102');
  assert.equal(f.state.generated, 0);
  assert.equal(f.state.creates, 1);
});
test('delete flow: rejected AGC deletion restores the existing certificate', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  await f.R.beginCertificateDeletion(f.context, f.account, '100');
  await f.R.cancelCertificateDeletion(f.context, f.account, '100');
  assert.equal((await f.R.load(f.context, f.account)).certId, '100');
  assert.equal(f.files.get(f.keyPath), KEY);
});
test('delete flow: switches and backs up replacement before permitting deletion', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800, certObjectId: 'cert101' });
  const current = await f.R.prepareCertificateDeletion(f.context, f.account, '100');
  assert.equal(current.certId, '101');
  assert.deepEqual(f.state.published, ['100', '101']);
});
test('delete flow: retry after failed backup cannot delete the old certificate', async () => {
  const f = await fixture({ expiry: 4102444800 });
  f.state.rows.push({ id: '101', certType: 1, expireTime: 4102444800, certObjectId: 'cert101' });
  f.state.publishErrorAt = '101';
  await assert.rejects(f.R.prepareCertificateDeletion(f.context, f.account, '100'), /backup unavailable/);
  await assert.rejects(f.R.prepareCertificateDeletion(f.context, f.account, '100'), /backup unavailable/);
  assert.deepEqual(f.state.published, ['100', '101', '101']);
});
test('scheduler: timeout never unlocks live work, even after every timer fires', async () => {
  const timers = [];
  let now = 0;
  const { JobScheduler: S } = load('jobs/JobScheduler.ets', {}, {
    Date: { now: () => now },
    setTimeout: (fn, delay) => (timers.push(() => { now += delay; fn(); }), timers.length),
    clearTimeout: () => {}
  });
  let finish; const gate = new Promise(r => finish = r); let writes = 0;
  const running = S.runExclusive('same', async () => { await gate; writes++; }, 1);
  const rejected = assert.rejects(running, /超时/);
  await new Promise(setImmediate); timers.shift()(); await rejected;
  while (timers.length) timers.shift()();
  assert.equal(S.isRunning('same'), true);
  await assert.rejects(S.runExclusive('same', async () => { writes++; }), /收尾/);
  finish(); await new Promise(setImmediate);
  assert.equal(S.isRunning('same'), false); assert.equal(writes, 1);
  await S.runExclusive('same', async () => {});
});
test('scheduler: synchronous failure releases the lock', async () => {
  const { JobScheduler: S } = load('jobs/JobScheduler.ets');
  await assert.rejects(S.runExclusive('sync', () => { throw Error('sync failure'); }));
  assert.equal(S.isRunning('sync'), false);
});
async function clientFixture() {
  const prefs = preferences();
  const { StoreClient: C } = load('data/StoreClient.ets', { '@kit.ArkData': { preferences: prefs }, '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' } } } });
  const c = Object.create(C.prototype); c.context = {};
  return { c, account: { userId: '42' }, prefs };
}
test('backup: certificate-scoped upload never sends a stale global replacement condition', async () => {
  const { c, account, prefs } = await clientFixture();
  await c.rememberSigningIdentity(account, { certId: '100', revision: 1 });
  const calls = [];
  c.requestData = async (_url, _method, _account, body) => { calls.push(body); throw Error('conflict'); };
  await assert.rejects(c.publishSigningIdentity('101', 'key', account));
  const raw = await (await prefs.getPreferences({}, 'signing-backup-version')).get('42:100', '');
  assert.equal(JSON.parse(raw).revision, 1);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].backup_scope, 'certificate');
  assert.equal(calls[0].replace_cert_id, undefined);
  assert.equal(calls[0].replace_revision, undefined);
});
test('backup: failed acknowledgement is rejected instead of clearing warning', async () => {
  const { c, account } = await clientFixture();
  c.requestData = async () => ({ synced: false, cert_id: '999', revision: 4 });
  await assert.rejects(c.publishSigningIdentity('101', 'key', account));
});

test('startup recovery and automatic enrollment share the same slow backup read', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await (await f.prefs.getPreferences(f.context, 'signing-identity')).put('identity', '');
  let finish;
  f.state.cloudGate = new Promise(resolve => { finish = resolve; });
  const startup = f.R.restore(f.context, f.account);
  const automatic = f.R.ensureForInstall(f.context, f.account);
  await new Promise(setImmediate);
  assert.equal(f.state.cloudReads, 1, 'no duplicate recovery while the first read is pending');
  finish();
  const [recovered, installed] = await Promise.all([startup, automatic]);
  assert.equal(recovered.certId, '100');
  assert.equal(installed.certId, '100');
  assert.equal(f.state.creates, 0);
});

test('a failed shared recovery is released so the same process can retry', async () => {
  const f = await fixture({ expiry: 4102444800 });
  await (await f.prefs.getPreferences(f.context, 'signing-identity')).put('identity', '');
  f.state.cloudError = true;
  await assert.rejects(f.R.restore(f.context, f.account), /offline/);
  f.state.cloudError = false;
  assert.equal((await f.R.ensureForInstall(f.context, f.account)).certId, '100');
  assert.equal(f.state.creates, 0);
});

test('a remotely deleted cached certificate is automatically replaced with the original private key',async()=>{
 const f=await fixture({expiry:4102444800});f.state.rows=[];f.state.cloudError=true;
 assert.equal((await f.R.load(f.context,f.account)).certId,'100');
 const identity=await f.R.recoverRejectedCertificate(f.context,f.account,'100');
 assert.equal(identity.certId,'102');assert.equal(f.files.get(f.keyPath),KEY);
 assert.equal(f.state.generated,0);assert.equal(f.state.creates,1);assert.equal(f.state.cloudReads,0);
 assert.equal((await f.R.load(f.context,f.account)).certId,'102');
});
test('missing certificate recovery reuses a matching surviving certificate before applying for one',async()=>{
 const f=await fixture({expiry:4102444800});
 f.state.rows=[{id:'101',certType:1,expireTime:4102444800,certObjectId:'cert101'}];
 const identity=await f.R.recoverRejectedCertificate(f.context,f.account,'100');
 assert.equal(identity.certId,'101');assert.equal(f.state.creates,0);assert.equal(f.state.generated,0);
 assert.equal(f.files.get(f.keyPath),KEY);
});
test('simultaneous missing certificate recoveries share one replacement',async()=>{
 const f=await fixture({expiry:4102444800});f.state.rows=[];
 const rows=await Promise.all([1,2,3].map(()=>f.R.recoverRejectedCertificate(f.context,f.account,'100')));
 assert.ok(rows.every(r=>r.certId==='102'));assert.equal(f.state.creates,1);assert.equal(f.state.generated,0);
 const again=await f.R.recoverRejectedCertificate(f.context,f.account,'100');
 assert.equal(again.certId,'102');assert.equal(f.state.creates,1);
});
test('a contradictory AGC list never allocates a replacement or overwrites the key',async()=>{
 const f=await fixture({expiry:4102444800});
 await assert.rejects(f.R.recoverRejectedCertificate(f.context,f.account,'100'),e=>e.failureKind==='transient');
 assert.equal(f.state.creates,0);assert.equal(f.state.generated,0);assert.equal(f.files.get(f.keyPath),KEY);
});
test('recovery preserves network and certificate-quota classifications without losing material',async()=>{
 const {ServiceFailure}=load('data/ServiceFailure.ets');
 for(const field of ['listError','createError']){
  const f=await fixture({expiry:4102444800});f.state.rows=[];
  const kind=field==='listError'?'network':'certificate_limit';
  f.state[field]=new ServiceFailure(kind,'temporary failure',999);
  await assert.rejects(f.R.recoverRejectedCertificate(f.context,f.account,'100'),e=>e.failureKind===kind);
  assert.equal(f.state.creates,0);assert.equal(f.state.generated,0);assert.equal(f.files.get(f.keyPath),KEY);
 }
});
