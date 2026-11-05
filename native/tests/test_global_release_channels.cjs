const { loadEts } = require('./load_ets.cjs');
const lookupRelease = loadEts('data/ReleaseInfo');
const { CatalogLookup } = loadEts('data/CatalogLookup', { './ReleaseInfo': lookupRelease,
  './CatalogApp': loadEts('data/CatalogApp', { './ReleaseInfo': lookupRelease }) });
const { InstallJob } = loadEts('jobs/InstallJob');
const ReleaseUpdate = require('./release_update_fixture.cjs').releaseUpdate({ INSTALLED: 'INSTALLED' });
const { CatalogPackageVariant } = loadEts('data/CatalogPackageVariant');
const { CatalogInstallTarget } = loadEts('jobs/CatalogInstallTarget', {
  '../data/CatalogPackageVariant': { CatalogPackageVariant }, './ReleaseUpdate': { ReleaseUpdate },
  './InstallJob': { InstallJob, InstallStage: { INSTALLED: 'INSTALLED' } }
});
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function fixture(disk = new Map()) {
  const f = { disk, requests: [], revision: 0, fail: false };
  const mocks = { '@kit.ArkData': { preferences: { async getPreferences(_, name) {
    return { async get(key, fallback) { return disk.get(name + ':' + key) ?? fallback; },
      async put(key, value) { disk.set(name + ':' + key, value); }, async flush() {},
      async getAll() { return Object.fromEntries([...disk].filter(([key]) => key.startsWith(name + ':'))
        .map(([key, value]) => [key.slice(name.length + 1), value])); } };
  } } }, '../jobs/ReleaseUpdate': { ReleaseUpdate: require('./release_update_fixture.cjs').releaseUpdate({ INSTALLED: 'INSTALLED' }) },
    './StoreClient': { StoreClient: class { listReleases(...args) {
    const d = {}; const promise = new Promise((resolve, reject) => Object.assign(d, { resolve, reject }));
    f.requests.push({ args, ...d }); return promise;
  } } } };
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data', file + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText, { exports, console, AppStorage: { get: () => f.revision, setOrCreate: (_, value) => f.revision = value },
      require: name => mocks[name] || (name.startsWith('./') ? load(name.slice(2)) : {}) });
    return exports;
  }
  f.registry = load('ReleaseChannelRegistry').ReleaseChannelRegistry;
  f.catalog = row => load('CatalogApp').CatalogApp.fromJson(row);
  f.app = (id = 7) => load('CatalogApp').CatalogApp.fromJson({ id, display_name: 'App',
    latest: { name: 'Stable' }, latest_asset: { name: 'app.hap', url: 'https://example.com/stable.hap',
      bundle_name: 'com.example.app', version_code: 2, version_name: '2', sha256: 'a'.repeat(64) } });
  f.release = (version = 3, preview = true) => load('ReleaseInfo').ReleaseInfo.fromJson({
    tag: 'v' + version, name: preview ? 'Preview' : 'Stable', prerelease: preview,
    assets: [{ name: 'app.hap', url: 'https://example.com/' + version + '.hap',
      bundle_name: 'com.example.app', version_code: version, version_name: String(version), sha256: 'b'.repeat(64) }] });
  return f;
}
const tick = () => new Promise(resolve => setImmediate(resolve));
test('preview targets retain each selected package’s declared device types across saved channel restoration', async () => {
  const f = fixture(), preview = f.release(3), other = f.release(3).assets[0];
  preview.assets[0].deviceTypes = ['tablet', '2in1'];
  Object.assign(other, { name: 'tv.hap', bundleName: 'com.example.tv', deviceTypes: ['tv'] });
  preview.assets.push(other);
  await f.registry.select({}, 7, true, [preview]);
  const restarted = fixture(new Map(f.disk)); await restarted.registry.restore({});
  const app = restarted.registry.apply(restarted.app());
  assert.deepEqual(Array.from(app.latestAssets[0].deviceTypes), ['tablet', '2in1']);
  assert.deepEqual(Array.from(app.latestAssets[1].deviceTypes), ['tv']);
  const legacyDisk = new Map(f.disk), saved = JSON.parse(legacyDisk.get('release-channel-targets:targets'));
  delete saved[0].assets[0].deviceTypes;
  legacyDisk.set('release-channel-targets:targets', JSON.stringify(saved));
  const legacy = fixture(legacyDisk); await legacy.registry.restore({});
  assert.deepEqual(Array.from(legacy.registry.apply(legacy.app()).latestAssets[0].deviceTypes), []);
});
test('fixed preview tags show the verified current build across history, hero and Discover after restart', async () => {
  const f = fixture(), release=f.release(120391);
  Object.assign(release,{tag:'v1.2.2-beta-120375',name:'轻启 1.2.2-beta（120391）'});
  Object.assign(release.assets[0],{versionName:'1.2.2-beta',releaseTag:release.tag,releaseName:release.name});
  await f.registry.select({},7,true,[release]);
  const restart=fixture(new Map(f.disk));await restart.registry.restore({});
  const {displayVersion,releaseDisplayVersion}=loadEts('data/DisplayVersion');
  const methods=[];
  for(const [file,names] of [['pages/Detail.ets',['selectedVersionLabel','currentRelease','currentReleaseLabel',
    'releaseOptions','releaseVersionLabel']],['pages/Index.ets',['latestVersionTag']]]) {
    const source=fs.readFileSync(path.join(root,file),'utf8');
    for(const name of names) {
      const at=source.indexOf('  private '+name+'(');
      assert.notEqual(at,-1,name);
      methods.push(source.slice(at,source.indexOf('\n  }',at)+4));
    }
  }
  const box={displayVersion,releaseDisplayVersion,ReleaseChannelRegistry:restart.registry};
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`,{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const ui=new box.Page();Object.assign(ui,{app:{displayName:'轻启',secondaryRepo:''},releases:[release],
    selectedReleaseIndex:0,selectedAsset:release.assets[0],releaseTotal:1});
  assert.equal(ui.selectedVersionLabel(),'1.2.2-beta-120391');
  assert.match(ui.currentReleaseLabel(),/120391/);assert.doesNotMatch(ui.currentReleaseLabel(),/120375/);
  assert.match(ui.releaseOptions()[0].value,/120391/);
  assert.equal(ui.latestVersionTag(restart.app()),'v1.2.2-beta-120391');
  assert.equal(release.tag,'v1.2.2-beta-120375');assert.equal(release.assets[0].versionCode,120391);
});

test('Discover uses the LNGA release version from a server or cached row without changing signing metadata', () => {
  const f = fixture();
  const { releaseDisplayVersion } = loadEts('data/DisplayVersion');
  const row = { id: 26, display_name: 'LNGA', latest: { name: 'v1.2.5', tag: '1.2.6' },
    latest_asset: { name: 'entry-default-unsigned.hap',
      url: 'https://github.com/apap6628114/lnga_harmony/releases/download/1.2.6/entry-default-unsigned.hap',
      bundle_name: 'com.example.nga_oh', version_code: 1000000, version_name: '1.0.0' } };
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const at = source.indexOf('  private latestVersionTag(');
  const method = source.slice(at, source.indexOf('\n  }', at) + 4);
  const box = { ReleaseChannelRegistry: f.registry, releaseDisplayVersion };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const ui = new box.Page();
  for (const raw of [row, JSON.parse(JSON.stringify(row))]) {
    const app = f.catalog(raw);
    assert.equal(ui.latestVersionTag(app), 'v1.2.6');
    assert.equal(app.latestAsset.versionName, '1.0.0');
    assert.equal(app.latestAsset.versionCode, 1000000);
  }
});
test('packages from an older release never inherit another bundle’s latest release name', () => {
  const f = fixture(), { releaseDisplayVersion } = loadEts('data/DisplayVersion');
  const make = (name, tag) => ({ name: name+'.hap', url: `https://github.com/o/r/releases/download/${tag}/${name}.hap`,
    version_code: 1000000, version_name: '1.0.0', bundle_name: 'com.example.'+name });
  const app = f.catalog({ id: 1, latest: { name: 'v1.2.6', tag: '1.2.6' },
    latest_asset: make('main', '1.2.6'), latest_assets: [make('main','1.2.6'), make('helper','1.2.5')] });
  assert.deepEqual(Array.from(app.latestAssets, a => releaseDisplayVersion(a.releaseName, a.releaseTag,
    a.versionName)), ['1.2.6','1.2.5']);
});
test('preview release versions survive persistence and migrate earlier snapshots using their own attachment URLs', async () => {
  const f = fixture(), { releaseDisplayVersion } = loadEts('data/DisplayVersion');
  const release = f.release(3);
  release.name = 'v1.2.6-beta.1'; release.tag = 'v1.2.6-beta.1';
  release.assets[0].releaseName = release.name; release.assets[0].releaseTag = release.tag;
  release.assets[0].versionName = '1.0.0';
  release.assets[0].url = 'https://github.com/o/r/releases/download/v1.2.6-beta.1/app.hap';
  await f.registry.select({}, 7, true, [release]);
  for (const migrate of [false, true]) {
    const disk = new Map(f.disk);
    if (migrate) {
      const saved = JSON.parse(disk.get('release-channel-targets:targets'));
      for (const target of saved) for (const asset of target.assets) {
        delete asset.releaseName; delete asset.releaseTag;
      }
      disk.set('release-channel-targets:targets', JSON.stringify(saved));
    }
    const restart = fixture(disk); await restart.registry.restore({});
    const asset = restart.registry.apply(restart.app()).latestAsset;
    assert.equal(releaseDisplayVersion(asset.releaseName, asset.releaseTag, asset.versionName), '1.2.6-beta.1');
    assert.equal(asset.versionName, '1.0.0'); assert.equal(asset.versionCode, 3);
  }
});
test('a mirror updating one bundle keeps the other primary preview package and all current variants', async () => {
  const f = fixture(), newest = f.release(4), primary = f.release(3), older = f.release(2);
  newest.sourceKind = 'secondary';
  primary.assets.push(Object.assign({}, primary.assets[0], { bundleName:'com.example.helper', name:'helper.hap' }));
  newest.assets.push(Object.assign({}, newest.assets[0], { name:'tablet.hap' }));
  await f.registry.select({}, 7, true, [newest,primary,older]);
  const selected = f.registry.apply(f.app());
  assert.deepEqual(Array.from(selected.latestAssets, a => [a.name,a.versionCode]),
    [['app.hap',4],['tablet.hap',4],['helper.hap',3]]);
});
test('a successful channel change supplies one preview target to Discover and Management without mutating the server catalog', async () => {
  const f = fixture(), catalog = f.app(); await f.registry.restore({});
  await f.registry.select({}, 7, true, [f.release()]);
  const visible = f.registry.apply(catalog), management = f.registry.apply(catalog);
  assert.equal(visible, management); assert.equal(visible.latestAsset.versionCode, 3);
  assert.equal(catalog.latestAsset.versionCode, 2); assert.equal(visible.previewChannel, true);
  await f.registry.select({}, 7, false, [f.release(2, false)]);
  assert.equal(f.registry.apply(catalog), catalog);
});
test('a fresh stable release read updates stale discovery and management targets while preserving the HAP variant', async () => {
  const f=fixture(), catalog=f.app(), latest=f.release(3,false);
  catalog.updatedAt='100';catalog.latestAsset.name='Petrelgram-1.5.2-unsigned.hap';
  Object.assign(latest.assets[0],{name:'Petrelgram-1.5.3-unsigned.hap',versionName:'1.5.3',releaseName:'Petrelgram 1.5.3',releaseTag:'v1.5.3'});
  latest.assets.unshift(Object.assign({},latest.assets[0],{name:'Petrelgram-1.5.3-unsigned.app.zip / Petrelgram-1.5.3-unsigned.app',
    sha256:'c'.repeat(64),url:'https://example.com/archive.app#qingqi-package=entry.app'}));
  await f.registry.select({},7,false,[latest],catalog);
  const projected=f.registry.apply(catalog);
  assert.equal(projected.latestAsset.name,'Petrelgram-1.5.3-unsigned.hap');
  assert.equal(projected.latestAsset.versionCode,3);assert.equal(projected.previewChannel,false);
  assert.equal(projected.latestAssets.length,2);assert.equal(f.registry.apply(catalog),projected);
  assert.equal(catalog.latestAsset.versionCode,2);
  const lookup=new CatalogLookup([catalog],[catalog],true,f.revision,app=>f.registry.apply(app));
  assert.equal(lookup.app(7).latestAsset,projected.latestAsset);
  assert.equal(lookup.source(7,projected.latestAsset.bundleName).latestAsset,projected.latestAsset);
});
test('a late stable detail snapshot never replaces a newer complete catalog or newer same-code release',async()=>{
  const f=fixture(), old=f.app();old.updatedAt='100';
  await f.registry.select({},7,false,[f.release(3,false)],old);
  const fresh=f.app();fresh.updatedAt='200';fresh.latestAsset.versionCode=4;
  assert.equal(f.registry.apply(fresh),fresh);
  const equal=f.app();equal.updatedAt='100';equal.latestAsset.versionCode=3;
  equal.latestAsset.versionName='1.5.4';equal.latestAsset.releaseTag='v1.5.4';
  const stale=f.release(3,false);stale.assets[0].versionName='1.5.3';stale.assets[0].releaseTag='v1.5.3';
  await f.registry.select({},7,false,[stale],equal);
  assert.equal(f.registry.apply(equal).latestAsset,equal.latestAsset,'cached old release must not lower a same-code catalog target');
});
test('a same-code and same-tag stable package replacement keeps the newer catalog digest after a late detail read',async()=>{
  const f=fixture(), old=f.app(), release=f.release(2,false);old.updatedAt='100';
  await f.registry.select({},7,false,[release],old);
  const current=f.app();current.updatedAt='200';current.latestAsset.sha256='d'.repeat(64);
  assert.equal(f.registry.apply(current),current);
  assert.equal(f.registry.apply(current).latestAsset.sha256,'d'.repeat(64));
});
test('same-package device metadata backfill survives a stable target at the same catalog revision', async () => {
  const f = fixture(), old = f.app(), release = f.release(2, false);
  Object.assign(old.latestAsset, release.assets[0]); old.updatedAt = '100';
  const originalRelease = release.assets[0]; originalRelease.mirrorUrls = ['https://example.com/mirror.hap'];
  await f.registry.select({}, 7, false, [release], old);
  const fresh = f.app(); Object.assign(fresh.latestAsset, old.latestAsset,
    { deviceTypes: [' TABLET ', '2IN1', 'tablet'], releaseName: 'Catalog label' }); fresh.updatedAt = '100';
  const selected = f.registry.apply(fresh).latestAsset;
  assert.deepEqual(Array.from(selected.deviceTypes), ['tablet', '2in1']);
  assert.equal(selected.releaseName, originalRelease.releaseName, 'only device metadata is supplemented');
  assert.equal(selected.mirrorUrls, originalRelease.mirrorUrls);
  assert.deepEqual(Array.from(originalRelease.deviceTypes), [], 'projection must not rewrite the old release snapshot');
  assert.deepEqual(Array.from(old.latestAsset.deviceTypes), [], 'projection must not rewrite the old catalog snapshot');
  assert.equal(f.registry.apply(fresh).latestAsset, selected, 'the supplemented projection remains cached');
});
test('same-package device metadata changes revalidate catalog and releases without changing versions', () => {
  const f = fixture(), source = f.app(), release = f.release(2, false);
  Object.assign(source.latestAsset, release.assets[0]);
  source.latestAsset.deviceTypes = ['tablet', '2in1'];
  assert.equal(f.registry.staleReleases(source, [release]), true, 'a cached release can predate metadata backfill');
  release.assets[0].deviceTypes = ['2IN1', ' TABLET ', 'tablet'];
  assert.equal(f.registry.staleReleases(source, [release]), false, 'case, order and duplicate tokens are equivalent');
  source.latestAsset.deviceTypes = [];
  assert.equal(f.registry.staleReleases(source, [release]), true, 'a cached catalog can also predate metadata backfill');
  source.latestAsset.deviceTypes = ['phone'];
  assert.equal(f.registry.staleReleases(source, [release]), true, 'contradictory declarations require a fresh read');
  assert.equal(source.latestAsset.versionCode, 2); assert.equal(release.assets[0].versionCode, 2);
  release.assets[0].sha256 = '';
  assert.equal(f.registry.staleReleases(source, [release]), false, 'unknown digests cannot establish identical package metadata');
});
test('device metadata supplementation requires an exact verified attachment and never guesses from variants', async () => {
  for (const change of [{ sha256: '' }, { sha256: 'invalid' }, { sha256: 'c'.repeat(64) },
    { name: 'app.app' }, { url: 'https://example.com/2.hap#qingqi-package=other.hap' },
    { releaseTag: 'another-release' }]) {
    const f = fixture(), old = f.app(), release = f.release(2, false);
    Object.assign(old.latestAsset, release.assets[0]); old.updatedAt = '100';
    await f.registry.select({}, 7, false, [release], old);
    const fresh = f.app(); Object.assign(fresh.latestAsset, old.latestAsset, change, { deviceTypes: ['tablet'] });
    fresh.updatedAt = '100';
    const selected = f.registry.apply(fresh).latestAssets.find(asset => asset.url === release.assets[0].url &&
      asset.name === release.assets[0].name);
    assert.ok(selected, JSON.stringify(change));
    assert.deepEqual(Array.from(selected.deviceTypes), [], JSON.stringify(change));
  }
});
test('stable projection preserves a release declaration when a catalog declaration differs or disappears', async () => {
  const f = fixture(), source = f.app(), release = f.release(2, false);
  release.assets[0].deviceTypes = ['tablet'];
  Object.assign(source.latestAsset, release.assets[0], { deviceTypes: ['phone'] }); source.updatedAt = '100';
  await f.registry.select({}, 7, false, [release], source);
  assert.deepEqual(Array.from(f.registry.apply(source).latestAsset.deviceTypes), ['tablet']);
  const fresh = f.app(); Object.assign(fresh.latestAsset, source.latestAsset, { deviceTypes: [] }); fresh.updatedAt = '100';
  assert.deepEqual(Array.from(f.registry.apply(fresh).latestAsset.deviceTypes), ['tablet']);
});
test('restored preview devices stay with that channel even when stable has the same attachment digest', async () => {
  const f = fixture(), preview = f.release(2, true), source = f.app();
  Object.assign(source.latestAsset, preview.assets[0], { deviceTypes: ['phone'] });
  await f.registry.select({}, 7, true, [preview], source);
  const restart = fixture(new Map(f.disk)); await restart.registry.restore({});
  assert.deepEqual(Array.from(restart.registry.apply(source).latestAsset.deviceTypes), [],
    'a missing preview declaration must not borrow a stable channel declaration');
  preview.assets[0].deviceTypes = ['tablet', '2in1'];
  await restart.registry.select({}, 7, true, [preview], source);
  assert.deepEqual(Array.from(restart.registry.apply(source).latestAsset.deviceTypes), ['tablet', '2in1']);
  const restored = fixture(new Map(restart.disk)); await restored.registry.restore({});
  assert.deepEqual(Array.from(restored.registry.apply(source).latestAsset.deviceTypes), ['tablet', '2in1']);
});
test('stable projection keeps older helper packages outside the first release page',async()=>{
  const f=fixture(), catalog=f.app();catalog.updatedAt='100';
  catalog.latestAssets.push({...catalog.latestAsset,bundleName:'com.example.helper',name:'helper.hap'});
  await f.registry.select({},7,false,[f.release(3,false)],catalog);
  assert.deepEqual(Array.from(f.registry.apply(catalog).latestAssets,a=>a.bundleName),['com.example.app','com.example.helper']);
});
test('same-revision stable target cannot lower helper builds or mix its HAP and APP variants',async()=>{
  const f=fixture(), catalog=f.app(), release=f.release(4,false);catalog.updatedAt='100';
  const make=(name,code,tag)=>({...catalog.latestAsset,bundleName:'com.example.helper',name,
    versionCode:code,versionName:tag,releaseTag:'v'+tag,url:'https://example.com/'+name});
  const currentHap=make('helper-v2.0.0.hap',8,'2.0.0'),currentApp=make('helper-v2.1.0.app',9,'2.1.0');
  catalog.latestAssets.push(currentHap,currentApp);
  release.assets.push(make('helper-v1.0.0.hap',6,'1.0.0'),make('helper-v1.1.0.app',7,'1.1.0'));
  await f.registry.select({},7,false,[release],catalog);
  const projected=f.registry.apply(catalog);
  assert.equal(projected.latestAsset.versionCode,4,'the updated primary is preserved');
  assert.deepEqual(Array.from(projected.latestAssets.filter(a=>a.bundleName==='com.example.helper'),a=>[a.name,a.versionCode]),
    [[currentHap.name,8],[currentApp.name,9]]);
  const fresh=f.app();fresh.updatedAt='100';fresh.latestAssets=[fresh.latestAsset,{...currentHap,versionCode:10},currentApp];
  const sameRevision=f.registry.apply(fresh);
  assert.equal(sameRevision.latestAssets.find(a=>a.name===currentHap.name).versionCode,10);
});
test('newer stable source membership removes a withdrawn helper instead of preserving an older page ghost',async()=>{
  const f=fixture(), old=f.app(), fresh=f.app(), release=f.release(3,false);
  old.updatedAt='100';fresh.updatedAt='200';
  old.latestAssets.push({...old.latestAsset,name:'removed-helper.hap',bundleName:'com.example.removed'});
  await f.registry.select({},7,false,[release],fresh);
  const projected=f.registry.apply(old);
  assert.equal(projected.latestAssets.some(a=>a.bundleName==='com.example.removed'),false);
  assert.equal(projected.knownAssets.some(a=>a.bundleName==='com.example.removed'),false);
});
test('an authoritative empty stable source clears packages withdrawn since the old discovery snapshot',async()=>{
  const f=fixture(), old=f.app(), empty=f.app();old.updatedAt='100';empty.updatedAt='200';
  empty.latestAsset=undefined;empty.latestAssets=[];
  await f.registry.select({},7,false,[],empty);
  const projected=f.registry.apply(old);
  assert.equal(projected.latestAsset,undefined);assert.equal(projected.latestAssets.length,0);
  assert.equal(projected.knownAssets.length,0);assert.equal(projected.channelUnavailable,true);
});
test('missing or invalid stable source timestamps cannot overwrite a known current catalog',async()=>{
  for(const timestamp of ['', 'invalid', '0', '-1']) {
    const f=fixture(), current=f.app(), source=f.app();current.updatedAt='200';source.updatedAt=timestamp;
    await f.registry.select({},7,false,[f.release(3,false)],source);
    assert.equal(f.registry.apply(current),current);
  }
});
function petrelPages() {
  const f=fixture(), bundle='com.miramira8295.petrelgram';
  const hap={name:'Petrelgram-1.5.3-unsigned.hap',
    url:'https://github.com/miramira8295/Petrelgram/releases/download/v1.5.3/Petrelgram-1.5.3-unsigned.hap',
    bundle_name:bundle,version_code:1003042,version_name:'1.5.3',
    sha256:'af32b6cb813d3a91ed5f61f249be1de1891ceb324ffb0c6197fbea95ffd092a4'};
  const appPackage={...hap,name:'Petrelgram-1.5.3-unsigned.app.zip / Petrelgram-1.5.3-unsigned.app',
    url:'https://github.com/miramira8295/Petrelgram/releases/download/v1.5.3/Petrelgram-1.5.3-unsigned.app.zip#qingqi-package=Petrelgram-1.5.3-unsigned.app',
    sha256:'286f1303bf5d507b98da811cf67b697b984ba7bda0b846cf0183a3a7c703d573'};
  const catalog=f.catalog({id:10,display_name:'Petrelgram',updated_at:1791676210,
    latest:{tag:'v1.5.3',name:'Petrelgram 1.5.3'},latest_asset:hap,latest_assets:[hap,appPackage]});
  const latest=f.release(1003042,false);Object.assign(latest,{tag:'v1.5.3',name:'Petrelgram 1.5.3',assets:
    [appPackage,hap].map(a=>Object.assign(new (loadEts('data/ReleaseInfo').HapAsset)(),{
      name:a.name,url:a.url,bundleName:bundle,versionCode:a.version_code,versionName:a.version_name,
      sha256:a.sha256,releaseTag:'v1.5.3',releaseName:'Petrelgram 1.5.3'}))});
  const jobs=[{id:'hap-done',appId:10,bundleName:bundle,versionCode:1003042,versionName:'1.5.3',
    assetName:hap.name,expectedSha256:hap.sha256,catalogSha256:hap.sha256,releaseTag:'v1.5.3',
    stage:'INSTALLED',installedUpdateTime:1234,stageHistory:[{stage:'INSTALLED',at:5000}],updatedAt:5000}];
  f.installed=1003042;f.installedName='1.5.3';f.detailRequests=[];
  const box={CatalogInstallTarget, CatalogPackageVariant, InstallJob,
    UpdatePolicy:{restore:async()=>{},disabled:bundle=>f.pausedBundles?.has(bundle)??false},
    ReleaseChannelRegistry:f.registry,HapAsset:loadEts('data/ReleaseInfo').HapAsset,
    ReleaseUpdate:require('./release_update_fixture.cjs').releaseUpdate({INSTALLED:'INSTALLED'}),
    CatalogInstallIdentity:{bundle:(_id,asset)=>asset?.bundleName??''},
    InstalledAppRegistry:{isAppGallery:()=>false,hasApplicationOrigin:()=>true,persist:async()=>{},versionName:()=>f.installedName,signingIdentity:()=>({updateTime:f.signingTime??1234})},
    LocalBundles:{isKnown:v=>v>=0,installedVersion:()=>f.installed},UpdateTarget:class{},
    releaseDisplayVersion:loadEts('data/DisplayVersion').releaseDisplayVersion,
    getContext:()=>({}),Detail:{RELEASES_PER_PAGE:20,CHECK_COOLDOWN_MS:0,CHECK_TIMEOUT_MS:30000,withDeadline:promise=>promise},
    StoreClient:class {
      async refreshApp(){return 'done';}
      async appDetail(...args){
        f.detailRequests.push(['appDetail',...args]);
        if(args[1]===true&&f.forceGate)await f.forceGate;
        if(args[1]===true&&f.forceError)throw Error(f.forceError);
        return f.freshCatalog??catalog;
      }
      async listReleases(...args){
        f.detailRequests.push(['listReleases',...args]);
        const force=args[4]===true;
        if(force&&f.forceGate)await f.forceGate;
        if(force&&f.forceError)throw Error(f.forceError);
        const items=(force?f.forcedReleases:f.cachedReleases)??f.freshReleases??[latest];
        return {items,page:1,total:items.length};
      }
    },errorText:e=>e.message};
  function page(file,names) {
    const source=fs.readFileSync(path.join(root,'pages',file+'.ets'),'utf8');
    const methods=names.map(name=>{const at=source.search(new RegExp(`^  private (?:async )?${name}\\(`,'m'));
      assert.notEqual(at,-1,name);return source.slice(at,source.indexOf('\n  }',at)+4);});
    const context={...box};vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page=Page;`,{
      compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);return new context.Page();
  }
  f.detail=page('Detail',['loadInitialReleases','checkForUpdates','selectReleaseChannel','reconcileSelectedAsset','selectRelease','refreshInstalledVersion',
    'selectedBundleName','installedForApp','updateAvailable','syncUpdatePolicy','selectedDowngrade','installButtonLabel',
    'selectedVersionLabel','currentRelease']);
  Object.assign(f.detail,{app:catalog,releases:[],installedJobs:jobs,selectedAsset:new box.HapAsset(),
    selectedReleaseIndex:0,releaseLoading:false,releaseMoreBusy:false,refreshBusy:false,disposed:false,
    showPreviewReleases:false,explicitSelection:false,pageVisible:true,lastCheckAt:0,updatePolicyReady:true,updatesPaused:false,
    animateOverlay:action=>action(),currentInstallTask:()=>undefined,syncInstallTask(){},loadMoreReleases(){},confirmInstalledViaDevice(){}});
  f.index=page('Index',['updateForApp','assetForBundle', 'catalogTarget','latestAssets']);
  Object.assign(f.index,{catalogApp:()=>f.registry.apply(catalog),displayInstalledVersion:()=>f.installed,
    allInstalledJobs:()=>jobs,installedJobs:jobs,installedVersionOf:()=>f.installed,updatePolicyReady:true});
  f.catalog=catalog;f.latest=latest;f.hap=hap;f.bundle=bundle;f.jobs=jobs;
  f.client=new box.StoreClient();f.load=()=>f.detail.loadInitialReleases(f.client);
  return f;
}
function sameNumberPetrelReplacement(f) {
  const fresh=f.release(1003042,false);
  Object.assign(fresh,{tag:f.latest.tag,name:f.latest.name,assets:f.latest.assets.map(asset=>({...asset,
    sha256:asset.name===f.hap.name?'d'.repeat(64):asset.sha256}))});
  f.catalog.updatedAt='1791676211';f.catalog.latestAsset.sha256='d'.repeat(64);
  f.catalog.latestAssets.find(asset=>asset.name===f.hap.name).sha256='d'.repeat(64);
  f.freshCatalog=f.catalog;f.cachedReleases=[f.latest];f.forcedReleases=[fresh];
  return fresh;
}
test('stopping and restoring one bundle synchronizes Discovery and Detail without altering the chosen release', async () => {
  const f=petrelPages(); sameNumberPetrelReplacement(f); await f.load();
  assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3'); assert.ok(f.index.updateForApp(10));
  const asset=f.detail.selectedAsset, requests=f.detailRequests.length;
  f.pausedBundles=new Set([f.bundle]); f.detail.syncUpdatePolicy();
  assert.equal(f.detail.installButtonLabel(),'打开应用'); assert.equal(f.index.updateForApp(10),undefined);
  assert.equal(f.detail.selectedAsset,asset); assert.equal(f.detailRequests.length,requests);
  f.pausedBundles.clear(); f.detail.syncUpdatePolicy();
  assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3'); assert.ok(f.index.updateForApp(10));
});
test('initial Detail detects a same-number digest conflict and starts exactly one concurrent forced pair',async()=>{
  const f=petrelPages(), fresh=sameNumberPetrelReplacement(f);
  let resume;f.forceGate=new Promise(resolve=>resume=resolve);
  const work=f.load();await tick();
  assert.deepEqual(f.detailRequests,[['listReleases',10,1,20,false],
    ['appDetail',10,true],['listReleases',10,1,20,false,true]],
    'the fresh catalog and fresh releases start together; a sequential fetch would not start both before the gate');
  assert.equal(f.detail.releaseLoading,true);resume();await work;
  assert.equal(f.detail.releaseLoading,false);assert.equal(f.detail.releaseMessage,'');
  assert.equal(f.detail.selectedAsset.sha256,'d'.repeat(64));
  assert.equal(f.detail.selectedAsset.url,fresh.assets[1].url);
  assert.equal(f.index.updateForApp(10).assetSha256,'d'.repeat(64));
  assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3');
});
test('initial Detail revalidates metadata-only backfill and selects the fresh declaration for the installed variant', async () => {
  const f = petrelPages(), fresh = f.release(1003042, false);
  Object.assign(fresh, { tag: f.latest.tag, name: f.latest.name,
    assets: f.latest.assets.map(asset => ({ ...asset,
      deviceTypes: asset.name === f.hap.name ? ['tablet', '2in1'] : ['phone'] })) });
  for (const asset of f.catalog.latestAssets.concat([f.catalog.latestAsset])) {
    asset.deviceTypes = asset.name === f.hap.name ? ['tablet', '2in1'] : ['phone'];
  }
  f.freshCatalog = f.catalog; f.cachedReleases = [f.latest]; f.forcedReleases = [fresh];
  await f.load();
  assert.deepEqual(f.detailRequests, [['listReleases', 10, 1, 20, false],
    ['appDetail', 10, true], ['listReleases', 10, 1, 20, false, true]]);
  assert.equal(f.detail.selectedAsset.name, f.hap.name, 'the completed HAP receipt still chooses the HAP');
  assert.equal(f.detail.selectedAsset.sha256, f.hap.sha256);
  assert.deepEqual(Array.from(f.detail.selectedAsset.deviceTypes), ['tablet', '2in1']);
  assert.deepEqual(Array.from(f.latest.assets[1].deviceTypes), [], 'the cached pre-backfill release remains unchanged');
});
test('an installed APP replacement also invalidates its cached detail page when the primary HAP is unchanged',async()=>{
  const f=petrelPages(), app=f.latest.assets[0], fresh=f.release(1003042,false);
  Object.assign(fresh,{tag:f.latest.tag,name:f.latest.name,assets:f.latest.assets.map(asset=>({...asset,
    sha256:asset.name===app.name?'d'.repeat(64):asset.sha256}))});
  f.catalog.updatedAt='1791676211';
  f.catalog.latestAssets.find(asset=>asset.name===app.name).sha256='d'.repeat(64);
  Object.assign(f.jobs[0],{assetName:app.name,expectedSha256:'d'.repeat(64),catalogSha256:'d'.repeat(64)});
  f.cachedReleases=[f.latest];f.forcedReleases=[fresh];f.freshCatalog=f.catalog;
  assert.equal(f.index.updateForApp(10),undefined,'Discover already knows the installed APP is current');
  await f.load();
  assert.equal(f.detailRequests.length,3,'an APP cache conflict needs the same single forced pair');
  assert.equal(f.detail.selectedAsset.name,app.name);assert.equal(f.detail.selectedAsset.sha256,'d'.repeat(64));
  assert.equal(f.detail.installButtonLabel(),'打开应用');assert.equal(f.index.updateForApp(10),undefined);
});
test('normal initial loading and preview selection perform no redundant forced cache read',async()=>{
  const f=petrelPages();await f.load();
  assert.deepEqual(f.detailRequests,[['listReleases',10,1,20,false]]);
  await f.detail.selectReleaseChannel(true);
  assert.deepEqual(f.detailRequests,[['listReleases',10,1,20,false],['listReleases',10,1,20,true]]);
  assert.equal(f.detail.showPreviewReleases,true);
});
test('switching back to stable revalidates conflicting caches once before selecting the fresh package',async()=>{
  const f=petrelPages();await f.load();f.detailRequests=[];
  sameNumberPetrelReplacement(f);f.detail.showPreviewReleases=true;
  await f.detail.selectReleaseChannel(false);
  assert.deepEqual(f.detailRequests,[['listReleases',10,1,20,false],
    ['appDetail',10,true],['listReleases',10,1,20,false,true]]);
  assert.equal(f.detail.showPreviewReleases,false);assert.equal(f.detail.releaseMoreBusy,false);
  assert.equal(f.detail.selectedAsset.sha256,'d'.repeat(64));assert.equal(f.detail.releaseMessage,'');
  assert.equal(f.registry.preview(10),false);
});
test('a failed forced cache pair preserves the existing Detail selection and release page',async()=>{
  const f=petrelPages();await f.load();
  const selected=f.detail.selectedAsset,releases=f.detail.releases;
  sameNumberPetrelReplacement(f);f.forceError='offline';f.detailRequests=[];
  await f.load();
  assert.equal(f.detail.selectedAsset,selected);assert.equal(f.detail.releases,releases);
  assert.equal(f.detail.releaseLoading,false);assert.match(f.detail.releaseMessage,/offline/);
  assert.equal(f.detailRequests.length,3,'one cached read plus the two forced reads, with no retry loop');
  assert.equal(f.registry.apply(f.catalog).latestAsset.sha256,'d'.repeat(64),
    'the failed old page cannot write its old digest over the known catalog target');
  f.detail.showPreviewReleases=true;f.detail.explicitSelection=true;f.detailRequests=[];
  await f.detail.selectReleaseChannel(false);
  assert.equal(f.detail.showPreviewReleases,true);assert.equal(f.detail.explicitSelection,true);
  assert.equal(f.detail.selectedAsset,selected);assert.equal(f.detail.releases,releases);
  assert.equal(f.detail.releaseMoreBusy,false);assert.match(f.detail.releaseMessage,/offline/);
  assert.equal(f.detailRequests.length,3);
});
test('actual Petrelgram APP-before-HAP release ordering gives Discover, Detail and Management one update target',async()=>{
  const f=petrelPages();f.installed=1003041;f.installedName='1.5.2';await f.load();
  const discovery=f.index.updateForApp(10),management=f.index.updateForApp(10,f.bundle,f.jobs[0].assetName,1003041);
  assert.equal(discovery.assetName,f.hap.name);assert.equal(management.assetName,f.hap.name);
  assert.equal(f.detail.selectedAsset.name,f.hap.name);assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3');
  f.installed=1003042;f.installedName='1.5.3';f.detail.refreshInstalledVersion();
  assert.equal(f.index.updateForApp(10),undefined);
  assert.equal(f.index.updateForApp(10,f.bundle,f.jobs[0].assetName,1003042),undefined);
  assert.equal(f.detail.installButtonLabel(),'打开应用');
});
test('installed current Petrelgram HAP opens on initial detail entry; explicitly selecting APP remains a replacement',async()=>{
  const f=petrelPages();await f.load();
  assert.equal(f.detail.selectedAsset.name,f.hap.name);assert.equal(f.detail.installButtonLabel(),'打开应用');
  f.detail.explicitSelection=true;f.detail.selectedAsset=f.latest.assets[0];f.detail.refreshInstalledVersion();
  assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3','a user-selected different package hash stays actionable');
  const reordered={...f.latest,assets:[f.latest.assets[1],f.latest.assets[0]]};
  f.detail.releases=[reordered];f.detail.selectRelease(0);
  assert.equal(f.detail.selectedAsset.name,f.latest.assets[0].name,'history selection keeps the explicit APP format');
  f.detail.selectedAsset=f.latest.assets[1];f.detail.selectRelease(0);
  assert.equal(f.detail.selectedAsset.name,f.hap.name);assert.equal(f.detail.installButtonLabel(),'打开应用');
});
test('installed Petrelgram APP and an unknown device observation retain one default target across all three pages',async()=>{
  const f=petrelPages(), app=f.latest.assets[0];
  Object.assign(f.jobs[0],{assetName:app.name,expectedSha256:app.sha256,catalogSha256:app.sha256});
  await f.load();
  assert.equal(f.detail.selectedAsset.name,app.name);assert.equal(f.detail.installButtonLabel(),'打开应用');
  assert.equal(f.index.catalogTarget(f.registry.apply(f.catalog)).name,app.name);
  assert.equal(f.index.updateForApp(10),undefined);
  assert.equal(f.index.updateForApp(10,f.bundle,f.jobs[0].assetName,1003042),undefined);
  f.installed=-1;f.detail.refreshInstalledVersion();
  assert.equal(f.detail.selectedAsset.name,app.name);assert.equal(f.detail.installButtonLabel(),'打开应用');
  assert.equal(f.index.catalogTarget(f.registry.apply(f.catalog)).name,app.name);
  assert.equal(f.index.updateForApp(10),undefined);
  assert.equal(f.index.updateForApp(10,f.bundle,f.jobs[0].assetName,1003042),undefined);
  f.installed=0;f.detail.refreshInstalledVersion();
  assert.equal(f.detail.selectedAsset.name,f.hap.name);assert.equal(f.detail.installButtonLabel(),'安装应用');
  assert.equal(f.index.catalogTarget(f.registry.apply(f.catalog)).name,f.hap.name);
});
test('ordinary detail refresh advances the default to the latest release while explicit historical selection survives',async()=>{
  const f=petrelPages(), app=f.latest.assets[0];
  Object.assign(f.jobs[0],{assetName:app.name,expectedSha256:app.sha256,catalogSha256:app.sha256});
  await f.load();
  const newer=f.release(1003043,false);
  Object.assign(newer,{tag:'v1.5.4',name:'Petrelgram 1.5.4',assets:f.latest.assets.map(asset=>({...asset,
    name:asset.name.replace('1.5.3','1.5.4'),url:asset.url.replaceAll('1.5.3','1.5.4'),
    versionCode:1003043,versionName:'1.5.4',releaseTag:'v1.5.4',releaseName:'Petrelgram 1.5.4',sha256:'d'.repeat(64)}))});
  f.freshCatalog=Object.assign({},f.catalog,{updatedAt:'1791676211',latestAsset:newer.assets[1],latestAssets:newer.assets});
  f.freshReleases=[newer,f.latest];await f.detail.checkForUpdates();
  assert.equal(f.detail.selectedAsset.name,newer.assets[0].name);
  assert.equal(f.detail.installButtonLabel(),'更新到 1.5.4');
  assert.equal(f.index.updateForApp(10).assetName,newer.assets[0].name);
  assert.equal(f.index.updateForApp(10,f.bundle,f.jobs[0].assetName,1003042).assetName,newer.assets[0].name);
  f.detail.selectRelease(1);
  assert.equal(f.detail.explicitSelection,true);assert.equal(f.detail.selectedAsset.name,app.name);
  await f.detail.checkForUpdates();
  assert.equal(f.detail.selectedReleaseIndex,1);assert.equal(f.detail.selectedAsset.url,app.url);
  assert.equal(f.detail.installButtonLabel(),'打开应用','a manual older/current release remains the explicit choice');
});
test('a same-number APP replacement updates consistently and one completed install removes that update everywhere',async()=>{
  const f=petrelPages(), app=f.latest.assets[0];
  Object.assign(f.jobs[0],{assetName:app.name,expectedSha256:app.sha256,catalogSha256:app.sha256});
  await f.load();
  const changed=f.release(1003042,false);
  Object.assign(changed,{tag:f.latest.tag,name:f.latest.name,
    assets:f.latest.assets.map(asset=>({...asset,sha256:asset.name===app.name?'d'.repeat(64):asset.sha256}))});
  f.freshCatalog=Object.assign({},f.catalog,{updatedAt:'1791676211',latestAsset:changed.assets[1],latestAssets:changed.assets});
  f.freshReleases=[changed];await f.detail.checkForUpdates();
  assert.equal(f.detail.selectedAsset.name,app.name);assert.equal(f.detail.installButtonLabel(),'更新到 1.5.3');
  assert.equal(f.index.updateForApp(10).assetSha256,'d'.repeat(64));
  assert.equal(f.index.updateForApp(10,f.bundle,app.name,1003042).assetSha256,'d'.repeat(64));
  // The first completed submission writes its actual/catalog digest and current device identity.
  f.signingTime=2000;Object.assign(f.jobs[0],{expectedSha256:'d'.repeat(64),catalogSha256:'d'.repeat(64),
    installedUpdateTime:2000,stageHistory:[{stage:'INSTALLED',at:6000}],updatedAt:6000});
  f.detail.refreshInstalledVersion();
  assert.equal(f.detail.installButtonLabel(),'打开应用');assert.equal(f.index.updateForApp(10),undefined);
  assert.equal(f.index.updateForApp(10,f.bundle,app.name,1003042),undefined);
});
test('preview target and mode survive restart, with an independent stable default for other apps', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const restart = fixture(f.disk); await restart.registry.restore({});
  assert.equal(restart.registry.preview(7), true); assert.equal(restart.registry.preview(8), false);
  assert.equal(restart.registry.apply(restart.app()).latestAsset.versionCode, 3);
});
test('an empty preview channel preserves application identity and does not offer the stable package', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, []);
  const selected = f.registry.apply(f.app());
  assert.equal(selected.channelUnavailable, true); assert.equal(selected.latestAsset, undefined);
  assert.equal(selected.latestAssets.length, 0); assert.equal(selected.knownAssets[0].bundleName, 'com.example.app');
});
test('only explicitly selected previews are requested, concurrent refreshes share the request, and network failure retains the target', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const work = f.registry.refreshTargets({}, [f.app(), f.app(8)], true);
  const joined = f.registry.refreshTargets({}, [f.app()], true); await tick();
  assert.equal(f.requests.length, 1); assert.deepEqual(f.requests[0].args, [7, 1, 20, true, true]);
  f.requests[0].reject(Error('offline')); await Promise.all([work, joined]);
  assert.equal(f.registry.preview(7), true); assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 3);
});

test('preview refresh runs two reads at a time and completes only after every selected target settles', async () => {
  const f = fixture(), apps = [7, 8, 9, 10].map(id => f.app(id));
  for (const app of apps) await f.registry.select({}, app.id, true, [f.release()]);
  let finished = false;
  const work = f.registry.refreshTargets({}, apps.concat([apps[0]]), true).then(() => finished = true);
  await tick(); assert.deepEqual(f.requests.map(r => r.args[0]), [7, 8]);
  f.requests[1].resolve({ items: [f.release(4)] }); await tick();
  assert.deepEqual(f.requests.map(r => r.args[0]), [7, 8, 9]);
  assert.equal(finished, false);
  f.requests[0].reject(Error('offline')); await tick();
  assert.deepEqual(f.requests.map(r => r.args[0]), [7, 8, 9, 10]);
  assert.equal(f.registry.apply(apps[0]).latestAsset.versionCode, 3, 'failed read retains its known preview');
  f.requests[2].resolve({ items: [f.release(5)] }); await tick(); assert.equal(finished, false);
  f.requests[3].resolve({ items: [f.release(6)] }); await work;
  assert.deepEqual(apps.map(app => f.registry.apply(app).latestAsset.versionCode), [3, 4, 5, 6]);
});
test('a late preview response cannot undo a subsequent stable selection', async () => {
  const f = fixture(); await f.registry.select({}, 7, true, [f.release()]);
  const work = f.registry.refreshTargets({}, [f.app()], true); await tick();
  await f.registry.select({}, 7, false, [f.release(2, false)]);
  f.requests[0].resolve({ items: [f.release(4)] }); await work;
  assert.equal(f.registry.preview(7), false); assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 2);
});
test('older boolean-only preferences recover the preview channel and read its target in the background', async () => {
  const f = fixture(new Map([['release-channels:app-7', true], ['release-channel-targets:targets', '[null]']]));
  await f.registry.restore({}); assert.equal(f.registry.preview(7), true);
  assert.equal(f.registry.apply(f.app()).channelUnavailable, true);
  const work = f.registry.refreshTargets({}, [f.app()]); await tick();
  f.requests[0].resolve({ items: [f.release()] }); await work;
  assert.equal(f.registry.apply(f.app()).latestAsset.versionCode, 3);
});
test('Discovery and Management calculate the same preview update entirely from observed memory', async () => {
  const f = fixture(), source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const names = ['catalogLookup', 'displayInstalledVersion', 'installedAssets', 'latestAssets', 'assetForBundle', 'catalogTarget', 'updateApps', 'catalogApp',
    'catalogForJob', 'allInstalledJobs', 'recentInstalledJobs', 'currentInstalledView', 'installedVersionOf', 'updateForApp',
    'checkInstalledUpdates', 'updateFor'];
  const methods = names.map(name => { const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4); });
  const box = { CatalogInstallTarget, CatalogPackageVariant, CatalogLookup, InstallJob, ReleaseUpdate, ReleaseChannelRegistry: f.registry, UpdateTarget: class {},
    UpdatePolicy:{disabled:()=>false},
    InstalledAppRegistry: { isAppGallery: () => false, hasApplicationOrigin: () => true, persist: async () => {}, signingIdentity: () => undefined, observedAt: () => 0, version: () => -1, versionName: () => '' }, InstallStage: { INSTALLED: 'INSTALLED' },
    LocalBundles: { isKnown: v => v >= 0, installedVersion() { throw Error('render invoked synchronous system query'); } } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { apps: [f.app()], updateCatalog: [f.app()], updateCatalogReady: true,updatePolicyReady:true,
    installedDisplay: new Map([['com.example.app', { version: 2, versionName: '2' }]]), installedVersions: new Map([[7, 2]]),
    storeInstalled: [], installedJobs: [{ id: 'done', appId: 7, bundleName: 'com.example.app', assetName: 'app.hap',
      stage: 'INSTALLED', versionCode: 2, versionName: '2' }], updates: [] });
  Object.defineProperty(ui, 'releaseChannelRevision', { get: () => f.revision });
  ui.checkInstalledUpdates(); assert.equal(ui.updates.length, 0);
  await f.registry.select({}, 7, true, [f.release()]); ui.checkInstalledUpdates();
  assert.equal(ui.updateForApp(7).versionCode, 3); assert.equal(ui.updateFor('com.example.app').versionCode, 3);
  await f.registry.select({}, 7, true, []); ui.checkInstalledUpdates();
  assert.equal(ui.updates.length, 0); assert.equal(ui.catalogForJob(ui.installedJobs[0]).id, 7);
});
test('header motion clamps overscroll and stops notifications once the search is pinned', () => {
  const source = fs.readFileSync(path.join(root, 'components/DiscoverHeader.ets'), 'utf8');
  const start = source.indexOf('export class DiscoverMotion'); const end = source.indexOf('\n@Component', start);
  const box = { exports: {} }; vm.runInNewContext(ts.transpileModule(source.slice(start, end).replace(/@Track /g, ''), {
    compilerOptions: { module: ts.ModuleKind.None, target: ts.ScriptTarget.ES2020 }
  }).outputText.replace('export ', '') + '\nglobalThis.Motion = DiscoverMotion;', box);
  const motion = new box.Motion(); motion.scroll(-100, 88); assert.equal(motion.scrollOffset, 0);
  motion.scroll(40, 88); assert.equal(motion.scrollOffset, 40);
  motion.scroll(1000, 88); assert.equal(motion.scrollOffset, 88);
  motion.pull(60); assert.equal(motion.pullOffset, 60); assert.equal(motion.scrollOffset, 0);
  motion.pull(0); motion.reachStart(-50);
  motion.scroll(38, 88); assert.equal(motion.scrollOffset, 88);
  motion.reachStart(0); motion.scroll(0, 88); assert.equal(motion.scrollOffset, 0);
});

test('returning to the list start reveals the title before refresh and the top action jumps without animation', () => {
  const component = fs.readFileSync(path.join(root, 'components/DiscoverHeader.ets'), 'utf8');
  const first = component.indexOf('export class DiscoverMotion'), last = component.indexOf('\n@Component', first);
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const methods = ['discoverScrollOffset', 'syncDiscoverScroll', 'revealDiscoverTop', 'backToDiscoverTop'].map(name => {
    const start = source.search(new RegExp(`^  private ${name}\\(`, 'm'));
    assert.ok(start >= 0); return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { ForegroundIdle: { interaction() {} }, exports: {}, Edge: { Top: 'top' } };
  vm.runInNewContext(ts.transpileModule(component.slice(first, last).replace(/@Track /g, '') +
    `\nclass Page { ${methods.join('\n')} }; globalThis.Page = Page; globalThis.Motion = DiscoverMotion;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  let offset = -50, jumped;
  const ui = new box.Page(); Object.assign(ui, { discoverMotion: new box.Motion(),
    discoverLayout:'normal', discoverTitleHeight: 88, discoverCanRefresh: true,
    discoverScroller: { currentOffset: () => ({ yOffset: offset }), scrollEdge(...args) { jumped = args; offset = -50; } } });
  ui.revealDiscoverTop(); offset = 1000; ui.syncDiscoverScroll();
  assert.equal(ui.discoverCanRefresh, false); assert.equal(ui.discoverMotion.showTop, true);
  offset = 0; ui.syncDiscoverScroll(); assert.equal(ui.discoverMotion.scrollOffset, 50);
  assert.equal(ui.discoverCanRefresh, false, 'partially collapsed title cannot start refreshing');
  offset = -50; ui.syncDiscoverScroll(); assert.equal(ui.discoverMotion.scrollOffset, 0);
  assert.equal(ui.discoverCanRefresh, true); assert.equal(ui.discoverMotion.showTop, false);
  offset = 1000; ui.syncDiscoverScroll(); ui.backToDiscoverTop();
  assert.deepEqual(jumped, ['top']); assert.equal(ui.discoverMotion.scrollOffset, 0);
  assert.equal(ui.discoverCanRefresh, true); assert.equal(ui.discoverMotion.showTop, false);
});

test('fresh catalog with a cached same-number replacement never projects the old digest back to any page', async () => {
  const f = fixture(), source = f.app(), old = f.release(2, false);
  source.updatedAt = '1791676211';
  Object.assign(source.latestAsset, { releaseTag: old.tag, releaseName: old.name, sha256: 'c'.repeat(64) });
  source.latestAssets = [source.latestAsset];
  assert.equal(f.registry.staleReleases(source, [old]), true);
  await f.registry.select({}, 7, false, [old], source);
  const stalePage = f.app(); stalePage.updatedAt = source.updatedAt;
  Object.assign(stalePage.latestAsset, { releaseTag: old.tag, releaseName: old.name, sha256: 'b'.repeat(64) });
  stalePage.latestAssets = [stalePage.latestAsset];
  for (const page of [source, stalePage]) {
    const selected = f.registry.apply(page);
    assert.equal(selected.latestAsset.sha256, 'c'.repeat(64));
    assert.equal(selected.latestAssets[0].sha256, 'c'.repeat(64));
    assert.equal(selected.latestAsset.versionCode, 2);
  }
});

test('conflicting catalog and release caches revalidate both directions, then accept one new replacement', async () => {
  const f = fixture(), old = f.app(), fresh = f.release(2, false);
  old.updatedAt = '1791676210';
  Object.assign(old.latestAsset, { releaseTag: fresh.tag, releaseName: fresh.name });
  old.latestAssets = [old.latestAsset];
  assert.equal(f.registry.staleReleases(old, [fresh]), true, 'a fresh release with an old catalog also needs a catalog re-read');
  const source = f.app(); source.updatedAt = '1791676211';
  Object.assign(source.latestAsset, { releaseTag: fresh.tag, releaseName: fresh.name, sha256: fresh.assets[0].sha256 });
  source.latestAssets = [source.latestAsset];
  assert.equal(f.registry.staleReleases(source, [fresh]), false);
  await f.registry.select({}, 7, false, [fresh], source);
  assert.equal(f.registry.apply(old).latestAsset.sha256, fresh.assets[0].sha256);
});

test('stable cache checks compare matching package variants and preserve absent or unverified metadata', () => {
  const f = fixture(), source = f.app(), release = f.release(2, false);
  source.updatedAt = '1791676211';
  Object.assign(source.latestAsset, { name: 'Petrelgram-1.5.3-unsigned.hap', versionName: '1.5.3',
    releaseTag: 'v1.5.3', releaseName: 'Petrelgram 1.5.3', sha256: 'a'.repeat(64) });
  Object.assign(release.assets[0], source.latestAsset);
  release.assets.unshift(Object.assign({}, source.latestAsset, { name: 'Petrelgram-1.5.3-unsigned.app.zip / Petrelgram-1.5.3-unsigned.app',
    sha256: 'b'.repeat(64) }));
  assert.equal(f.registry.staleReleases(source, [release]), false, 'different APP and HAP digests are normal');
  assert.equal(f.registry.staleReleases(source, [release], true), false, 'stable catalog is not preview cache evidence');
  assert.equal(f.registry.staleReleases(source, []), false, 'missing history metadata cannot invalidate catalog');
  const noPrimary = f.app(); noPrimary.latestAsset = undefined;
  assert.equal(f.registry.staleReleases(noPrimary, [release]), false);
  const unknown = f.app(); unknown.latestAsset.versionCode = 0;
  assert.equal(f.registry.staleReleases(unknown, [release]), false);
  release.assets[1].sha256 = '';
  assert.equal(f.registry.staleReleases(source, [release]), false, 'no digest is not evidence of a replacement');
});

test('stable cache checks recognize code and tag mismatches without rewriting internal build numbers', () => {
  const f = fixture(), source = f.app(), release = f.release(2, false);
  Object.assign(source.latestAsset, { releaseTag: release.tag, releaseName: release.name, sha256: release.assets[0].sha256 });
  assert.equal(f.registry.staleReleases(source, [release]), false);
  release.assets[0].versionCode = 3;
  assert.equal(f.registry.staleReleases(source, [release]), true);
  release.assets[0].versionCode = 2; release.assets[0].releaseTag = 'v2.1';
  assert.equal(f.registry.staleReleases(source, [release]), true);
  assert.equal(source.latestAsset.versionCode, 2); assert.equal(source.latestAsset.releaseTag, 'v2');
});

test('stable cache checks every current package variant but ignores a helper absent from the history page', () => {
  const f = fixture(), source = f.app(), release = f.release(2, false);
  Object.assign(source.latestAsset, { releaseTag: release.tag, releaseName: release.name,
    sha256: release.assets[0].sha256 });
  const app = Object.assign({}, source.latestAsset, { name: 'app.app', sha256: 'c'.repeat(64) });
  const helper = Object.assign({}, source.latestAsset, { name: 'helper.hap', bundleName: 'com.example.helper',
    versionCode: 9, versionName: '9', releaseTag: 'v9', sha256: 'd'.repeat(64) });
  source.latestAssets = [source.latestAsset, app, helper];
  release.assets.push(Object.assign({}, app, { sha256: 'a'.repeat(64) }));
  assert.equal(f.registry.staleReleases(source, [release]), true, 'APP-only replacement is detected while the primary HAP is unchanged');
  release.assets[1].sha256 = app.sha256;
  assert.equal(f.registry.staleReleases(source, [release]), false, 'an older helper outside the first twenty releases remains valid');
  const staleHelper = f.release(8, false);
  Object.assign(staleHelper.assets[0], helper, { versionCode: 8, versionName: '8', releaseTag: 'v8' });
  assert.equal(f.registry.staleReleases(source, [release, staleHelper]), true, 'a represented helper variant also participates in revalidation');
});
