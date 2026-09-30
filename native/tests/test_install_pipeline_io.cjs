const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function loadRuntime(mocks) {
  mocks['./InstallTaskState'] = { InstallTaskState: { installProgress: () => {} } };
  const file = path.join(__dirname, '../entry/src/main/ets/jobs/NativeJobRuntime.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: name => mocks[name] || {} });
  return exports.NativeJobRuntime;
}

function fixture(installedVersion = 0, selfUpdate = false,
  matchingIdentity = false, matchingAppIdentifier = false, installedIdentity = undefined,
  alternateCertificate = false, backupFails = false) {
  const calls = { hapHashes: 0, profileHashes: 0, nativeSigns: 0,
    nativeVerifies: 0, installedPath: '', uninstalls: 0, selfStaged: '',
    selectedCertId: '', identityBackups: 0 };
  let deviceVersion = installedVersion;
  const job = {
    sourceUrl: 'local', assetName: 'installer-signed.hap',
    cachePath: '/private/source.hap', signedPath: '/private/signed.hap',
    expectedSha256: 'abc', profilePath: selfUpdate ? '' : '/private/profile.p7b',
    profileSha256: selfUpdate ? '' : 'profile',
    signedProfileSha256: '', deviceUdid: '', bundleName: 'com.example.app', versionCode: 7,
    signingCertId: '', allowDataLoss: false
  };
  const originalIdentity = { bundleName: job.bundleName, versionCode: job.versionCode };
  const mocks = {
    './JobCancellation': { JobCancellation: { assertActive: () => {
      if (calls.cancelled) throw new Error('安装任务已取消');
    } } },
    './InstallJob': { InstallStage: { INSTALLING: 'installing', INSTALLED: 'installed' },
      FailureKind: { INVALID_PACKAGE: 'invalid_package' },
      RecoveryEvidence: class {
      verifiedCache = false; validProfile = false; verifiedSignature = false;
      installedVersionCode = 0;
    } },
    './LocalBundles': { LocalBundles: { liveInstalledVersion: () => installedVersion,
      isSelfBundle: () => selfUpdate, selfSigningFingerprint: () => 'A'.repeat(64),
      selfAppIdentifier: () => 'installed-app-id' } },
    './InstalledAppRegistry': { InstalledSigningIdentity: class {
      fingerprint = ''; appIdentifier = ''; versionCode = 0;
    } },
    '../data/AgcProfile': { AgcProfile: {
      signingFingerprint: async () => matchingIdentity ? 'A'.repeat(64) : 'B'.repeat(64),
      appIdentifier: () => matchingIdentity || matchingAppIdentifier ?
        'installed-app-id' : 'other-app-id',
      valid: () => true, effectiveAcls: () => [],
      ensure: async (_context, _account, identity) => {
        calls.selectedCertId = identity.certId;
        return '/private/profile.p7b';
      }
    } },
    '@kit.CoreFileKit': {
      fileIo: { accessSync: () => true, readTextSync: () => 'private key' },
      hash: { hash: async file => {
        if (file === job.cachePath) { calls.hapHashes++; return 'abc'; }
        calls.profileHashes++; return 'profile';
      } }
    },
    'libhap_core.so': {
      hasSigningBlock: () => !job.assetName.includes('unsigned'),
      signHap: async () => { calls.nativeSigns++; },
      verifyHap: async () => {
        calls.nativeVerifies++;
        if (calls.invalidWorker) throw new Error('QuietStart worker device profile differs from main HAP');
      }
    },
    '../data/SigningIdentity': { SigningIdentityRecovery: {
      load: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      restore: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      forJob: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      matchingInstalledCertificate: async () => alternateCertificate ?
        { certId: '2', privateKeyPath: '/private/key', certificatePath: '/private/cert-2' } : undefined,
      pinForJob: async (_context, identity) => identity
    } },
    '../data/StoreClient': { StoreClient: class {
      async publishSigningIdentity() {
        calls.identityBackups++;
        if (backupFails) throw new Error('backup offline');
      }
    } },
    './AssetDownload': { AssetDownload: class {
      async verifiedFileExists(value) {
        calls.hapHashes++;
        return value.expectedSha256 === 'abc';
      }
    } },
    './PackageInspector': { inspectPackage: () => originalIdentity,
      requestedPermissions: () => [] },
    './JobRunner': { JobFailure: class extends Error {
      constructor(_kind, message) { super(message); }
    }, JobPaths: class {}, PackageIdentity: class {} }
  };
  const Runtime = loadRuntime(mocks);
  const runtime = new Runtime({}, { save: async () => {} }, { userId: '1' }, {
    connected: async () => true,
    udid: async () => 'a'.repeat(64),
    installedSigningIdentity: async () => installedIdentity,
    installedVersion: async () => deviceVersion,
    uninstall: async () => { calls.uninstalls++; deviceVersion = 0; },
    install: async file => { calls.installedPath = file; deviceVersion = job.versionCode; },
    installSelfAfterUninstall: async file => { calls.selfStaged = file; }
  });
  return { job, calls, Runtime, runtime };
}

test('installer self-update keeps the official signed HAP and lets the platform verify it', async () => {
  const { job, calls, runtime } = fixture(1, true);
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(evidence.validProfile, true);
  assert.equal(evidence.verifiedSignature, true);
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await runtime.verifySignature(job);
  await runtime.install(job);
  assert.equal(calls.nativeSigns, 0);
  assert.equal(calls.installedPath, job.cachePath);
  assert.equal(calls.nativeVerifies, 0, 'the custom verifier cannot parse official SDK signing blocks');
});
test('a stored matching certificate is selected before creating the update profile', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, false, true, false, installed, true);
  await runtime.ensureProfile(job);
  assert.equal(calls.selectedCertId, '2');
  assert.equal(job.signingCertId, '2');
});
test('unsigned installer update signs with the current installed certificate', async () => {
  const { job, calls, runtime } = fixture(1, true, true);
  job.assetName = 'installer-unsigned.hap';
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(evidence.verifiedSignature, false);
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await runtime.verifySignature(job);
  await runtime.install(job);
  assert.equal(calls.nativeSigns, 1);
  assert.equal(calls.installedPath, job.signedPath);
});
test('matching AGC app identifier also permits a certificate change', async () => {
  const { job, calls, runtime } = fixture(1, true, false, true);
  job.assetName = 'installer-unsigned.hap';
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await runtime.install(job);
  assert.equal(calls.nativeSigns, 1);
  assert.equal(calls.installedPath, job.signedPath);
});
test('unsigned self-update requires explicit data-loss confirmation when identity differs', async () => {
  const { job, calls, runtime } = fixture(1, true, false);
  job.assetName = 'installer-unsigned.hap';
  await assert.rejects(() => runtime.ensureProfile(job), /卸载旧版再安装/);
  assert.equal(calls.nativeSigns, 0);
  assert.equal(calls.installedPath, '');
});
test('self-update recovery rechecks a locally signed output', async () => {
  const { job, calls, runtime } = fixture(1, true, true);
  job.assetName = 'installer-unsigned.hap';
  job.profilePath = '/private/profile.p7b';
  job.profileSha256 = 'profile';
  job.signedProfileSha256 = 'profile';
  job.deviceUdid = 'a'.repeat(64);
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(evidence.validProfile, true);
  assert.equal(evidence.verifiedSignature, true);
  assert.equal(calls.nativeVerifies, 1);
});
test('runtime permits re-signing when the installed certificate or app identifier matches', async () => {
  for (const [sameCertificate, sameAppIdentifier] of [[true, false], [false, true]]) {
    const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
      appIdentifier: 'installed-app-id' };
    const { job, calls, runtime } = fixture(1, false, sameCertificate,
      sameAppIdentifier, installed);
    await runtime.ensureProfile(job);
    await runtime.sign(job);
    await runtime.install(job);
    assert.equal(calls.nativeSigns, 1);
    assert.equal(calls.installedPath, job.signedPath);
  }
});
test('runtime asks before a known identity conflict causes data loss', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, false, false, false, installed);
  await assert.rejects(() => runtime.ensureProfile(job), /卸载旧版再安装/);
  assert.equal(calls.nativeSigns, 0);
  assert.equal(calls.installedPath, '');
});
test('a resumed update rechecks signature compatibility before reusing its signed package', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, false, false, false, installed);
  job.deviceUdid = 'a'.repeat(64);
  job.signedProfileSha256 = job.profileSha256;
  await assert.rejects(() => runtime.inspectEvidence(job), /卸载旧版再安装/);
  assert.equal(calls.nativeVerifies, 0);
});
test('after approval a regular app uninstalls once and installs the verified signed HAP', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, false, false, false, installed);
  job.allowDataLoss = true;
  job.approvedInstalledVersion = installed.versionCode;
  job.approvedInstalledFingerprint = installed.fingerprint;
  job.approvedInstalledAppIdentifier = installed.appIdentifier;
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await runtime.verifySignature(job);
  await runtime.install(job);
  assert.equal(calls.uninstalls, 1);
  assert.equal(calls.installedPath, job.signedPath);
});
test('an approval cannot uninstall a different installed identity after the device changes', async () => {
  const installed = { versionCode: 3, fingerprint: 'C'.repeat(64),
    appIdentifier: 'other-installed-id' };
  const { job, calls, runtime } = fixture(3, false, false, false, installed);
  job.allowDataLoss = true;
  job.approvedInstalledVersion = 1;
  job.approvedInstalledFingerprint = 'A'.repeat(64);
  job.approvedInstalledAppIdentifier = 'installed-app-id';
  await assert.rejects(() => runtime.install(job), /发生变化/);
  assert.equal(calls.uninstalls, 0);
  assert.equal(calls.installedPath, '');
});
test('after approval a self-update stages a device-side replacement before old app exits', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, true, false, false, installed);
  job.allowDataLoss = true;
  job.approvedInstalledVersion = installed.versionCode;
  job.approvedInstalledFingerprint = installed.fingerprint;
  job.approvedInstalledAppIdentifier = installed.appIdentifier;
  job.assetName = 'installer-unsigned.hap';
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await runtime.verifySignature(job);
  await runtime.install(job);
  assert.equal(calls.selfStaged, job.signedPath);
  assert.equal(calls.identityBackups, 1);
  assert.equal(calls.uninstalls, 0);
});
test('a failed identity backup stops destructive self-update before staging', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, true, false, false, installed, false, true);
  job.allowDataLoss = true;
  job.approvedInstalledVersion = installed.versionCode;
  job.approvedInstalledFingerprint = installed.fingerprint;
  job.approvedInstalledAppIdentifier = installed.appIdentifier;
  job.assetName = 'installer-unsigned.hap';
  await runtime.ensureProfile(job);
  await runtime.sign(job);
  await assert.rejects(() => runtime.install(job), /backup offline/);
  assert.equal(calls.selfStaged, '');
  assert.equal(calls.uninstalls, 0);
});
test('installer self-update rejects a package whose identity differs from its catalog row', async () => {
  const { job, runtime } = fixture(1, true);
  job.versionCode = 8;
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(evidence.verifiedSignature, false);
  await assert.rejects(() => runtime.ensureProfile(job), /应用身份/);
});

test('one local install hashes the original HAP once and trusts native signer verification', async () => {
  const { job, calls, runtime } = fixture();
  assert.equal((await runtime.inspectEvidence(job)).verifiedCache, true);
  await runtime.sign(job);
  await runtime.verifySignature(job);
  assert.equal(calls.hapHashes, 1);
  assert.equal(calls.nativeSigns, 1);
  assert.equal(calls.nativeVerifies, 0);
});

test('an already installed local HAP completes without reading the cached packages', async () => {
  const { job, calls, runtime } = fixture(7);
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(evidence.installedVersionCode, 7);
  assert.equal(calls.hapHashes, 0);
  assert.equal(calls.nativeVerifies, 0);
});

test('a resumed runtime verifies the signed HAP again', async () => {
  const { job, calls, Runtime } = fixture();
  job.signedProfileSha256 = job.profileSha256;
  const resumed = new Runtime({}, {}, { userId: '1' }, {});
  await resumed.verifySignature(job);
  assert.equal(calls.nativeVerifies, 1);
});

test('changed expected digest cannot reuse an earlier source verification', async () => {
  const { job, calls, runtime } = fixture();
  await runtime.inspectEvidence(job);
  job.expectedSha256 = 'changed';
  await assert.rejects(() => runtime.sign(job), /SHA-256/);
  assert.equal(calls.hapHashes, 2);
  assert.equal(calls.nativeSigns, 0);
});

test('cancel during identity checks prevents uninstall and install from starting', async () => {
  const f = fixture(1, false, false, false,
    { versionCode: 1, fingerprint: 'A'.repeat(64), appIdentifier: 'installed-app-id' });
  Object.assign(f.job, { allowDataLoss: true, approvedInstalledVersion: 1,
    approvedInstalledFingerprint: 'A'.repeat(64), approvedInstalledAppIdentifier: 'installed-app-id' });
  f.runtime.device.installedSigningIdentity = async () => {
    f.calls.cancelled = true;
    return { versionCode: 1, fingerprint: 'A'.repeat(64), appIdentifier: 'installed-app-id' };
  };
  await assert.rejects(f.runtime.install(f.job), /已取消/);
  assert.equal(f.calls.uninstalls, 0); assert.equal(f.calls.installedPath, '');
});

test('once uninstall starts, cancellation still completes replacement to avoid leaving the app absent', async () => {
  const f = fixture(1, false, false, false,
    { versionCode: 1, fingerprint: 'A'.repeat(64), appIdentifier: 'installed-app-id' });
  Object.assign(f.job, { allowDataLoss: true, approvedInstalledVersion: 1,
    approvedInstalledFingerprint: 'A'.repeat(64), approvedInstalledAppIdentifier: 'installed-app-id' });
  f.runtime.device.uninstall = async () => {
    f.calls.uninstalls++;
    f.calls.cancelled = true;
    f.runtime.device.installedVersion = async () => 0;
  };
  await f.runtime.install(f.job);
  assert.equal(f.calls.uninstalls, 1); assert.equal(f.calls.installedPath, f.job.signedPath);
});

test('a same-version cached QuietStart with an unauthorized inner HAP is not treated as complete', async () => {
  const { job, calls, runtime } = fixture(7);
  job.bundleName = 'com.tonghongxiang.quietstart';
  calls.invalidWorker = true;
  const evidence = await runtime.inspectEvidence(job);
  assert.equal(job.reinstallRequired, true);
  assert.ok(calls.nativeVerifies > 0);
  assert.equal(evidence.verifiedSignature, false);
});
test('a failed same-version repair is not masked by the old installed version', async () => {
  const { job, runtime } = fixture(7);
  job.reinstallRequired = true;
  runtime.device.install = async () => { throw new Error('code:9568423 device is unauthorized'); };
  await assert.rejects(runtime.install(job), /9568423/);
});
