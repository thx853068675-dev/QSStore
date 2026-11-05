const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const release = loadEts('data/ReleaseInfo');
const { DeviceSupportDisplay } = loadEts('data/DeviceSupportDisplay', { './ReleaseInfo': release });
const { CatalogApp } = loadEts('data/CatalogApp', { './ReleaseInfo': release });
const { CatalogLookup } = loadEts('data/CatalogLookup', { './ReleaseInfo': release, './CatalogApp': { CatalogApp } });
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

test('API device declarations filter malformed values, deduplicate and preserve unknown valid tokens without defaulting to phone', () => {
  const asset = release.HapAsset.fromJson({ device_types: [' PHONE ', 'phone', 'tablet', 7, null,
    '2in1', 'FutureDevice', 'futuredevice', '', 'phone,tablet', 'x<script>', 'a'.repeat(65)] });
  assert.deepEqual(Array.from(asset.deviceTypes), ['phone', 'tablet', '2in1', 'FutureDevice']);
  for (const value of [undefined, null, 'phone', {}, [], [null, '', 'bad value']]) {
    assert.deepEqual(Array.from(DeviceSupportDisplay.normalize(value)), []);
  }
  assert.deepEqual(Array.from(release.HapAsset.fromJson({}).deviceTypes), []);
  const catalog = CatalogApp.fromJson({ latest_asset: { name: 'a.hap', device_types: ['phone'] },
    latest_assets: [{ name: 'a.hap', device_types: ['phone'] }, { name: 'b.app', device_types: ['tablet', '2in1'] }] });
  assert.deepEqual(Array.from(CatalogApp.copy(catalog).latestAsset.deviceTypes), ['phone']);
  assert.deepEqual(Array.from(catalog.latestAssets[1].deviceTypes), ['tablet', '2in1']);
});
test('official SDK device labels include PC while default and valid future declarations are never inferred as a phone', () => {
  assert.deepEqual(Array.from(DeviceSupportDisplay.labels(['phone', 'tablet', '2in1', 'wearable', 'tv', 'car', 'default', 'FutureDevice'])),
    ['手机', '平板', '电脑', '穿戴', '电视', '车机', '默认', 'FutureDevice']);
  assert.deepEqual(Array.from(DeviceSupportDisplay.labels(['pc'])), ['pc'], 'SDK does not define pc as an alias of 2in1');
});
test('device matching is conservative for missing declarations or an unspecified system type and preserves exact future matches', () => {
  assert.equal(DeviceSupportDisplay.matches(['phone', 'tablet'], 'tablet'), true);
  assert.equal(DeviceSupportDisplay.matches(['PHONE'], 'phone'), true);
  assert.equal(DeviceSupportDisplay.matches(['2in1'], 'phone'), false);
  assert.equal(DeviceSupportDisplay.matches(['pc'], '2in1'), false);
  assert.equal(DeviceSupportDisplay.matches(['default'], 'phone'), false);
  assert.equal(DeviceSupportDisplay.matches([], 'phone'), undefined);
  assert.equal(DeviceSupportDisplay.matches(['phone'], ''), undefined);
  assert.equal(DeviceSupportDisplay.matches(['phone'], 'default'), undefined);
  assert.equal(DeviceSupportDisplay.matches(['phone'], 'futureDevice'), undefined);
  assert.equal(DeviceSupportDisplay.matches(['FutureDevice'], 'futureDevice'), true);
});
test('Detail labels use only the selected history, channel or package and never borrow the latest stable declaration', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
  const at = source.indexOf('  private selectedDeviceLabels(');
  assert.ok(at >= 0);
  const method = source.slice(at, source.indexOf('\n  }', at) + 4);
  const box = { DeviceSupportDisplay };
  vm.runInNewContext(ts.transpileModule('class Page {' + method + '}; globalThis.Page = Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page(); ui.app = { latestAsset: { name: 'stable.hap', deviceTypes: ['phone'] } };
  for (const [asset, expected] of [
    [{ name: 'history.hap', deviceTypes: ['tablet'] }, ['平板']],
    [{ name: 'preview.app', deviceTypes: ['2in1'] }, ['电脑']],
    [{ name: 'secondary.hap', deviceTypes: ['tv', 'car'] }, ['电视', '车机']],
    [{ name: 'unknown.hap' }, ['设备未标注']],
    [new release.HapAsset(), []]
  ]) { ui.selectedAsset = asset; assert.deepEqual(Array.from(ui.selectedDeviceLabels()), expected); }
});

function deviceCatalog(options = {}) {
  const a = { name: 'a.hap', url: 'https://example.com/releases/download/v2/a.hap',
    sha256: 'a'.repeat(64), bundle_name: 'com.example.a', version_code: 2, version_name: '2' };
  const b = { ...a, name: 'b.app', url: 'https://example.com/releases/download/v2/b.app',
    sha256: 'b'.repeat(64), bundle_name: 'com.example.b' };
  return CatalogApp.fromJson({ id: 7, updated_at: '100', latest: { tag: 'v2', name: 'v2' },
    latest_asset: a, latest_assets: [a, b], ...options });
}
const deviceLookup = (old, fresh) => new CatalogLookup([old], [fresh], true, 0, app => app);

test('same-revision catalog lookup preserves device backfill in both separately parsed primary and attachment objects', () => {
  const old = deviceCatalog(), fresh = deviceCatalog();
  assert.notEqual(fresh.latestAsset, fresh.latestAssets[0], 'API parsing creates independent objects');
  fresh.latestAsset.deviceTypes = ['tablet']; fresh.latestAssets[0].deviceTypes = ['tablet'];
  fresh.latestAssets[1].deviceTypes = ['2in1'];
  old.displayName = 'Authoritative'; fresh.displayName = 'Stale visible title';
  const lookup = deviceLookup(old, fresh);
  assert.equal(lookup.app(7).displayName, 'Authoritative', 'the primary still owns the row');
  assert.deepEqual(Array.from(lookup.app(7).latestAsset.deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(lookup.app(7).latestAssets[0].deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(lookup.source(7, 'com.example.b').latestAssets[1].deviceTypes), ['2in1']);
  assert.deepEqual(Array.from(old.latestAsset.deviceTypes), [], 'the old snapshot remains untouched');
});
test('same-revision device backfill recognizes independent latestAsset when the attachment array has no new declaration', () => {
  const old = deviceCatalog(), fresh = deviceCatalog(); fresh.latestAsset.deviceTypes = ['tablet'];
  assert.deepEqual(Array.from(deviceLookup(old, fresh).app(7).latestAsset.deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(deviceLookup(old, fresh).app(7).latestAssets[0].deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(old.latestAssets[0].deviceTypes), []);
});
test('attachment metadata backfill cannot replace an independent primary with a different package', () => {
  for (const change of [{ sha256: 'c'.repeat(64) }, { sha256: '' }, { name: 'other.hap' },
    { url: 'https://example.com/other.hap' }, { bundleName: 'com.example.other' }, { versionCode: 1 }]) {
    const old = deviceCatalog(), fresh = deviceCatalog(); fresh.latestAssets[1].deviceTypes = ['tablet'];
    Object.assign(fresh.latestAsset, change);
    const selected = deviceLookup(old, fresh).app(7);
    for (const key of ['sha256', 'name', 'url', 'bundleName', 'versionCode']) {
      assert.equal(selected.latestAsset[key], old.latestAsset[key], JSON.stringify(change) + ': ' + key);
    }
    assert.deepEqual(Array.from(selected.latestAssets[1].deviceTypes), ['tablet'], 'a matching independent package may still gain metadata');
  }
});
test('device metadata backfill preserves authoritative package membership and never revives a removed attachment', () => {
  const old = deviceCatalog(), fresh = deviceCatalog();
  old.latestAssets = old.latestAssets.slice(0, 1);
  fresh.latestAssets[0].deviceTypes = ['tablet'];
  const retained = deviceLookup(old, fresh);
  assert.equal(retained.app(7).latestAssets.length, 1, 'a stale visible row cannot restore the withdrawn second package');
  assert.equal(retained.source(7, 'com.example.b'), undefined);
  assert.deepEqual(Array.from(retained.app(7).latestAssets[0].deviceTypes), ['tablet']);
  const replacement = deviceCatalog();
  replacement.latestAssets[0].deviceTypes = ['tablet']; replacement.latestAssets[1].sha256 = 'c'.repeat(64);
  assert.equal(deviceLookup(deviceCatalog(), replacement).app(7).latestAssets[1].sha256, 'b'.repeat(64));
});
test('duplicate old attachments cannot introduce another package during device metadata backfill', () => {
  const old = deviceCatalog(), fresh = deviceCatalog(); old.latestAssets[1] = old.latestAssets[0];
  fresh.latestAssets[0].deviceTypes = ['tablet'];
  const selected = deviceLookup(old, fresh).app(7);
  assert.equal(selected.latestAssets.length, 2);
  assert.equal(selected.latestAssets.some(asset => asset.bundleName === 'com.example.b'), false);
});
test('backfilling one package cannot erase or replace known device declarations in another independent object', () => {
  for (const changed of [[], ['tablet']]) {
    const old = deviceCatalog(), fresh = deviceCatalog();
    old.latestAsset.deviceTypes = ['phone']; old.latestAssets[0].deviceTypes = ['phone'];
    fresh.latestAsset.deviceTypes = changed; fresh.latestAssets[0].deviceTypes = changed;
    fresh.latestAssets[1].deviceTypes = ['2in1'];
    const selected = deviceLookup(old, fresh).app(7);
    assert.deepEqual(Array.from(selected.latestAsset.deviceTypes), ['phone']);
    assert.deepEqual(Array.from(selected.latestAssets[0].deviceTypes), ['phone']);
    assert.deepEqual(Array.from(selected.latestAssets[1].deviceTypes), ['2in1']);
  }
});
test('device supplementation also preserves known package membership and channel flags', () => {
  const old = deviceCatalog(), fresh = deviceCatalog();
  old.knownAssets = old.latestAssets.map(asset => release.HapAsset.copyWithDeviceTypes(asset, []));
  old.previewChannel = true; old.channelUnavailable = true;
  fresh.latestAsset.deviceTypes = ['tablet']; fresh.latestAssets[1].deviceTypes = ['2in1'];
  const selected = deviceLookup(old, fresh).app(7);
  assert.equal(selected.previewChannel, true); assert.equal(selected.channelUnavailable, true);
  assert.deepEqual(Array.from(selected.knownAssets, asset => asset.bundleName), ['com.example.a', 'com.example.b']);
  assert.deepEqual(Array.from(selected.knownAssets[0].deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(selected.knownAssets[1].deviceTypes), ['2in1']);
  assert.deepEqual(Array.from(old.knownAssets[0].deviceTypes), [], 'known package snapshots are not mutated');
});
test('same-revision device upgrades reject unverified digests and package identities', () => {
  for (const change of [{ sha256: '' }, { sha256: 'invalid' }, { name: '' }, { url: '' },
    { bundleName: '' }, { versionCode: 0 }]) {
    const old = deviceCatalog(), fresh = deviceCatalog();
    Object.assign(old.latestAssets[1], change); Object.assign(fresh.latestAssets[1], change);
    fresh.latestAssets[1].deviceTypes = ['tablet'];
    assert.equal(deviceLookup(old, fresh).app(7), old, JSON.stringify(change));
  }
});
test('device metadata upgrades do not promote an older or invalid catalog revision', () => {
  for (const updatedAt of ['99', 'invalid']) {
    const old = deviceCatalog(), fresh = deviceCatalog({ updated_at: updatedAt });
    fresh.latestAsset.deviceTypes = ['tablet']; fresh.latestAssets[0].deviceTypes = ['tablet'];
    const selected = deviceLookup(old, fresh).app(7);
    assert.equal(selected.updatedAt, '100', updatedAt);
    assert.equal(selected.latestAsset.sha256, old.latestAsset.sha256, updatedAt);
  }
});
test('a newer catalog keeps its selected revision and package while recovering only metadata for the same bytes', () => {
  const old = deviceCatalog(), fresh = deviceCatalog({ updated_at: '200', display_name: 'New title' });
  old.latestAsset.deviceTypes = ['tablet']; old.latestAssets[0].deviceTypes = ['tablet'];
  old.latestAssets[1].deviceTypes = ['2in1'];
  const selected = deviceLookup(old, fresh).app(7);
  assert.equal(selected.updatedAt, '200'); assert.equal(selected.displayName, 'New title');
  assert.deepEqual(Array.from(selected.latestAsset.deviceTypes), ['tablet']);
  assert.deepEqual(Array.from(selected.latestAssets[1].deviceTypes), ['2in1']);
  const replacement = deviceCatalog({ updated_at: '200', display_name: 'Replacement title' });
  replacement.latestAsset.sha256 = 'c'.repeat(64); replacement.latestAsset.versionCode = 3;
  replacement.latestAssets[0].sha256 = 'c'.repeat(64); replacement.latestAssets[0].versionCode = 3;
  const newPackage = deviceLookup(old, replacement).app(7);
  assert.equal(newPackage.updatedAt, '200'); assert.equal(newPackage.latestAsset.versionCode, 3);
  assert.equal(newPackage.latestAsset.sha256, 'c'.repeat(64));
  assert.deepEqual(Array.from(newPackage.latestAsset.deviceTypes), [], 'the old package declaration cannot cross a digest/build change');
  assert.deepEqual(Array.from(newPackage.latestAssets[0].deviceTypes), []);
});
