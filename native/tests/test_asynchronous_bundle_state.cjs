const { publicConsentModule } = require('./load_ets.cjs');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { loadEts } = require('./load_ets.cjs');
function fixture() {
  const f = { ownCalls: 0, queries: [], ownFails: false, ownCode: 52, ownName: '0.4.52-pre',
    ownQuery: undefined, code: 7, name: '1.2.0', error: undefined };
  const bundleManager = { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0, GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
    getBundleInfoForSelf(flag) { assert.equal(flag, 1); f.ownCalls++; if (f.ownQuery) return f.ownQuery();
      if (f.ownFails) return Promise.reject(Error('not ready'));
      return Promise.resolve({ name: 'com.example.installer', versionCode: f.ownCode, versionName: f.ownName }); },
    async getBundleInfo(name, flag) { assert.equal(flag, 1); f.queries.push(name); if (f.error) throw f.error;
      if (f.query) return f.query(name);
      return { name: f.returnedBundle ?? name, versionCode: f.code, versionName: f.name,
        appInfo: f.appInfo, updateTime: f.updateTime }; },
    getBundleInfoForSelfSync() { throw Error('UI thread must not issue synchronous lookup'); },
    getBundleInfoSync() { throw Error('UI thread must not issue synchronous lookup'); } };
  const exports = {}, disk = new Map();
  f.registry = loadEts('jobs/InstalledAppRegistry', { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } }).InstalledAppRegistry;
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/LocalBundles.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => name === '@kit.AbilityKit' ? { bundleManager } :
    name === './InstalledAppRegistry' ? { InstalledAppRegistry: f.registry } : publicConsentModule(name) });
  f.Bundles = exports.LocalBundles; return f;
}
test('display scanning shares the own-bundle lookup and obtains each version code/name in one asynchronous query', async () => {
  const f = fixture();
  const [one, two, own] = await Promise.all(['com.example.one', 'com.example.two', 'com.example.installer']
    .map(name => f.Bundles.liveInstalledState(name)));
  assert.equal(f.ownCalls, 1); assert.deepEqual(f.queries, ['com.example.one', 'com.example.two']);
  assert.equal(one.versionCode, 7); assert.equal(two.versionName, '1.2.0');
  assert.equal(own.versionCode, 52); assert.equal(own.versionName, '0.4.52-pre');
});
test('permissions and malformed versions remain unknown; only verified absence is zero', async () => {
  const f = fixture();
  f.error = { code: 201 }; assert.equal((await f.Bundles.liveInstalledState('com.example.one')).versionCode, -1);
  f.error = { code: 17700001 }; assert.equal((await f.Bundles.liveInstalledState('com.example.one')).versionCode, 0);
  f.error = undefined; f.code = NaN; assert.equal((await f.Bundles.liveInstalledState('com.example.one')).versionCode, -1);
  assert.equal((await f.Bundles.liveInstalledState('../wrong')).versionCode, 0);
});
test('a temporarily unavailable self lookup is evicted and retried', async () => {
  const f = fixture(); f.ownFails = true;
  await f.Bundles.liveInstalledState('com.example.one');
  f.ownFails = false; const own = await f.Bundles.liveInstalledState('com.example.installer');
  assert.equal(f.ownCalls, 2); assert.equal(own.versionCode, 52);
});
test('a successful self lookup is shared only while pending, so the next scan sees a self update', async () => {
  const f = fixture();
  const before = await f.Bundles.liveInstalledState('com.example.installer');
  assert.equal(before.versionCode, 52);
  f.ownCode = 56; f.ownName = '0.4.56-pre';
  const [own, other] = await Promise.all(['com.example.installer', 'com.example.app']
    .map(name => f.Bundles.liveInstalledState(name)));
  assert.equal(f.ownCalls, 2, 'each scan coalesces its concurrent callers, not future scans');
  assert.equal(own.versionCode, 56); assert.equal(own.versionName, '0.4.56-pre');
  assert.equal(other.versionCode, 7);
});
test('an older failed self lookup cannot clear the new pending recovery query', async () => {
  const f = fixture(); let rejectOld, resolveNew;
  const oldReply = new Promise((_resolve, reject) => { rejectOld = reject; });
  const newReply = new Promise(resolve => { resolveNew = resolve; });
  const replies = [oldReply, newReply];
  f.ownQuery = () => replies.shift() ?? Promise.resolve({ name: 'com.example.installer', versionCode: 99 });
  const failedScan = f.Bundles.liveInstalledState('com.example.installer');
  let recovery;
  // The new caller starts after the old request's finally, before its awaiting
  // caller reaches the fallback. Cleanup of the old caller must not steal it.
  const launched = oldReply.catch(() => { recovery = f.Bundles.liveInstalledState('com.example.installer'); });
  rejectOld(Error('not ready'));
  await launched; await failedScan;
  const sameRecovery = f.Bundles.liveInstalledState('com.example.installer');
  assert.equal(f.ownCalls, 2);
  resolveNew({ name: 'com.example.installer', versionCode: 56, versionName: '0.4.56-pre' });
  const [one, two] = await Promise.all([recovery, sameRecovery]);
  assert.equal(one.versionCode, 56); assert.equal(two.versionCode, 56);
  assert.equal(f.ownCalls, 2);
});

test('the existing asynchronous version query also records AppGallery origin, without an additional IPC', async () => {
  const f = fixture(), bundle = 'com.nrc.huawei';
  f.code = 111112; f.name = '1.111.0.112'; f.updateTime = Date.now() - 5000;
  f.appInfo = { appDistributionType: 'app_gallery', appProvisionType: 'release',
    installSource: 'com.huawei.hmsapp.appgallery' };
  const state = await f.Bundles.liveInstalledState(bundle);
  assert.equal(state.versionCode, 111112); assert.equal(f.registry.isAppGallery(bundle), true);
  assert.equal(f.registry.hasApplicationOrigin(bundle), true);
  assert.deepEqual(f.queries, [bundle]); assert.equal(f.ownCalls, 1);
  f.error = { code: 201 };
  assert.equal((await f.Bundles.liveInstalledState(bundle)).versionCode, -1);
  assert.equal(f.registry.isAppGallery(bundle), true, 'permission denial cannot clear reliable prior source');
  f.error = undefined; f.appInfo = { appDistributionType: 'none', appProvisionType: 'debug', installSource: 'shell' };
  f.updateTime += 1000;
  await f.Bundles.liveInstalledState(bundle);
  assert.equal(f.registry.isAppGallery(bundle), false, 'same code installed from a new source must replace old evidence');
  assert.equal(f.registry.hasApplicationOrigin(bundle), true, 'a known debug origin avoids needless follow-up IPC');
});

test('a mismatched system reply stays unknown, and only verified absence clears the installed source', async () => {
  const f = fixture(), bundle = 'com.nrc.huawei';
  f.appInfo = { appDistributionType: 'app_gallery' };
  await f.Bundles.liveInstalledState(bundle);
  f.returnedBundle = 'com.example.other';
  assert.equal((await f.Bundles.liveInstalledState(bundle)).versionCode, -1);
  assert.equal(f.registry.isAppGallery(bundle), true);
  f.error = { code: 17700001 };
  assert.equal((await f.Bundles.liveInstalledState(bundle)).versionCode, 0);
  assert.equal(f.registry.isAppGallery(bundle), false);
  assert.equal(f.registry.hasApplicationOrigin(bundle), false);
});

test('late system replies return the newer observed version and never restore stale source, including missing timestamps', async () => {
  for (const sameCode of [true, false]) {
    for (const withTime of [true, false]) {
      const f = fixture(), bundle = 'com.nrc.huawei', at = Date.now() - 10000;
      let reply, started;
      const entered = new Promise(resolve => started = resolve);
      f.query = () => { started(); return new Promise(resolve => reply = resolve); };
      const pending = f.Bundles.liveInstalledState(bundle); await entered;
      f.registry.rememberApplicationInfo(bundle, sameCode ? 111112 : 111113, 'new-device-build',
        'none', 'debug', 'shell', at + 1000);
      reply({ name: bundle, versionCode: 111112, versionName: 'old-official-build',
        updateTime: withTime ? at : undefined,
        appInfo: { appDistributionType: 'app_gallery', appProvisionType: 'release', installSource: 'com.huawei.hmsapp.appgallery' } });
      const state = await pending;
      assert.equal(state.versionCode, sameCode ? 111112 : 111113); assert.equal(state.versionName, 'new-device-build');
      assert.equal(f.registry.isAppGallery(bundle), false);
      assert.equal(f.registry.installationTime(bundle, state.versionCode), at + 1000);
    }
  }
});

test('a late absence result cannot delete an install confirmed while the system request was in flight', async () => {
  const f = fixture(), bundle = 'com.nrc.huawei'; let rejectReply, started;
  const entered = new Promise(resolve => started = resolve);
  f.query = () => { started(); return new Promise((_resolve, reject) => rejectReply = reject); };
  const pending = f.Bundles.liveInstalledState(bundle); await entered;
  f.registry.rememberApplicationInfo(bundle, 111113, 'new-device-build', 'none', 'debug', 'shell', Date.now() - 1000);
  rejectReply({ code: 17700001 });
  const state = await pending;
  assert.equal(state.versionCode, 111113); assert.equal(state.versionName, 'new-device-build');
  assert.equal(f.registry.version(bundle), 111113);
});
