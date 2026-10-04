const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture() {
  const f = { ownCalls: 0, queries: [], ownFails: false, code: 7, name: '1.2.0', error: undefined };
  const bundleManager = { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    async getBundleInfoForSelf() { f.ownCalls++; if (f.ownFails) throw Error('not ready');
      return { name: 'com.example.installer', versionCode: 52, versionName: '0.4.52-pre' }; },
    async getBundleInfo(name) { f.queries.push(name); if (f.error) throw f.error;
      return { versionCode: f.code, versionName: f.name }; },
    getBundleInfoForSelfSync() { throw Error('UI thread must not issue synchronous lookup'); },
    getBundleInfoSync() { throw Error('UI thread must not issue synchronous lookup'); } };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/LocalBundles.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => name === '@kit.AbilityKit' ? { bundleManager } : {} });
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
