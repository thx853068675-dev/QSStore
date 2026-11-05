const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { loadEts } = require('./load_ets.cjs');
const { releaseUpdate } = require('./release_update_fixture.cjs');
const { InstallJob, InstallStage } = loadEts('jobs/InstallJob');
const { HapAsset } = loadEts('data/ReleaseInfo');
const bundle = 'com.example.samecode';

function fixture(disk = new Map(), clock = { now: 1700000000000 }) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/InstalledAppRegistry.ets'), 'utf8');
  const exports = {};
  const preferences = { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => { disk.set(key, value); }, flush: async () => {}
  }) };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { exports, require: name => name === '@kit.ArkData' ? { preferences } : {}, console,
    Date: class extends Date { static now() { return clock.now; } } });
  return { registry: exports.InstalledAppRegistry, disk, clock };
}
function dump(version = 7, updateTime = 1699999999000, versionName = '1.2.0', fingerprint = 'A'.repeat(64)) {
  return JSON.stringify({ name: bundle, versionCode: version, versionName, updateTime,
    applicationInfo: { fingerprint } });
}

test('ordinary same-build observations cannot renew a stale signing identity or revive it after restart', async () => {
  const f = fixture(), R = f.registry; await R.load({});
  R.observe(dump(), bundle);
  assert.equal(R.signingIdentity(bundle, 15000).updateTime, 1699999999000);
  f.clock.now += 16001;
  assert.equal(R.signingIdentity(bundle, 15000), undefined);
  R.remember(bundle, 7, '1.2.0');
  assert.equal(R.signingIdentity(bundle, 15000), undefined);
  assert.equal(R.version(bundle), 7, 'version evidence remains fresh independently');
  assert.equal(R.signingIdentity(bundle).fingerprint, 'A'.repeat(64), 'long-lived display evidence is preserved');
  await R.persist({});
  const saved = JSON.parse(f.disk.get('last-confirmed'))[0];
  assert.equal(saved.signingObservedAt, 1700000000000);
  assert.equal(saved.at, f.clock.now);
  const restarted = fixture(f.disk, f.clock).registry; await restarted.load({});
  assert.equal(restarted.signingIdentity(bundle, 15000), undefined);
  restarted.remember(bundle, 7); await restarted.persist({});
  assert.equal(JSON.parse(f.disk.get('last-confirmed'))[0].signingObservedAt, 1700000000000);
  restarted.observe(dump(7, f.clock.now - 1), bundle);
  assert.equal(restarted.signingIdentity(bundle, 15000).updateTime, f.clock.now - 1,
    'a fresh complete device dump really refreshes signing evidence');
});

test('legacy caches migrate their saved observation once, without discarding valid receipts or extending their age', async () => {
  const clock = { now: 1700000005000 }, at = clock.now - 5000;
  const disk = new Map([['last-confirmed', JSON.stringify([{ bundleName: bundle, version: 7,
    versionName: '1.2.0', at, signingUpdateTime: at - 1000, signingFingerprint: 'A'.repeat(64) }])]]);
  const R = fixture(disk, clock).registry; await R.load({});
  const job = Object.assign(new InstallJob(), { stage: InstallStage.INSTALLED, bundleName: bundle,
    versionCode: 7, versionName: '1.2.0', releaseTag: 'v1.2.0', installedUpdateTime: at - 1000,
    expectedSha256: 'a'.repeat(64), updatedAt: at });
  const asset = Object.assign(new HapAsset(), { bundleName: bundle, versionCode: 7,
    versionName: '1.2.0', releaseTag: 'v1.2.0', sha256: 'a'.repeat(64) });
  R.remember(bundle, 7, '1.2.0');
  const identity = R.signingIdentity(bundle, 15000);
  assert.equal(identity.updateTime, job.installedUpdateTime);
  assert.equal(releaseUpdate().available(asset, 7, '1.2.0', [job], identity.updateTime), false);
  clock.now += 11000; R.remember(bundle, 7); await R.persist({});
  assert.equal(R.signingIdentity(bundle, 15000), undefined);
  assert.equal(JSON.parse(disk.get('last-confirmed'))[0].signingObservedAt, at);
  const restored = fixture(disk, clock).registry; await restored.load({});
  assert.equal(restored.signingIdentity(bundle, 15000), undefined);
});

test('a verified external same-code replacement invalidates old release receipts; incomplete dumps and build changes clear identity', () => {
  const f = fixture(), R = f.registry, U = releaseUpdate(); R.observe(dump(), bundle);
  const job = Object.assign(new InstallJob(), { stage: InstallStage.INSTALLED, bundleName: bundle,
    versionCode: 7, versionName: '1.2.0', releaseTag: 'v1.2.0', installedUpdateTime: 1699999999000,
    expectedSha256: 'a'.repeat(64), updatedAt: f.clock.now });
  const asset = Object.assign(new HapAsset(), { bundleName: bundle, versionCode: 7,
    versionName: '1.2.0', releaseTag: 'v1.2.0', sha256: 'a'.repeat(64) });
  f.clock.now += 20000;
  R.observe(dump(7, f.clock.now - 1, '1.1.9', 'B'.repeat(64)), bundle);
  const identity = R.signingIdentity(bundle, 15000);
  assert.equal(U.record([job], bundle, 7, identity.updateTime), undefined);
  assert.equal(U.available(asset, 7, R.versionName(bundle, 7), [job], identity.updateTime), true);
  R.observe(JSON.stringify({ name: bundle, versionCode: 7, versionName: '1.1.9' }), bundle);
  assert.equal(R.signingIdentity(bundle), undefined);
  R.observe(dump(7, f.clock.now - 1), bundle); R.remember(bundle, 8, '2.0.0');
  assert.equal(R.signingIdentity(bundle), undefined);
});
