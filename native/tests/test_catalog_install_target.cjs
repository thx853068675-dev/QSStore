const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { InstallJob, InstallStage } = loadEts('jobs/InstallJob');
const { HapAsset } = loadEts('data/ReleaseInfo');
const { CatalogApp } = loadEts('data/CatalogApp');
const { CatalogPackageVariant } = loadEts('data/CatalogPackageVariant');
const ReleaseUpdate = require('./release_update_fixture.cjs').releaseUpdate();
const { CatalogInstallTarget: target } = loadEts('jobs/CatalogInstallTarget', {
  '../data/CatalogPackageVariant': { CatalogPackageVariant }, './ReleaseUpdate': { ReleaseUpdate },
  './InstallJob': { InstallJob, InstallStage }
});

function packageAsset(name, digest = 'a', code = 152, bundleName = 'com.example.petrelgram') {
  const asset = new HapAsset();
  Object.assign(asset, { name, sha256: digest.repeat(64), versionCode: code, bundleName,
    versionName: '1.5.2', releaseName: 'Petrelgram 1.5.2', releaseTag: 'v1.5.2',
    url: 'https://github.com/author/Petrelgram/releases/download/v1.5.2/' + encodeURIComponent(name) });
  return asset;
}
function catalog(primary, choices = [primary]) {
  const app = new CatalogApp(); app.latestAsset = primary; app.latestAssets = choices; return app;
}
function completed(asset) {
  const job = InstallJob.create('receipt-' + asset.name, 1, asset.name, asset.url, asset.sha256);
  Object.assign(job, { stage: InstallStage.INSTALLED, bundleName: asset.bundleName,
    versionCode: asset.versionCode, versionName: asset.versionName, releaseTag: asset.releaseTag,
    releaseName: asset.releaseName, catalogSha256: asset.sha256, installedUpdateTime: 60000,
    stageHistory: [{ stage: InstallStage.INSTALLED, at: 60000 }], updatedAt: 60000 });
  return job;
}

test('APP ZIP receipt gives Discover, Detail and Management the same package and eliminates cross-package digest updates', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b');
  const app = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(app), store = catalog(hap, [hap, app]);
  assert.equal(ReleaseUpdate.available(hap, 152, '1.5.2', [receipt], 60000), true,
    'old primary-HAP path incorrectly treated the installed APP digest as an update');
  const discover = target.choose(store, [receipt], 152, 60000);
  const management = target.choose(store, [receipt], 152, 60000, app.bundleName, receipt.assetName);
  const detail = target.asset([hap, app], hap, ReleaseUpdate.record([receipt], app.bundleName, 152, 60000));
  assert.equal(discover, app); assert.equal(management, app); assert.equal(detail, app);
  assert.equal(ReleaseUpdate.available(discover, 152, '1.5.2', [receipt], 60000), false);
});

test('same installed package variant with replaced content remains a genuine update', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b'), old = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(old), newer = packageAsset(old.name, 'c');
  const selected = target.choose(catalog(hap, [hap, newer]), [receipt], 152, 60000);
  assert.equal(selected, newer);
  assert.equal(ReleaseUpdate.available(selected, 152, '1.5.2', [receipt], 60000), true);
  assert.equal(receipt.expectedSha256, 'a'.repeat(64));
});

test('versioned filenames follow the installed variant to a later release, never to a different container', () => {
  const previous = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap'), receipt = completed(previous);
  const hap = packageAsset('Petrelgram-1.5.3.hap', 'b', 153);
  const app = packageAsset('Petrelgram-1.5.3.app.zip / entry.hap', 'c', 153);
  Object.assign(hap, { versionName: '1.5.3', releaseTag: 'v1.5.3' });
  Object.assign(app, { versionName: '1.5.3', releaseTag: 'v1.5.3' });
  const selected = target.choose(catalog(hap, [hap, app]), [receipt], 152, 60000);
  assert.equal(selected, app);
  assert.equal(ReleaseUpdate.available(selected, 152, '1.5.2', [receipt], 60000), true);
});

test('an external reinstall invalidates the old variant receipt and uses the catalog default', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b'), app = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(app), store = catalog(hap, [hap, app]);
  assert.equal(target.choose(store, [receipt], 152, 70000, app.bundleName, receipt.assetName), hap);
  assert.equal(target.choose(store, [receipt], 153, 60000, app.bundleName, receipt.assetName), hap);
  assert.equal(target.choose(store, [], 152, 60000, app.bundleName, receipt.assetName), hap);
  assert.equal(target.choose(store, [receipt], 0, 60000, app.bundleName, receipt.assetName), hap);
  assert.equal(target.choose(store, [receipt], 152), app,
    'a matching completed current-code receipt remains useful when the device exposes no updateTime');
});

test('legacy estimated receipts are ignored when device updateTime proves a later installation', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b'), app = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(app); receipt.installedUpdateTime = 0;
  assert.equal(target.choose(catalog(hap, [hap, app]), [receipt], 152, 90000), hap);
});

test('unknown device observations use the last confirmed APP receipt, while confirmed absence never does', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b'), app = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(app), store = catalog(hap, [hap, app]);
  assert.equal(target.receipt([receipt], app.bundleName, -1, 60000), receipt);
  assert.equal(target.choose(store, [receipt], -1, 60000), app);
  assert.equal(ReleaseUpdate.available(target.choose(store, [receipt], -1, 60000),
    receipt.versionCode, receipt.versionName, [receipt], 60000), false);
  assert.equal(target.receipt([receipt], app.bundleName, 0, 60000), undefined);
  assert.equal(target.choose(store, [receipt], 0, 60000), hap);
  assert.equal(target.choose(store, [receipt], -1, 90000), hap,
    'unknown system code still cannot resurrect a receipt invalidated by device installation time');
});

test('unknown observations choose the newest completed receipt and ignore pending work or another bundle', () => {
  const hap = packageAsset('Petrelgram-1.5.2.hap', 'b'), app = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const older = completed(hap), newer = completed(app), pending = completed(hap), other = completed(hap);
  older.updatedAt = 100; older.stageHistory[0].at = 100;
  newer.updatedAt = 200; newer.stageHistory[0].at = 200;
  pending.updatedAt = 300; pending.stageHistory[0].at = 300; pending.stage = InstallStage.DOWNLOADING;
  other.updatedAt = 400; other.stageHistory[0].at = 400; other.bundleName = 'com.another.app';
  assert.equal(target.receipt([older, newer, pending, other], app.bundleName, -1), newer);
  assert.equal(target.receipt([], app.bundleName, -1), undefined);
});

test('explicit bundle matching keeps phone packages separate from another module or HiCar bundle', () => {
  const wear = packageAsset('watch-1.5.2.hap', 'b', 152, 'com.example.watch');
  const phoneHap = packageAsset('Petrelgram-1.5.2.hap', 'c'), phoneApp = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap');
  const receipt = completed(phoneApp), store = catalog(wear, [wear, phoneHap, phoneApp]);
  assert.equal(target.choose(store, [receipt], 152, 60000, phoneApp.bundleName), phoneApp);
  assert.equal(target.choose(store, [receipt], 152, 60000), wear);
  assert.equal(target.choose(store, [receipt], 152, 60000, 'com.missing.app'), undefined);
});

test('missing latestAssets and empty bundle metadata remain safe for old catalog rows', () => {
  const primary = packageAsset('local.hap');
  assert.equal(target.choose({ latestAsset: primary }, [], 0), primary);
  assert.equal(target.choose({ latestAssets: [] }, [], 0), undefined);
  primary.bundleName = '';
  const second = packageAsset('local.app.zip / entry.hap', 'b'); second.bundleName = '';
  assert.equal(target.choose(catalog(primary, [primary, second]), [], 0), primary);
});

test('default selection never revives an obsolete primary outside the current release assets', () => {
  const old = packageAsset('Petrelgram-1.5.1.app.zip / entry.hap', 'a', 151);
  const currentHap = packageAsset('Petrelgram-1.5.2.hap', 'b'), currentApp = packageAsset('Petrelgram-1.5.2.app.zip / entry.hap', 'c');
  assert.equal(target.asset([currentHap, currentApp], old, undefined), currentApp);
  assert.equal(target.asset([], old, completed(old)), undefined);
  const unavailable = packageAsset('custom-1.5.2.hap');
  assert.equal(target.asset([currentHap, currentApp], currentHap, completed(unavailable)), undefined,
    'a known installed format cannot silently switch to another ambiguous package');
  assert.equal(target.asset([currentHap, currentApp], undefined, undefined, 'missing-variant.hap'), undefined);
  assert.equal(target.asset([currentHap], currentHap, completed(unavailable)), currentHap,
    'one candidate remains unambiguous');
});
