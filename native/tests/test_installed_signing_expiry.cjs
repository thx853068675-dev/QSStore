const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture() {
  const f = { fingerprint: 'A'.repeat(64), profileEnd: 1900000000, profileBefore: 1799900000,
    certTime: '290101000000Z', digest: 'b'.repeat(64), reads: 0, paths: ['/private/app.p7b'] };
  f.live = { name: 'com.example.app', versionCode: 7, updateTime: 1800000000000,
    signatureInfo: { fingerprint: f.fingerprint } };
  const identity = { exports: {}, require: () => ({}) };
  const folder = path.join(__dirname, '../entry/src/main/ets/jobs');
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(folder, 'InstallJob.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, identity);
  const mocks = {
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_WITH_SIGNATURE_INFO: 1 },
      getBundleInfoForSelfSync: () => ({ name: 'self' }), getBundleInfoSync: () => { if (f.unavailable) throw Object.assign(Error('query denied'), { code: f.errorCode || 201 }); return f.live; } } },
    '@kit.ArkTS': { util: { Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } } } },
    '@kit.DeviceCertificateKit': { cert: { EncodingFormat: { FORMAT_DER: 0 }, createX509Cert: async () => ({ getNotAfterTime: () => f.certTime }) } },
    '@kit.CoreFileKit': { hash: { hash: async () => f.digest } },
    'libhap_core.so': { readSignedProfile: () => { f.reads++; return JSON.stringify({
      'bundle-info': { 'bundle-name': f.profileBundle || 'com.example.app', 'app-identifier': f.profileIdentifier || '',
        'development-certificate': '-----BEGIN CERTIFICATE-----YQ==-----END CERTIFICATE-----' },
      validity: { 'not-before': f.profileBefore, 'not-after': f.profileEnd }
    }); } },
    '../data/AgcProfile': { AgcProfile: { signingFingerprint: async () => f.fingerprint } },
    '../data/LocalProfileStore': { LocalProfileStore: { retainedFiles: () => f.paths } },
    './InstallJob': identity.exports, './InstalledAppRegistry': { InstalledSigningIdentity: class {}, InstalledAppRegistry: {
      signingIdentity: () => f.cached, installationTime: () => f.installationTime || 0 } }
  };
  const box = { exports: {}, require: name => mocks[name] || {}, setTimeout };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(folder, 'InstalledSigningExpiry.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  f.Expiry = box.exports.InstalledSigningExpiry;
  f.job = new identity.exports.InstallJob();
  Object.assign(f.job, { bundleName: 'com.example.app', versionCode: 7, stage: identity.exports.InstallStage.INSTALLED,
    profilePath: '/private/app.p7b', signedProfileSha256: f.digest, stageHistory: [{ stage: 'installed', at: f.live.updateTime + 500 }] });
  return f;
}
test('expiry is the earlier of the verified Profile and its actual leaf certificate, with bounded decode reuse', async () => {
  const f = fixture();
  assert.equal(await f.Expiry.profileExpiry(f.job), Date.UTC(2029, 0, 1) / 1000);
  assert.equal(await f.Expiry.profileExpiry(f.job), Date.UTC(2029, 0, 1) / 1000); assert.equal(f.reads, 1);
  const b = fixture(); b.profileEnd = 1800000000; assert.equal(await b.Expiry.profileExpiry(b.job), b.profileEnd);
});
test('invalid ASN.1 dates, overwritten material and another bundle never invent a deadline', async () => {
  const f = fixture();
  assert.equal(f.Expiry.asn1Seconds('491231235959Z'), Date.UTC(2049, 11, 31, 23, 59, 59) / 1000);
  assert.equal(f.Expiry.asn1Seconds('20500101000000Z'), Date.UTC(2050, 0, 1) / 1000);
  for (const value of ['300229000000Z', '301301000000Z', 'not a time']) assert.equal(f.Expiry.asn1Seconds(value), 0);
  f.digest = 'c'.repeat(64); assert.equal(await f.Expiry.profileExpiry(f.job), 0);
  f.digest = f.job.signedProfileSha256; f.profileBundle = 'other.bundle'; assert.equal(await f.Expiry.profileExpiry(f.job), 0);
});
test('capture seals the expiry to the exact installed build; external reinstall, new signature and unknown permission invalidate it', async () => {
  const f = fixture(); await f.Expiry.capture(f.job, { versionCode: 7, updateTime: f.live.updateTime, fingerprint: f.fingerprint });
  assert.ok(f.job.authorizationExpiresAt > 0); assert.equal(f.job.installedUpdateTime, f.live.updateTime);
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), f.job.authorizationExpiresAt);
  f.live.updateTime++; assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
  f.live.updateTime--; f.live.signatureInfo.fingerprint = 'C'.repeat(64); assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
  f.live.signatureInfo.fingerprint = f.fingerprint; f.unavailable = true; assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
});
test('legacy completion migrates only matching material near its immutable install stage mark', async () => {
  const f = fixture(); assert.ok(await f.Expiry.read(f.job.bundleName, 7, [f.job]) > 0);
  f.live.updateTime += 1000; assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
  assert.equal(await f.Expiry.read(f.job.bundleName, 8, [f.job]), 0);
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, []), 0);
});
test('seven-day and expired authorization are highlighted; unknown and later deadlines are not', () => {
  const f = fixture(), now = 1800000000;
  assert.equal(f.Expiry.dueSoon(now + 7 * 86400, now), true);
  assert.equal(f.Expiry.dueSoon(now + 7 * 86400 + 1, now), false);
  assert.equal(f.Expiry.dueSoon(now - 1, now), true);
  for (const expiry of [0, -1, NaN, Infinity]) assert.equal(f.Expiry.dueSoon(expiry, now), false);
  assert.match(f.Expiry.label(0), /^预计到期 \d{4}-\d{2}-\d{2}$/); assert.match(f.Expiry.label(now), /^到期 /);
});

test('unsealed matching local material supplies a labelled estimate without becoming verified expiry', async () => {
  const f = fixture();
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, []), 0);
  const materials = await f.Expiry.estimateMaterials({}, [f.job.bundleName]);
  const estimate = f.Expiry.estimate(f.job.bundleName, 7, materials);
  assert.equal(estimate, Date.UTC(2029, 0, 1) / 1000);
  assert.match(f.Expiry.label(0, estimate), /^预计到期 /);
  assert.match(f.Expiry.label(1800000000, estimate), /^到期 /);
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, []), 0, 'display estimates must never become confirmed authorization');
  assert.equal(f.job.authorizationExpiresAt, 0);
});

test('an estimate rejects foreign certificates, other bundles and material created after the installed build', async () => {
  const f = fixture(), materials = await f.Expiry.estimateMaterials({}, [f.job.bundleName]);
  assert.equal(f.Expiry.estimate('com.other.app', 7, materials), 0);
  assert.equal(f.Expiry.estimate(f.job.bundleName, 8, materials), 0);
  f.live.signatureInfo.fingerprint = 'C'.repeat(64);
  const defaultEstimate = Math.floor(f.live.updateTime / 1000) + 365 * 86400;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, materials), defaultEstimate);
  f.live.signatureInfo.fingerprint = f.fingerprint;
  materials[0].notBefore = f.live.updateTime / 1000 + 1;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, materials), defaultEstimate);
  materials[0].notBefore = f.profileBefore; materials[0].expiresAt = f.live.updateTime / 1000;
  assert.ok(f.Expiry.estimate(f.job.bundleName, 7, materials) > materials[0].expiresAt);
});

test('ambiguous matching Profiles use the earliest estimate and respect application identity', async () => {
  const f = fixture(); f.profileEnd = 1800500000;
  const materials = await f.Expiry.estimateMaterials({}, [f.job.bundleName]);
  const later = { ...materials[0], expiresAt: materials[0].expiresAt + 86400 };
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [later, ...materials]), materials[0].expiresAt);
  later.notBefore = materials[0].notBefore + 1;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [later, ...materials]), later.expiresAt,
    'the closest authorization created before this install beats an older candidate');
  f.live.signatureInfo.appIdentifier = 'actual-app';
  materials[0].appIdentifier = 'another-app';
  assert.ok(f.Expiry.estimate(f.job.bundleName, 7, materials) > materials[0].expiresAt);
});

test('offline estimates use matching scanned identity; confirmed uninstall blocks older cached identity', async () => {
  const f = fixture(), materials = await f.Expiry.estimateMaterials({}, [f.job.bundleName]);
  f.unavailable = true;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, materials), 0);
  f.cached = { versionCode: 7, updateTime: f.live.updateTime, fingerprint: f.fingerprint };
  assert.ok(f.Expiry.estimate(f.job.bundleName, 7, materials) > 0);
  f.errorCode = 17700001;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, materials), 0);
});

test('without matching material, display estimates use the installed time plus the explicit 365-day default', async () => {
  const f = fixture(); f.paths = [];
  assert.deepEqual(Array.from(await f.Expiry.estimateMaterials({}, [f.job.bundleName])), []);
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, []), Math.floor(f.live.updateTime / 1000) + 365 * 86400);
  assert.equal(f.Expiry.label(0, NaN, Date.UTC(2026, 9, 4)), '预计到期 2027-10-04');
  f.paths = ['/private/app.p7b']; f.profileBefore = 0;
  assert.equal((await f.Expiry.estimateMaterials({}, [f.job.bundleName])).length, 0);
  f.profileBefore = 1799900000; f.profileBundle = 'com.other.app';
  assert.equal((await f.Expiry.estimateMaterials({}, [f.job.bundleName])).length, 1, 'same-certificate other apps can supply certificate expiry and observed duration');
});

test('same-certificate observed duration beats the default, is capped by cert expiry, and never borrows a foreign key', () => {
  const f = fixture(), installedAt = Math.floor(f.live.updateTime / 1000);
  const material = { bundleName:'com.other.app', fingerprint:f.fingerprint, notBefore:installedAt - 1000,
    expiresAt:installedAt + 5000, certificateExpiresAt:installedAt + 90 * 86400, durationSeconds:14 * 86400 };
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [material]), installedAt + 14 * 86400);
  material.certificateExpiresAt = installedAt + 7 * 86400;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [material]), material.certificateExpiresAt);
  material.fingerprint = 'C'.repeat(64);
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [material]), installedAt + 365 * 86400);
});

test('offline fallback prefers durable installation evidence to a changing task timestamp', () => {
  const f = fixture(); f.unavailable = true; f.installationTime = 1700000000000;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [], 1800000000000), 1700000000 + 365 * 86400);
  f.installationTime = 0;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [], 1800000000000), 1800000000 + 365 * 86400);
  f.errorCode = 17700001;
  assert.equal(f.Expiry.estimate(f.job.bundleName, 7, [], 1800000000000), 0, 'confirmed uninstall cannot inherit an estimate');
});

function managementFixture() {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const methods = ['loadSigningExpiries', 'renewalLabel', 'renewalDueSoon'].map(name => {
    const begin = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
    assert.ok(begin >= 0); return source.slice(begin, source.indexOf('\n  }', begin) + 4);
  }).join('\n');
  const f = { batches: [], exact: 1800000000, estimate: 1800001000 };
  const expiry = { read: async bundle => bundle === 'com.exact.app' ? f.exact : 0,
    estimateMaterials: async (_context, bundles) => { f.batches.push(Array.from(bundles)); if (f.wait) await f.wait; return []; },
    estimate: () => f.estimate, label: (exact, estimate) => exact ? '到期' : estimate ? '预计到期' : '待确认',
    dueSoon: value => value > 0 };
  const box = { InstalledSigningExpiry: expiry, getContext: () => ({}),
    InstalledAppRegistry: { installationTime: () => 1800000000000 }, InstallStage: { INSTALLED: 'installed' } };
  vm.runInNewContext(ts.transpileModule('class Page {' + methods + '}; globalThis.Page = Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  f.ui = new box.Page(); Object.assign(f.ui, { expiryReadToken: 0, installedJobs: [],
    signingExpiries: new Map(), signingExpiryEstimates: new Map(),
    allInstalledJobs: () => [{ bundleName: 'com.exact.app', versionCode: 7, stageHistory:[], updatedAt:1800000000000 },
      { bundleName: 'com.estimated.app', versionCode: 8, stageHistory:[], updatedAt:1800000000000 }] });
  return f;
}

test('management estimates unresolved apps in one offline batch and never treats estimates as verified renewal triggers', async () => {
  const f = managementFixture(); await f.ui.loadSigningExpiries();
  assert.deepEqual(f.batches, [['com.estimated.app']]);
  assert.equal(f.ui.renewalLabel({ bundleName: 'com.exact.app' }), '到期');
  assert.equal(f.ui.renewalLabel({ bundleName: 'com.estimated.app' }), '预计到期');
  assert.equal(f.ui.renewalDueSoon({ bundleName: 'com.estimated.app' }), false);
  assert.equal(f.ui.signingExpiries.get('com.estimated.app'), 0);
});

test('a superseded management read cannot publish estimates for an older device inventory', async () => {
  const f = managementFixture(); let release; f.wait = new Promise(resolve => release = resolve);
  const work = f.ui.loadSigningExpiries();
  await new Promise(setImmediate); f.ui.expiryReadToken++; release(); await work;
  assert.equal(f.ui.signingExpiries.size, 0); assert.equal(f.ui.signingExpiryEstimates.size, 0);
});

test('offline display can reuse a scanned identity but never infer expiry from version alone', async () => {
  const f = fixture(); f.unavailable = true;
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
  f.cached = { versionCode: 7, updateTime: f.live.updateTime, fingerprint: f.fingerprint };
  assert.ok(await f.Expiry.read(f.job.bundleName, 7, [f.job]) > 0);
  f.cached.updateTime += 5000; assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0);
  f.cached.updateTime -= 5000; f.errorCode = 17700001;
  assert.equal(await f.Expiry.read(f.job.bundleName, 7, [f.job]), 0, 'confirmed uninstall beats cached signature');
});
