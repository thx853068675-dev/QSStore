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
    selectedCertId: '', identityBackups: 0, identityPrepares: 0, order: [], stagedCleanup: 0,
    profiles: [], renewals: [], previousJobs: [], saved: [] };
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
    './InstalledSigningExpiry': { InstalledSigningExpiry: {
      capture: async (value, installed) => {
        calls.capturedIdentity={...installed};value.authorizationExpiresAt=1900000000;
        value.installedUpdateTime=installed.updateTime;value.installedFingerprint=installed.fingerprint;
      },current:()=>undefined
    } },
    './StorageBudget': { StorageBudget: { require: async () => {} } },
    './PackageArchive': { PackageArchive: { permissions: async () => [], workingBytes: () => 123, release: () => {} } },
    './JobCancellation': { JobCancellation: { assertActive: () => {
      if (calls.cancelled) throw new Error('安装任务已取消');
    } } },
    './InstallJob': { InstallStage: { INSTALLING: 'installing', INSTALLED: 'installed' },
      FailureKind: { INVALID_PACKAGE: 'invalid_package', DEVICE: 'device', CONFIRMATION: 'confirmation' },
      RecoveryEvidence: class {
      verifiedCache = false; validProfile = false; verifiedSignature = false;
      installedVersionCode = 0;
    } },
    './LocalBundles': { LocalBundles: { liveInstalledVersion: () => installedVersion, installedVersionName: () => '',
      isKnown: version => version >= 0, isSelfBundle: () => selfUpdate, selfSigningFingerprint: () => 'A'.repeat(64),
      selfAppIdentifier: () => 'installed-app-id' } },
    './InstalledAppRegistry': { InstalledAppRegistry: { load: async () => {}, version: () => installedVersion,
      versionName: () => '', remember: () => {}, persist: async () => {} }, InstalledSigningIdentity: class {
      fingerprint = ''; appIdentifier = ''; versionCode = 0;
    } },
    '../data/AgcProfile': { ProfileRefreshOptions: class {}, AgcProfile: {
      signingFingerprint: async () => matchingIdentity ? 'A'.repeat(64) : 'B'.repeat(64),
      appIdentifier: () => matchingIdentity || matchingAppIdentifier ?
        'installed-app-id' : 'other-app-id',
      valid: () => true, effectiveAcls: () => [],
      profileExpiry: () => calls.previousExpiry || 0,
      effectiveExpiry: (_path, expiry) => Math.min(calls.profileExpiry || Date.now() / 1000 + 86400, expiry),
      ensure: async (_context, _account, identity, _bundle, _udid, _permissions, refresh) => {
        calls.selectedCertId = identity.certId;
        calls.profiles.push(refresh && { ...refresh });
        return '/private/profile.p7b';
      }
    } },
    '@kit.CoreFileKit': {
      fileIo: { statSync: () => ({ size: 123 }), accessSync: () => true, readTextSync: () => 'private key' },
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
      ensureForInstall: async () => {
        calls.identityPrepares++;
        if (calls.enrollmentError) throw new Error(calls.enrollmentError);
        if (calls.cancelAfterPrepare) calls.cancelled = true;
        return { certId: calls.missingIdentity ? '3' : '1', certExpiry: calls.certExpiry ?? Date.now() / 1000 + 365 * 86400,
          privateKeyPath: '/private/key', certificatePath: '/private/cert' };
      },
      ensureForRenewal: async (_context, _account, minimum) => {
        calls.renewals.push(minimum);
        return { certId: '4', certExpiry: minimum + 365 * 86400,
          privateKeyPath: '/private/key', certificatePath: '/private/cert-4' };
      },
      load: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      restore: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      forJob: async () => ({ certId: '1', privateKeyPath: '/private/key', certificatePath: '/private/cert' }),
      matchingInstalledCertificate: async () => alternateCertificate ?
        { certId: '2', certExpiry: calls.certExpiry ?? Date.now() / 1000 + 365 * 86400,
          privateKeyPath: '/private/key', certificatePath: '/private/cert-2' } : undefined,
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
    './PackageInspector': { inspectPackage: () => calls.inspectedIdentity ?? originalIdentity,
      checkCatalogIdentity: () => {}, PackageInspectError: class extends Error {},
      requestedPermissions: () => [] },
    './JobRunner': { JobFailure: class extends Error {
      constructor(kind, message) { super(message); this.kind=kind; }
    }, JobPaths: class {}, PackageIdentity: class {} }
  };
  const Runtime = loadRuntime(mocks);
  const runtime = new Runtime({}, { save: async value => calls.saved.push({ ...value }),
    listAll: async () => calls.previousJobs }, { userId: '1' }, {
    connected: async () => true,
    udid: async () => 'a'.repeat(64),
    installedSigningIdentity: async () => {
      calls.signingQueries=(calls.signingQueries||0)+1;
      if (calls.queryError) throw Error('device offline');
      return installedIdentity;
    },
    installedVersion: async () => deviceVersion,
    uninstall: async () => { calls.uninstalls++; deviceVersion = 0; },
    install: async file => {
      if (calls.installError) throw Error(calls.installError);
      calls.installedPath = file; deviceVersion = job.versionCode;
    },
    stageInstall: async file => {
      calls.order.push('stage');
      if (calls.stageFails) throw Error('transfer failed before uninstall');
      calls.stagedPath = file;
      if (calls.identityChangesDuringTransfer) installedIdentity.versionCode++;
      return 'staging-ticket';
    },
    installStaged: async () => {
      calls.order.push('uninstall-and-install'); calls.uninstalls++;
      calls.installedPath = calls.stagedPath; deviceVersion = job.versionCode;
    },
    discardStaged: async () => { calls.stagedCleanup++; return true; },
    installSelfAfterUninstall: async file => { calls.selfStaged = file; }
  });
  return { job, calls, Runtime, runtime };
}

function renewalFixture({ sameCertificate = true, sameApp = false, alternateCertificate = false } = {}) {
  const installed = { versionCode: 7, fingerprint: 'A'.repeat(64),
    appIdentifier: 'installed-app-id', updateTime: 1700000000000 };
  const f = fixture(7, false, sameCertificate, sameApp, installed, alternateCertificate);
  Object.assign(f.job, { renewalRequestedAt: Date.now(), renewalPreparedAt: 0,
    renewalPreviousExpiry: 0, renewalExpiresAt: 0, renewalInstallBaseline: 0, reinstallRequired: true });
  return { ...f, installed };
}
test('an old valid Profile is never accepted as evidence of a new renewal', async () => {
  const f = renewalFixture();
  f.job.deviceUdid = 'a'.repeat(64); f.job.signedProfileSha256 = 'profile';
  const evidence = await f.runtime.inspectEvidence(f.job);
  assert.equal(evidence.validProfile, false);
  assert.equal(evidence.verifiedSignature, false);
});
test('retained renewal bytes are inspected before certificate work, even when the journal claims the right version', async () => {
  for (const actual of [{ bundleName: 'com.example.other', versionCode: 7 },
    { bundleName: 'com.example.app', versionCode: 8 }]) {
    const f = renewalFixture(); f.calls.inspectedIdentity = actual;
    await assert.rejects(f.runtime.ensureProfile(f.job), /续签原包.*不一致/);
    assert.equal(f.calls.identityPrepares, 0); assert.equal(f.calls.profiles.length, 0);
    assert.equal(f.calls.uninstalls, 0);
  }
});
test('same-version renewal prepares a fresh authorization and submits without uninstalling', async () => {
  const f = renewalFixture({ alternateCertificate: true });
  f.calls.previousExpiry = Date.now() / 1000 + 7200;
  await f.runtime.ensureProfile(f.job);
  assert.equal(f.job.signingCertId, '2');
  assert.equal(f.job.renewalPreparedAt, f.job.renewalRequestedAt);
  assert.ok(f.job.renewalExpiresAt > f.job.renewalPreviousExpiry);
  assert.deepEqual(f.calls.profiles[0], {
    requestId: f.job.renewalRequestedAt.toString(36), minimumExpiry: f.job.renewalPreviousExpiry });
  await f.runtime.sign(f.job); await f.runtime.install(f.job);
  assert.equal(f.calls.installedPath, f.job.signedPath);
  assert.equal(f.job.renewalInstallBaseline, f.installed.updateTime);
  assert.equal(f.calls.uninstalls, 0); assert.equal(f.calls.renewals.length, 0);
  assert.equal(await f.runtime.confirmRenewal(f.job), false, 'same version alone is not a completion proof');
  f.installed.updateTime++;
  assert.equal(await f.runtime.confirmRenewal(f.job), true);
});
test('renewal rejects missing, mismatched or unidentifiable targets before certificate preparation', async () => {
  for (const change of [i => { i.versionCode = 0; }, i => { i.versionCode++; },
    i => { i.fingerprint = ''; i.appIdentifier = ''; }, i => { i.updateTime = 0; }]) {
    const f = renewalFixture(); change(f.installed);
    await assert.rejects(() => f.runtime.ensureProfile(f.job));
    assert.equal(f.calls.identityPrepares, 0);
    assert.equal(f.calls.profiles.length, 0); assert.equal(f.calls.uninstalls, 0);
  }
});
test('renewal rotates only an insufficient certificate and keeps the existing private key', async () => {
  const f = renewalFixture({ sameCertificate: false, sameApp: true });
  f.calls.certExpiry = Date.now() / 1000 + 7200;
  f.calls.previousExpiry = f.calls.certExpiry + 3600;
  // The previous Profile belongs to the installed certificate, while the new certificate is different.
  f.calls.previousJobs = [];
  f.job.renewalPreviousExpiry = f.calls.previousExpiry;
  await f.runtime.ensureProfile(f.job);
  assert.deepEqual(f.calls.renewals, [f.job.renewalPreviousExpiry]);
  assert.equal(f.calls.selectedCertId, '4');
  await f.runtime.install(f.job);
  assert.equal(f.calls.uninstalls, 0);
});
test('incompatible renewal asks for consent and never uninstalls with missing or stale approval', async () => {
  for (const approval of [false, true]) {
    const f = renewalFixture({ sameCertificate: false, sameApp: false });
    f.job.allowDataLoss = approval;
    await assert.rejects(() => f.runtime.ensureProfile(f.job), e => e.kind==='confirmation'&&/无法保留数据续签/.test(e.message));
    await assert.rejects(() => f.runtime.install(f.job), /无法保留数据续签/);
    assert.equal(f.calls.uninstalls, 0); assert.equal(f.calls.installedPath, '');
  }
});
test('renewal cannot submit a package before fresh authorization is prepared', async () => {
  const f = renewalFixture();
  await assert.rejects(() => f.runtime.install(f.job), /尚未核对/);
  assert.equal(f.calls.installedPath, ''); assert.equal(f.calls.uninstalls, 0);
});
test('platform identity conflicts during renewal pause for explicit data-loss consent', async () => {
  const f = renewalFixture(); await f.runtime.ensureProfile(f.job);
  f.calls.installError = '9568264 incompatible signature';
  await assert.rejects(() => f.runtime.install(f.job), e=>e.kind==='confirmation'&&/系统拒绝保留数据续签/.test(e.message));
  assert.equal(f.calls.uninstalls, 0);
});
test('approved incompatible renewal transfers a verified package before replacing the exact approved application', async () => {
  const f=renewalFixture({sameCertificate:false,sameApp:false});
  await assert.rejects(()=>f.runtime.ensureProfile(f.job),/无法保留数据续签/);
  Object.assign(f.job,{allowDataLoss:true,approvedInstalledVersion:f.installed.versionCode,
    approvedInstalledFingerprint:f.installed.fingerprint,approvedInstalledAppIdentifier:f.installed.appIdentifier});
  await f.runtime.ensureProfile(f.job);await f.runtime.sign(f.job);await f.runtime.verifySignature(f.job);
  await f.runtime.install(f.job);
  assert.equal(f.calls.uninstalls,1);assert.deepEqual(f.calls.order,['stage','uninstall-and-install']);
  assert.equal(f.calls.installedPath,f.job.signedPath);assert.equal(f.calls.nativeSigns,1);
  assert.equal(f.job.renewalInstallBaseline,f.installed.updateTime);
});
test('renewal replacement rechecks consent after transmission and can recover an interrupted reinstall', async () => {
  const f=renewalFixture({sameCertificate:false,sameApp:false});
  await assert.rejects(()=>f.runtime.ensureProfile(f.job),/无法保留数据续签/);
  Object.assign(f.job,{allowDataLoss:true,approvedInstalledVersion:f.installed.versionCode,
    approvedInstalledFingerprint:f.installed.fingerprint,approvedInstalledAppIdentifier:f.installed.appIdentifier});
  f.calls.identityChangesDuringTransfer=true;
  await assert.rejects(()=>f.runtime.install(f.job),/传输期间已安装应用发生变化/);
  assert.equal(f.calls.uninstalls,0);assert.equal(f.job.allowDataLoss,false);
  f.installed.versionCode--;f.calls.identityChangesDuringTransfer=false;f.job.allowDataLoss=true;
  f.runtime.device.installedSigningIdentity=async()=>undefined;
  f.runtime.device.installedVersion=async()=>0;
  await f.runtime.install(f.job);
  assert.equal(f.calls.uninstalls,0);assert.equal(f.calls.installedPath,f.job.signedPath);
});
test('renewal rechecks the target at submission and rejects a queued version change', async () => {
  const f = renewalFixture(); await f.runtime.ensureProfile(f.job);
  f.installed.versionCode++;
  await assert.rejects(() => f.runtime.install(f.job), /相同版本/);
  assert.equal(f.calls.uninstalls, 0); assert.equal(f.calls.installedPath, '');
});
test('resuming a prepared renewal uses verified files without new AGC enrollment', async () => {
  const f = renewalFixture(); await f.runtime.ensureProfile(f.job);
  f.job.signedProfileSha256 = f.job.profileSha256;
  const evidence = await f.runtime.inspectEvidence(f.job);
  assert.equal(evidence.validProfile, true); assert.equal(evidence.verifiedSignature, true);
  assert.equal(f.calls.identityPrepares, 1); assert.equal(f.calls.profiles.length, 1);
});
test('renewal confirmation requires both a newer installation time and the expected signing certificate', async () => {
  const f = renewalFixture(); await f.runtime.ensureProfile(f.job); await f.runtime.install(f.job);
  f.installed.updateTime++; f.installed.fingerprint = 'C'.repeat(64);
  assert.equal(await f.runtime.confirmRenewal(f.job), false);
  f.installed.fingerprint = 'A'.repeat(64); f.installed.versionCode++;
  assert.equal(await f.runtime.confirmRenewal(f.job), false);
  f.installed.versionCode = f.job.versionCode;
  assert.equal(await f.runtime.confirmRenewal(f.job), true);
  f.calls.queryError = true;
  await assert.rejects(() => f.runtime.confirmRenewal(f.job), /核实/);
});
test('a renewal completed before a timeout is reconciled without resubmission and seals expiry after leaving the page', async () => {
  const f=renewalFixture();await f.runtime.ensureProfile(f.job);await f.runtime.install(f.job);
  const baseline=f.job.renewalInstallBaseline;
  f.installed.updateTime+=1000;
  f.calls.installedPath='';f.runtime.confirmedSubmission=''; // new runtime cannot depend on an old in-memory receipt
  f.job.stageHistory=[{stage:'installing',at:f.installed.updateTime+5000}];
  await f.runtime.install(f.job);
  assert.equal(f.calls.installedPath,'','the already applied renewal is not submitted again');
  assert.equal(f.job.renewalInstallBaseline,baseline,'retry retains the first submission baseline');
  const queries=f.calls.signingQueries;
  await f.runtime.rememberInstalledAuthorization(f.job);
  assert.equal(f.calls.signingQueries,queries,'reuse confirmed system identity without another HDC query');
  assert.equal(f.job.installedUpdateTime,f.installed.updateTime);
  assert.equal(f.job.authorizationExpiresAt,1900000000);
});
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

test('local and online installation automatically prepare a missing signing identity before the Profile', async () => {
  for (const source of ['local', 'https://github.com/example/app/releases/download/v1/app.hap']) {
    const { job, calls, runtime } = fixture();
    job.sourceUrl = source; calls.missingIdentity = true;
    await runtime.ensureProfile(job);
    assert.equal(calls.identityPrepares, 1);
    assert.equal(calls.selectedCertId, '3');
    assert.equal(job.signingCertId, '3');
    assert.equal(job.profilePath, '/private/profile.p7b');
    await runtime.sign(job);
    assert.equal(calls.nativeSigns, 1);
  }
});

test('unsigned installer update automatically prepares an identity and retains data-loss confirmation', async () => {
  const { job, calls, runtime } = fixture(1, true, false);
  job.assetName = 'installer-unsigned.hap'; calls.missingIdentity = true;
  await assert.rejects(() => runtime.ensureProfile(job), /卸载旧版再安装/);
  assert.equal(calls.identityPrepares, 1);
  assert.equal(calls.selectedCertId, '3');
  assert.equal(calls.uninstalls, 0);
});

test('failed automatic enrollment never advances to Profile creation or signing', async () => {
  const { job, calls, runtime } = fixture(); calls.enrollmentError = 'AGC offline';
  await assert.rejects(() => runtime.ensureProfile(job), /AGC offline/);
  assert.equal(calls.selectedCertId, ''); assert.equal(calls.nativeSigns, 0);
});

test('cancellation after automatic enrollment prevents further device authorization', async () => {
  const { job, calls, runtime } = fixture(); calls.cancelAfterPrepare = true;
  await assert.rejects(() => runtime.ensureProfile(job), /已取消/);
  assert.equal(calls.selectedCertId, '');
});

test('an already cancelled task does not start automatic certificate preparation', async () => {
  const { job, calls, runtime } = fixture(); calls.cancelled = true;
  await assert.rejects(() => runtime.ensureProfile(job), /已取消/);
  assert.equal(calls.identityPrepares, 0); assert.equal(calls.selectedCertId, '');
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
  assert.deepEqual(calls.order, ['stage', 'uninstall-and-install']);
  assert.equal(calls.stagedCleanup, 1);
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

for (const changeIdentity of [false, true]) test('replacement protects the old app when ' +
  (changeIdentity ? 'identity changes during staging' : 'staging transfer fails'), async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64), appIdentifier: 'installed-app-id' };
  const { job, calls, runtime } = fixture(1, false, false, false, installed);
  Object.assign(job, { allowDataLoss: true, approvedInstalledVersion: 1,
    approvedInstalledFingerprint: installed.fingerprint, approvedInstalledAppIdentifier: installed.appIdentifier });
  calls.stageFails = !changeIdentity; calls.identityChangesDuringTransfer = changeIdentity;
  await assert.rejects(runtime.install(job), changeIdentity ? /发生变化/ : /before uninstall/);
  assert.equal(calls.uninstalls, 0); assert.equal(calls.installedPath, '');
  if (changeIdentity) assert.equal(calls.stagedCleanup, 1);
});

test('staged replacement keeps a cleanup ticket when the link drops during cleanup', async () => {
  const installed = { versionCode: 1, fingerprint: 'A'.repeat(64), appIdentifier: 'installed-app-id' };
  const { runtime, job, calls } = fixture(1, false, false, false, installed);
  Object.assign(job, { allowDataLoss: true, approvedInstalledVersion: installed.versionCode,
    approvedInstalledFingerprint: installed.fingerprint,
    approvedInstalledAppIdentifier: installed.appIdentifier });
  runtime.device.discardStaged = async () => false;
  await runtime.install(job);
  assert.equal(calls.uninstalls, 1); assert.ok(job.stagedTicket.length > 0);
});

test('an online queued package cannot downgrade after another source upgrades the app', async () => {
  const { job, calls, runtime } = fixture(9);
  job.appId = 12; job.versionCode = 7; job.allowDataLoss = true;
  await assert.rejects(() => runtime.install(job), /无法降级/);
  assert.equal(calls.uninstalls, 0); assert.equal(calls.installedPath, '');
  assert.equal(calls.selfStaged, '');
});
