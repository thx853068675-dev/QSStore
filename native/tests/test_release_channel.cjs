const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
function fixture() {
  const start = source.indexOf('  private async selectReleaseChannel(');
  assert.ok(start >= 0);
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const f = { requests: [], reconciled: [], probes: 0 };
  const sandbox = { getContext: () => ({}), errorText: error => error.message,
    StoreClient: class {
      listReleases(...args) {
        const work = {};
        work.promise = new Promise((resolve, reject) => Object.assign(work, { resolve, reject }));
        f.requests.push({ args, ...work });
        return work.promise;
      }
    } };
  vm.runInNewContext(ts.transpileModule(`class Detail { static RELEASES_PER_PAGE = 20;
    ${method} }; globalThis.Page = Detail;`, { compilerOptions: {
    target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);
  f.ui = new sandbox.Page();
  Object.assign(f.ui, { app: { id: 1 }, showPreviewReleases: false, releaseMoreBusy: false,
    refreshBusy: false, releases: ['stable'], releasePage: 1, releaseTotal: 1,
    selectedAsset: { url: 'https://example.com/stable.hap', name: 'stable.hap' },
    animateOverlay: action => action(),
    reconcileSelectedAsset: (...args) => f.reconciled.push(args),
    refreshInstalledVersion: () => f.probes++ });
  return f;
}
test('selecting the active release channel performs no network request', async () => {
  const f = fixture(); await f.ui.selectReleaseChannel(false);
  assert.equal(f.requests.length, 0);
});
test('channel change coalesces taps and preserves the selected package during a successful refresh', async () => {
  const f = fixture(); const work = f.ui.selectReleaseChannel(true);
  await f.ui.selectReleaseChannel(false);
  assert.equal(f.requests.length, 1);
  assert.deepEqual(f.requests[0].args, [1, 1, 20, true]);
  f.requests[0].resolve({ items: ['preview', 'stable'], page: 1, total: 2 }); await work;
  assert.equal(f.ui.showPreviewReleases, true); assert.equal(f.ui.releaseMoreBusy, false);
  assert.deepEqual(f.reconciled, [['https://example.com/stable.hap', 'stable.hap']]);
  assert.equal(f.probes, 1);
});
test('a failed channel request restores the previous selection and release data', async () => {
  const f = fixture(); const work = f.ui.selectReleaseChannel(true);
  f.requests[0].reject(Error('offline')); await work;
  assert.equal(f.ui.showPreviewReleases, false); assert.equal(f.ui.releaseMoreBusy, false);
  assert.deepEqual(f.ui.releases, ['stable']); assert.equal(f.reconciled.length, 0);
  assert.match(f.ui.releaseMessage, /offline/);
});
test('checking updates prevents a conflicting release-channel request', async () => {
  const f = fixture(); f.ui.refreshBusy = true;
  await f.ui.selectReleaseChannel(true);
  assert.equal(f.requests.length, 0); assert.equal(f.ui.showPreviewReleases, false);
});
