const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const f = { app: deferred(), icon: deferred(), versions: deferred(), reviews: deferred(), calls: [], saved: [], released: 0 };
  const box = { Promise, getContext: () => ({}), router: { getParams: () => ({ id: 42 }) }, errorText: e => e.message,
    ReleaseChannelRegistry: { restore: async () => {}, preview: () => true, select: async (...args) => f.saved.push(args) },
    StoreClient: class {
      appDetail() { f.calls.push('app'); return f.app.promise; }
      appIcon() { f.calls.push('icon'); return f.icon.promise; }
      listReleases() { f.calls.push('versions'); return f.versions.promise; }
      listReviews() { f.calls.push('reviews'); return f.reviews.promise; }
    } };
  const methods = ['loadApp', 'loadDetailIcon', 'loadInitialReleases', 'fetchReviewPage', 'loadReviews', 'refreshPage'].map(name => {
    const at = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.ok(at >= 0, name); return source.slice(at, source.indexOf('\n  }', at) + 4);
  }).join('\n');
  vm.runInNewContext(ts.transpileModule(`class Detail { static RELEASES_PER_PAGE = 20; static REVIEWS_PER_PAGE = 20;
    ${methods} }; globalThis.Page = Detail;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  f.ui = Object.assign(new box.Page(), { disposed: false, loaded: false, detailLoading: false, error: '', releaseLoading: true,
    releaseMessage: '', app: {}, appIcon: null, releases: [], reviewPage: 0, reviewPageBusy: false, reviews: [],
    reconcileSelectedAsset() { this.selectedAsset = this.releases[0]?.assets[0]; }, refreshHeroColor() {},
    refreshInstalledVersion() {}, syncInstallTask() {}, checkForUpdates() { f.calls.push('collection'); } });
  f.finish = () => { f.icon.resolve(null); f.versions.resolve({ items: [{ assets: ['hap'] }], page: 1, total: 1 });
    f.reviews.resolve({ items: [], page: 1, total: 0 }); };
  return f;
}
test('core content is visible while icon, releases and reviews load independently', async () => {
  const f = fixture(), work = f.ui.loadApp();
  f.app.resolve({ id: 42, displayName: 'Test' }); await tick();
  assert.equal(f.ui.loaded, true); assert.equal(f.ui.app.displayName, 'Test');
  assert.deepEqual(f.calls, ['app', 'icon', 'versions', 'reviews']);
  f.versions.resolve({ items: [{ assets: ['hap'] }], page: 1, total: 1 }); await tick();
  assert.equal(f.ui.releaseLoading, false); assert.equal(f.ui.selectedAsset, 'hap');
  assert.equal(f.ui.reviewPageBusy, true, 'slow reviews must not delay installation');
  f.finish(); await work; assert.equal(f.ui.error, '');
});
test('secondary failures never replace loaded application content with a full-page error', async () => {
  const f = fixture(), work = f.ui.loadApp(); f.app.resolve({ id: 42 }); await tick();
  f.icon.reject(Error('icon timeout')); f.versions.reject(Error('version timeout')); f.reviews.reject(Error('review timeout'));
  await work;
  assert.equal(f.ui.loaded, true); assert.equal(f.ui.error, ''); assert.equal(f.ui.releaseLoading, false);
  assert.match(f.ui.releaseMessage, /version timeout/); assert.match(f.ui.reviewMessage, /review timeout/);
  f.versions = deferred(); f.ui.refreshPage();
  f.versions.resolve({ items: [], page: 1, total: 0 }); await tick();
  assert.equal(f.calls.includes('collection'), false, 'retrying a failed read must not collect the repository');
  assert.equal(f.ui.releaseMessage, '');
});
test('returning during loading discards responses and releases the unshown icon', async () => {
  const f = fixture(), work = f.ui.loadApp(); f.app.resolve({ id: 42 }); await tick(); f.ui.disposed = true;
  f.icon.resolve({ release: async () => { f.released++; } }); f.finish(); await work;
  assert.equal(f.ui.appIcon, null); assert.equal(f.ui.releases.length, 0); assert.equal(f.ui.reviews.length, 0);
  assert.equal(f.saved.length, 0); assert.equal(f.released, 1);
});
test('a disposed page stops after its first request and duplicate retry taps share the load', async () => {
  const f = fixture(), work = f.ui.loadApp(); await f.ui.loadApp();
  assert.deepEqual(f.calls, ['app']); f.ui.disposed = true; f.app.resolve({ id: 42 }); await work;
  assert.deepEqual(f.calls, ['app']); assert.equal(f.ui.loaded, false);
});
test('the initial application request can be retried after failure', async () => {
  const f = fixture(), work = f.ui.loadApp(); f.app.reject(Error('network timeout')); await work;
  assert.equal(f.ui.detailLoading, false); assert.match(f.ui.error, /network timeout/);
  f.app = deferred(); const retry = f.ui.loadApp(); f.app.resolve({ id: 42 }); f.finish(); await retry;
  assert.equal(f.ui.loaded, true); assert.equal(f.ui.error, '');
});
