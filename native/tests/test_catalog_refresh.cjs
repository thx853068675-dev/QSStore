// Run: node --test native/tests/test_catalog_refresh.cjs
// Exercise production page methods with deterministic network and image adapters.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
// Page methods have two-space indentation; the next member closes the slice.
function method(name) {
  // 方法可能是 private / public / static，也可能没有修饰符
  const start = source.search(new RegExp(
    `^  (?:private |public )?(?:static )?(?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, `production method ${name} exists`);
  const end = source.indexOf('\n  }', start);
  assert.notEqual(end, -1);
  return source.slice(start, end + 4);
}
const code = ts.transpileModule(`class Index {
  static CATALOG_PAGE_SIZE = 30;
  static REFRESH_MIN_VISIBLE_MS = 600;
  static STAR_FIELD_COUNT = 46;
  static STARRED_MIN_STARS = 100;
  ${['catalogHasMore', 'loadApps', 'pullRefreshCatalog', 'loadAppIcon', 'loadCatalogIcons', 'isCurrentCatalogIcon', 'iconFor',
    'refreshCatalogInstallState', 'reconcileCatalogInstallState', 'confirmCatalogVersionsViaDevice',
    'displayApps', 'featuredTier', 'featuredColors']
    .map(method).join('\n')}
}; globalThis.Page = Index;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
const page = (ids, total = ids.length) => ({ items: ids.map(id => {
  const row = typeof id === 'object' ? id : { id };
  return { iconRev: 'rev-1', iconUrl: '/api/v1/apps/' + row.id + '/icon', ...row };
}), total, rawItems: [] });
function fixture() {
  const requests = [], icons = [], saved = [], savedIcons = [], releases = [];
  // 声明必须在使用之前：f 的字面量会引用它（TDZ）
  const staleRefreshes = [];
  const removed = [];
  const calls = [];
  const f = { requests, icons, saved, savedIcons, releases, staleRefreshes,
    staleChanged: 0, icon: async () => undefined,
    decode: async () => ({ release: async () => releases.push('pixels') }) };
  const f2 = {};
  f2.localBundles = { installedVersion: () => f.localVersion,
    isKnown: (v) => v !== -1, UNKNOWN: -1 };
  f2.bridgeClass = class {
    async connected() { calls.push('connected'); return f.deviceConnected; }
    async isInstalled(bundleName) {
      if (f.deviceThrows) throw new Error('offline');
      calls.push('isInstalled:' + bundleName);
      return !f.deviceMissing.includes(bundleName);
    }
    /** 批量查询：一次拿到全部包名与版本号，避免「一个包一次往返」。 */
    async installedBundleVersions() {
      if (f.deviceThrows || !f.deviceConnected) throw new Error('offline');
      calls.push('installedBundleVersions');
      if (f.deviceUnparsable) return undefined;
      const out = new Map();
      for (const name of (f.knownBundles || [])) {
        if (!f.deviceMissing.includes(name)) out.set(name, (f.deviceVersions || {})[name] || 100);
      }
      return out.size > 0 ? out : undefined;
    }
  };
  f2.store = { forget: async (id) => removed.push(id) };
  f2.removed = removed;
  f2.calls = calls;
  f2.localVersion = 0;
  f2.deviceConnected = true;
  f2.deviceMissing = [];
  f2.deviceThrows = false;
  f2.deviceUnparsable = false;
  f2.deviceVersions = {};
  f2.knownBundles = [];
  const sandbox = { setTimeout, clearTimeout, console,
    StoreClient: class {
      listApps(number, size, sort, query) {
        const d = deferred(); requests.push({ ...d, number, query }); return d.promise;
      }
      appIconBytes(app) { icons.push(app.id); return f.icon(app); }
      /** 服务端批量重采：记录客户端点名了哪几个应用。 */
      refreshStaleApps(appIds = []) { staleRefreshes.push({ appIds }); return f.staleChanged; }
    },
    getContext: () => ({}), errorText: e => (e && e.message) || String(e),
    AppIcon: class {}, CachedIcon: class {},
    CatalogCache: { iconWithinLimit: () => true,
      save: (_, rows) => saved.push(rows.map(r => r.id)),
      saveIcons: (_, rows) => savedIcons.push(rows) },
    image: { createImageSource: () => ({ createPixelMap: () => f.decode(),
      release: async () => releases.push('source') }) },
    util: { Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } } },
    InstalledAppRegistry: { markCatalogSnapshot: async () => {} },
    LocalBundles: f.localBundles,
    HdcDeviceBridge: f.bridgeClass,
    JobStore: { open: async () => f.store }
  };
  vm.runInNewContext(code, sandbox);
  sandbox.Page.REFRESH_MIN_VISIBLE_MS = 20;
  const ui = new sandbox.Page();
  Object.assign(ui, { catalogToken: 0, activeQuery: '', apps: [], appIcons: [], catalogIconFlights: new Map(),
    catalogLoading: false, catalogPage: 0, catalogTotal: 0, catalogMoreBusy: false,
    catalogRefreshing: false, catalogRefreshBusy: false, catalogError: '',
    installedVersions: new Map(), installedJobs: [], catalogProbeBusy: false, catalogProbeNames: [], catalogProbePending: [], updateCatalogReady: false, updateInstallScanPrompt() {}, refreshCatalogInstallState() {},
    updateApps() { return this.apps; }, syncDetectedInstalled() {}, reconcileDetectedJobs: async () => {}, forgetInstalledVersions() {}, loadUpdateCatalog() {}, checkInstalledUpdates() {},
    refreshCatalogInstallState() {} });
  Object.assign(f, f2);
  // sandbox 是在合并之前建的，这里把设备/存储适配器补进去
  sandbox.LocalBundles = f.localBundles;
  sandbox.HdcDeviceBridge = f.bridgeClass;
  sandbox.JobStore = { open: async () => f.store };
  f.ui = ui;
  f.PageClass = sandbox.Page;
  return f;
}
test('Refresh binding true before callback still starts a request; duplicate callbacks are coalesced', async () => {
  const f = fixture(), ui = f.ui;
  ui.catalogRefreshing = true;
  const work = ui.pullRefreshCatalog();
  await ui.pullRefreshCatalog();
  assert.equal(f.requests.length, 1);
  f.requests[0].resolve(page([1])); await work;
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.catalogRefreshBusy, false);
  const next = ui.pullRefreshCatalog();
  assert.equal(f.requests.length, 2);
  f.requests[1].resolve(page([2])); await next;
  assert.equal(ui.apps[0].id, 2);
});
test('failed refresh releases spinner and preserves loaded pagination for retry', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1 }]; ui.catalogPage = 2; ui.catalogTotal = 90;
  const work = ui.pullRefreshCatalog(); f.requests[0].reject(Error('offline')); await work;
  assert.equal(ui.catalogRefreshing, false); assert.equal(ui.catalogMoreBusy, false);
  assert.equal(ui.catalogPage, 2); assert.equal(ui.catalogTotal, 90); assert.equal(ui.apps[0].id, 1);
  const retry = ui.pullRefreshCatalog(); assert.equal(f.requests[1].number, 1);
  f.requests[1].resolve(page([])); await retry;
  assert.equal(ui.apps.length, 0); assert.equal(ui.catalogError, '');
});
test('older network rejection cannot replace a successful search with an error', async () => {
  const f = fixture(), ui = f.ui;
  const old = ui.loadApps(); ui.activeQuery = 'new'; const latest = ui.loadApps();
  f.requests[1].resolve(page([2])); await latest;
  f.requests[0].reject(Error('old timeout')); await old;
  assert.equal(ui.catalogError, ''); assert.equal(ui.apps[0].id, 2); assert.equal(ui.catalogTotal, 1);
});
test('late icon download cannot overwrite search metadata, icons or first-page cache', async () => {
  const f = fixture(), ui = f.ui, icon = deferred();
  f.icon = app => app.id === 1 ? icon.promise : Promise.resolve(undefined);
  const old = ui.loadApps(); f.requests[0].resolve(page([1], 99)); await tick();
  ui.activeQuery = 'new'; const latest = ui.loadApps();
  f.requests[1].resolve(page([2])); await latest;
  icon.resolve(new ArrayBuffer(4)); await old; await tick();
  assert.equal(ui.catalogTotal, 1); assert.equal(ui.apps[0].id, 2);
  assert.equal(ui.appIcons.length, 0); assert.deepEqual(f.saved, [[1]]); assert.equal(f.savedIcons.length, 0);
});
test('stale decoded pixels are released instead of appended to newer results', async () => {
  const f = fixture(), ui = f.ui, decode = deferred();
  f.icon = async app => app.id === 1 ? new ArrayBuffer(4) : undefined;
  f.decode = () => decode.promise;
  const old = ui.loadApps(); f.requests[0].resolve(page([1])); await tick();
  ui.activeQuery = 'new'; const latest = ui.loadApps(); f.requests[1].resolve(page([2])); await latest;
  decode.resolve({ release: async () => f.releases.push('pixels') }); await old; await tick();
  assert.equal(ui.appIcons.length, 0); assert.deepEqual(f.releases, ['pixels', 'source']);
});
test('refresh retries missing icons of existing apps but retains available icons', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = page([1, 2]).items; ui.appIcons = [{ id: 2, rev: 'rev-1', pixels: {} }];
  f.icon = async () => new ArrayBuffer(4);
  const work = ui.loadApps(); f.requests[0].resolve(page([1, 2])); await work; await tick();
  assert.deepEqual(f.icons, [1]); assert.equal(ui.appIcons.length, 2);
  assert.equal(f.savedIcons[0][0].id, '1');
});
test('failed icon fetch does not fail refresh and can be retried', async () => {
  const f = fixture(), ui = f.ui;
  f.icon = async () => { throw Error('icon unavailable'); };
  const first = ui.pullRefreshCatalog(); f.requests[0].resolve(page([1])); await first;
  assert.equal(ui.catalogError, ''); assert.equal(ui.catalogRefreshing, false);
  f.icon = async () => new ArrayBuffer(4);
  const retry = ui.pullRefreshCatalog(); f.requests[1].resolve(page([1])); await retry;
  assert.deepEqual(f.icons, [1, 1, 1]); assert.equal(ui.appIcons.length, 1);
});
test('a new icon revision replaces the discovery icon and fetches new bytes', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = page([1]).items;
  ui.appIcons = [{ id: 1, rev: 'rev-1', pixels: {} }];
  f.icon = async () => new ArrayBuffer(4);
  const work = ui.loadApps();
  f.requests[0].resolve(page([{ id: 1, iconRev: 'rev-2' }]));
  await work; await tick();
  assert.deepEqual(f.icons, [1]);
  assert.equal(ui.appIcons.length, 1);
  assert.equal(ui.appIcons[0].rev, 'rev-2');
});
test('a transient icon miss gets one retry in the same refresh', async () => {
  const f = fixture(), ui = f.ui;
  f.icon = async () => f.icons.length === 1 ? undefined : new ArrayBuffer(4);
  const work = ui.loadApps(); f.requests[0].resolve(page([1])); await work; await tick();
  assert.deepEqual(f.icons, [1, 1]);
  assert.equal(ui.appIcons.length, 1);
});
test('reset invalidates an in-flight next page and retains only new results', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1 }]; ui.catalogPage = 1; ui.catalogTotal = 3;
  const more = ui.loadApps(false); assert.equal(f.requests[0].number, 2);
  const refresh = ui.pullRefreshCatalog(); f.requests[1].resolve(page([4])); await refresh;
  f.requests[0].resolve(page([1, 2], 3)); await more;
  assert.equal(ui.apps.length, 1); assert.equal(ui.apps[0].id, 4);
  assert.equal(ui.catalogPage, 1); assert.equal(ui.catalogTotal, 1);
});

test('refresh spinner stays visible for a minimum time even when the request is instant', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'a.b' } }];
  ui.localVersion = 0;
  ui.deviceConnected = false;   // 对账跳过，只测停留时间
  const work = ui.pullRefreshCatalog();
  assert.equal(ui.catalogRefreshing, true);
  f.requests[0].resolve(page([1]));
  // 数据已经回来了，但转圈要留够时间，否则动画还没画出来就被收回
  await tick();
  assert.equal(ui.catalogRefreshing, true);
  await work;
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.catalogRefreshBusy, false);
});

test('reconcile drops install records the device no longer has', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'gone.b' } },
    { id: 2, latestAsset: { bundleName: 'here.b' } }];
  ui.installedJobs = [{ id: 'j1', bundleName: 'gone.b' }, { id: 'j2', bundleName: 'here.b' }];
  f.knownBundles = ['gone.b', 'here.b'];
  f.deviceMissing = ['gone.b'];
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));

  // 设备明确报「不存在」的记录要删掉，仍在的保留
  assert.deepEqual(f.removed, ['j1']);
  assert.deepEqual(ui.installedJobs.map(j => j.id), ['j2']);
});

test('reconcile keeps records when the device cannot be reached', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'gone.b' } }];
  ui.installedJobs = [{ id: 'j1', bundleName: 'gone.b' }];
  f.knownBundles = ['gone.b'];
  f.deviceThrows = true;
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  // 连不上设备时按「不确定」处理：断线一次就清空历史是不可接受的
  assert.deepEqual(f.removed, []);
  assert.deepEqual(ui.installedJobs.map(j => j.id), ['j1']);
});

test('reconcile does not touch records while the device is disconnected', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'gone.b' } }];
  ui.installedJobs = [{ id: 'j1', bundleName: 'gone.b' }];
  f.knownBundles = ['gone.b'];
  f.deviceConnected = false;
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  assert.deepEqual(f.removed, []);
  assert.deepEqual(ui.installedJobs.map(j => j.id), ['j1']);
});

test('reconcile asks the device once, not once per app', async () => {
  const f = fixture(), ui = f.ui;
  // 30 个应用：逐个查询会是 30 次设备往返，刷新慢到无法接受
  ui.apps = [];
  for (let i = 0; i < 30; i++) ui.apps.push({ id: i + 1, latestAsset: { bundleName: 'app' + i + '.b' } });
  f.knownBundles = ui.apps.map(a => a.latestAsset.bundleName);
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  const perBundle = f.calls.filter(c => String(c).startsWith('isInstalled:'));
  assert.deepEqual(perBundle, [], '不应逐个查询');
  assert.deepEqual(f.calls, ['installedBundleVersions'], '只应有一次批量查询');
});

test('unparsable device list keeps every record', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'gone.b' } }];
  ui.installedJobs = [{ id: 'j1', bundleName: 'gone.b' }];
  f.deviceUnparsable = true;   // bm dump -a 输出解析不出包名 → 无法核实
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  assert.deepEqual(f.removed, []);
  assert.deepEqual(ui.installedJobs.map(j => j.id), ['j1']);
});

test('reconcile records the version actually on the device', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 7, latestAsset: { bundleName: 'app.b' } }];
  ui.installedJobs = [{ id: 'j7', bundleName: 'app.b', versionCode: 1 }];
  f.knownBundles = ['app.b'];
  f.deviceVersions = { 'app.b': 2026092908 };
  let updatesChecked = 0;
  ui.checkInstalledUpdates = () => { updatesChecked++; };
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  // 记录里是旧版本 1，设备上是 2026092908 —— 必须以设备为准，
  // 否则卡片会一直显示「更新」
  assert.equal(ui.installedVersions.get(7), 2026092908);
  assert.equal(updatesChecked, 1, '版本变化后要重算「是否有更新」');
});

test('reconcile leaves version state alone when the device is unparsable', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 7, latestAsset: { bundleName: 'app.b' } }];
  f.deviceUnparsable = true;
  ui.checkInstalledUpdates = () => { throw new Error('不应触发'); };
  await ui.confirmCatalogVersionsViaDevice(ui.apps.map(a => a.latestAsset.bundleName));
  assert.equal(ui.installedVersions.size, 0);
});

test('pull refresh only reads the catalog even when installed apps are behind', async () => {
  const f = fixture(), ui = f.ui;
  // 目录里两个应用都是 versionCode 200
  const rows = [
    { id: 1, latestAsset: { bundleName: 'old.b', versionCode: 200 } },
    { id: 2, latestAsset: { bundleName: 'new.b', versionCode: 200 } },
  ];
  // 设备上：1 是 100（落后），2 是 200（已最新）。对账会照设备真值写入。
  f.knownBundles = ['old.b', 'new.b'];
  f.deviceVersions = { 'old.b': 100, 'new.b': 200 };
  ui.catalogPage = 1; ui.catalogTotal = 2;
  const pull = ui.pullRefreshCatalog();
  await tick();
  assert.ok(f.requests.length >= 1, '下拉要拉一次列表');
  f.requests[0].resolve(page(rows, 2));
  await pull;
  assert.equal(f.staleRefreshes.length, 0);
  assert.equal(f.requests.length, 1);
});

// ── 发现页大卡：置顶与星点背景 ────────────────────────────────────

test('displayApps puts oversized cards first, best first', () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [10, 300, 50, 120, 400].map((stars, i) => ({ id: i + 1, stars }));
  // 大卡按星数降序置顶；其余保持目录原顺序
  assert.deepEqual(Array.from(ui.displayApps(), a => a.stars), [400, 300, 120, 10, 50]);
});

test('displayApps does not mutate the catalog array', () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, stars: 10 }, { id: 2, stars: 300 }];
  const before = Array.from(ui.apps, a => a.id);
  ui.displayApps();
  // this.apps 还带着分页状态，就地排序会打乱它
  assert.deepEqual(Array.from(ui.apps, a => a.id), before);
});

test('displayApps keeps the catalog order when nothing qualifies', () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 3, stars: 5 }, { id: 1, stars: 90 }, { id: 2, stars: 0 }];
  assert.deepEqual(Array.from(ui.displayApps(), a => a.id), [3, 1, 2]);
});

test('featured card thresholds cover hundreds, thousands, and ten thousands', () => {
  const { ui } = fixture();
  assert.deepEqual([100, 101, 999, 1000, 9999, 10000].map(n => ui.featuredTier(n)),
    [0, 1, 1, 2, 2, 3]);
  assert.notEqual(ui.featuredColors(101)[0][0], ui.featuredColors(1000)[0][0]);
  assert.notEqual(ui.featuredColors(1000)[0][0], ui.featuredColors(10000)[0][0]);
});

test('pull refresh ends while an icon and a device inventory are still pending', async () => {
  const f = fixture(), ui = f.ui, icon = deferred(), device = deferred();
  f.icon = () => icon.promise;
  f.bridgeClass.prototype.installedBundleVersions = () => device.promise;
  delete ui.refreshCatalogInstallState; // execute the production dispatcher
  ui.updateInstallScanPrompt = () => {};
  const run = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([{ id: 1, latestAsset: { bundleName: 'app.one' } }]));
  await run;
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.catalogPage, 1);
  assert.equal(ui.catalogTotal, 1);
  assert.equal(ui.catalogProbeBusy, true);
  assert.equal(ui.appIcons.length, 0);
  icon.resolve(new ArrayBuffer(4)); device.resolve(new Map([['app.one', 123]]));
  await tick();
  assert.equal(ui.appIcons.length, 1);
  assert.equal(ui.installedVersions.get(1), 123);
  assert.equal(f.savedIcons[0][0].id, '1');
});

test('repeated refresh and pagination reuse an unfinished icon without losing the first page', async () => {
  const f = fixture(), ui = f.ui, icon = deferred();
  f.icon = app => app.id === 1 ? icon.promise : Promise.resolve(new ArrayBuffer(4));
  let run = ui.loadApps(); f.requests[0].resolve(page([1], 2)); await run;
  run = ui.loadApps(); f.requests[1].resolve(page([1], 2)); await run;
  assert.deepEqual(f.icons, [1]);
  run = ui.loadApps(false); f.requests[2].resolve(page([2], 2)); await run;
  icon.resolve(new ArrayBuffer(4)); await tick();
  assert.deepEqual(ui.appIcons.map(i => i.id).sort(), [1, 2]);
  assert.equal(f.icons.filter(id => id === 1).length, 1);
});

test('old icon revisions cannot replace a new icon after a background download finishes', async () => {
  const f = fixture(), ui = f.ui, old = deferred();
  f.icon = app => app.iconRev === 'rev-1' ? old.promise : Promise.resolve(new ArrayBuffer(4));
  let run = ui.loadApps(); f.requests[0].resolve(page([1])); await run;
  run = ui.loadApps(); f.requests[1].resolve(page([{ id: 1, iconRev: 'rev-2' }])); await run;
  await tick(); old.resolve(new ArrayBuffer(4)); await tick();
  assert.equal(ui.appIcons.length, 1); assert.equal(ui.appIcons[0].rev, 'rev-2');
  assert.ok(f.savedIcons.flat().every(icon => icon.rev === 'rev-2'));
});
