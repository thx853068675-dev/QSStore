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
const paging = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/CatalogPaging.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: paging });
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
  static REFRESH_MIN_VISIBLE_MS = 600; static VERSION_TTL_MS = 60000;
  static STAR_FIELD_COUNT = 46;
  static STARRED_MIN_STARS = 100;
  ${['catalogHasMore', 'loadMoreApps', 'prefetchCatalog', 'loadApps', 'pullRefreshCatalog', 'loadAppIcon', 'loadCatalogIcons', 'isCurrentCatalogIcon', 'iconFor',
    'latestAssets', 'installedAssets', 'assetForBundle', 'refreshCatalogInstallState', 'runCatalogStateRefreshes', 'readCatalogInstallState', 'cancelResumeMaintenance', 'reconcileCatalogInstallState', 'confirmCatalogVersionsViaDevice', 'runCatalogVersionProbes', 'waitForRefreshConnection', 'completeRefreshConnection', 'openReconnectSettings', 'onPageHide', 'animateOverlay', 'reconnect', 'applyDetectedCatalogVersion', 'commitCatalogVersions',
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
  return { stars: 0, iconRev: 'rev-1', iconUrl: '/api/v1/apps/' + row.id + '/icon', ...row };
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
    liveInstalledVersion: () => f.localVersion, installedVersionName: () => '',
    isKnown: (v) => v !== -1, UNKNOWN: -1,
    liveInstalledState: async name => { const versionCode = f.localBundles.liveInstalledVersion(name);
      return { versionCode, versionName: f.localBundles.installedVersionName(name, versionCode) }; } };
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
  f2.bridgeClass.deviceLinked = () => f.deviceConnected;
  f2.store = { forget: async (id) => removed.push(id), get: async () => undefined };
  f2.removed = removed;
  f2.calls = calls;
  f2.localVersion = 0;
  f2.deviceConnected = true;
  f2.deviceMissing = [];
  f2.deviceThrows = false;
  f2.deviceUnparsable = false;
  f2.deviceVersions = {};
  f2.knownBundles = [];
  const sandbox = { ...paging, ReleaseChannelRegistry: { apply: app => app, restore: async () => {}, refreshTargets: async () => {} }, ForegroundIdle: { cancel() {}, defer: (_key, fn) => setTimeout(fn, 0) }, VersionCacheEntry: class {}, InstalledBundleState: class { versionCode = -1; versionName = ''; }, setTimeout, clearTimeout, console, Curve: { EaseOut: 'ease-out' },
    InstallReconnect: { clear() {}, deactivate() {} }, InstallConfirmation: { deactivate() {} }, InstallCoordinator: { conditionReady() {} }, InstallStage: { WAITING_DEVICE: 'waiting-device' },
    StoreClient: class {
      listApps(number, size, sort, query) {
        const d = deferred(); requests.push({ ...d, number, query, sort }); return d.promise;
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
    InstalledAppRegistry: { observedAt: () => 0, markCatalogSnapshot: async () => {}, versionName: () => '', version: () => -1 },
    LocalBundles: f.localBundles,
    HdcDeviceBridge: f.bridgeClass,
    JobStore: { open: async () => f.store }
  };
  vm.runInNewContext(code, sandbox);
  sandbox.Page.REFRESH_MIN_VISIBLE_MS = 20;
  const ui = new sandbox.Page();
  Object.assign(ui, { resumeMaintenancePending: false, catalogStatePending: false, catalogStateRescan: false, catalogToken: 0, activeQuery: '', apps: [], appIcons: [], catalogIconFlights: new Map(),
    catalogLoading: false, catalogPage: 0, catalogTotal: 0, catalogMoreBusy: false, catalogMoreError: '',
    catalogRefreshing: false, catalogRefreshBusy: false, catalogError: '',
    getUIContext: () => ({ animateTo: (_options, change) => change() }),
    installedDisplay: new Map(), installedVersions: new Map(), installedJobs: [], catalogProbeBusy: false, catalogProbeNames: [], catalogProbePending: [], updateCatalogReady: false, updateInstallScanPrompt() {}, refreshCatalogInstallState() {},
    updateApps() { return this.apps; }, syncDetectedInstalled() {}, reconcileDetectedJobs: async () => {}, loadUpdateCatalog() {}, checkInstalledUpdates() {},
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
  ui.apps = [{ id: 1 }]; ui.catalogPage = 1; ui.catalogTotal = 60;
  const more = ui.loadApps(false); assert.equal(f.requests[0].number, 2);
  const refresh = ui.pullRefreshCatalog(); f.requests[1].resolve(page([4])); await refresh;
  f.requests[0].resolve(page([1, 2], 60)); await more;
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

test('displayApps preserves the committed order when new pages have already been ranked', () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [10, 300, 50, 120, 400].map((stars, i) => ({ id: i + 1, stars }));
  assert.deepEqual(Array.from(ui.displayApps(), a => a.stars), [10, 300, 50, 120, 400]);
});

test('Discover asks the server to rank featured cards before both first-page and next-page slicing', async () => {
  const f = fixture(), ui = f.ui;
  let run = ui.loadApps();
  assert.equal(f.requests[0].sort, 'discover');
  f.requests[0].resolve(page([{ id: 1, stars: 9000 }], 60)); await run;
  run = ui.loadApps(false);
  assert.equal(f.requests[1].sort, 'discover');
  f.requests[1].resolve(page([{ id: 2, stars: 150 }], 60)); await run;
  assert.deepEqual(Array.from(ui.displayApps(), app => app.id), [1, 2]);
});

test('appending a page only probes newly added apps and preserves earlier installed state', async () => {
  const f = fixture(), ui = f.ui, queried = [];
  ui.apps = [{ id: 1, stars: 0, latestAsset: { bundleName: 'app.old' } }];
  ui.catalogPage = 1; ui.catalogTotal = 60;
  ui.installedVersions.set(1, 200);
  f.localBundles.liveInstalledVersion = name => { queried.push(name); return 0; };
  delete ui.refreshCatalogInstallState;
  const run = ui.loadApps(false);
  f.requests[0].resolve(page([{ id: 2, latestAsset: { bundleName: 'app.new' } }], 60));
  await run;
  await ui.catalogStateFlight;
  assert.deepEqual(queried, ['app.new']);
  assert.equal(ui.installedVersions.get(1), 200);
  assert.equal(ui.installedVersions.get(2), 0);
});

test('pagination failure leaves visible cards intact and blocks repeated automatic requests until retry', async () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, stars: 0 }]; ui.catalogPage = 1; ui.catalogTotal = 60;
  const run = ui.loadApps(false); f.requests[0].reject(new Error('offline')); await run;
  assert.equal(ui.catalogError, '');
  assert.equal(ui.catalogMoreError, 'offline');
  assert.equal(ui.apps[0].id, 1);
  ui.prefetchCatalog(30); ui.loadMoreApps();
  assert.equal(f.requests.length, 1);
  ui.catalogMoreError = ''; ui.loadMoreApps();
  assert.equal(f.requests[1].number, 2);
  f.requests[1].resolve(page([2], 60)); await tick();
  assert.equal(ui.apps[1].id, 2);
});

test('a page starts at most four concurrent icon transfers and stops queuing when the query changes', async () => {
  const f = fixture(), ui = f.ui, pending = deferred();
  ui.apps = page([1, 2, 3, 4, 5, 6, 7, 8]).items;
  const client = { appIconBytes: app => { f.icons.push(app.id); return pending.promise; } };
  const flight = ui.loadCatalogIcons(client, ui.apps, '', false);
  assert.equal(f.icons.length, 4);
  ui.activeQuery = 'another'; pending.resolve(undefined);
  await flight;
  assert.equal(f.icons.length, 4);
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

test('pull refresh waits for device recognition but leaves icon downloads in the background', async () => {
  const f = fixture(), ui = f.ui, icon = deferred(), device = deferred();
  f.localVersion = -1;
  f.icon = () => icon.promise;
  f.bridgeClass.prototype.installedBundleVersions = () => device.promise;
  delete ui.refreshCatalogInstallState; // execute the production dispatcher
  ui.updateInstallScanPrompt = () => {};
  const run = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([{ id: 1, latestAsset: { bundleName: 'app.one' } }]));
  await tick();
  assert.equal(ui.catalogRefreshing, true);
  assert.equal(ui.catalogPage, 1);
  assert.equal(ui.catalogTotal, 1);
  assert.equal(ui.catalogProbeBusy, true);
  assert.equal(ui.appIcons.length, 0);
  device.resolve(new Map([['app.one', 123]]));
  await run;
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.catalogProbeBusy, false);
  assert.equal(ui.appIcons.length, 0);
  icon.resolve(new ArrayBuffer(4)); await tick();
  assert.equal(ui.appIcons.length, 1);
  assert.equal(ui.installedVersions.get(1), 123);
  assert.equal(f.savedIcons[0][0].id, '1');
});

test('dispatcher deduplicates variant bundle names and only sends system-unknown packages to wireless', async () => {
  const f = fixture(), ui = f.ui, nativeQueries = [], scans = [];
  const asset = bundleName => ({ bundleName });
  ui.apps = [{ id: 1, latestAsset: asset('app.known'), latestAssets: [asset('app.known'), asset('app.known')] },
    { id: 2, latestAsset: asset('app.unknown'), latestAssets: [asset('app.unknown'), asset('app.unknown')] }];
  f.localBundles.liveInstalledVersion = name => {
    nativeQueries.push(name); return name === 'app.known' ? 9 : -1;
  };
  delete ui.refreshCatalogInstallState;
  ui.confirmCatalogVersionsViaDevice = names => scans.push([...names]);
  await ui.refreshCatalogInstallState(true);
  assert.deepEqual(nativeQueries, ['app.known', 'app.unknown']);
  assert.deepEqual(scans, [['app.unknown']]);
  assert.equal(ui.installedVersions.get(1), 9);
});

test('a live package result updates its button before the rest of the device scan finishes', async () => {
  const f = fixture(), ui = f.ui, remaining = deferred();
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'app.one' } },
    { id: 2, latestAsset: { bundleName: 'app.two' } }];
  f.bridgeClass.prototype.installedBundleVersions = async (_names, progress) => {
    progress(1, 2, 'app.one', 123);
    await remaining.promise;
    progress(2, 2, 'app.two', 456);
    return new Map([['app.one', 123], ['app.two', 456]]);
  };
  const run = ui.confirmCatalogVersionsViaDevice(['app.one', 'app.two']);
  await tick();
  assert.equal(ui.catalogProbeBusy, true);
  assert.equal(ui.installedVersions.get(1), 123);
  assert.equal(ui.installedVersions.has(2), false);
  remaining.resolve(); await run;
  assert.equal(ui.installedVersions.get(2), 456);
});

test('repeated refresh and pagination reuse an unfinished icon without losing the first page', async () => {
  const f = fixture(), ui = f.ui, icon = deferred();
  f.icon = app => app.id === 1 ? icon.promise : Promise.resolve(new ArrayBuffer(4));
  let run = ui.loadApps(); f.requests[0].resolve(page([1], 60)); await run;
  run = ui.loadApps(); f.requests[1].resolve(page([1], 60)); await run;
  assert.deepEqual(f.icons, [1]);
  run = ui.loadApps(false); f.requests[2].resolve(page([2], 60)); await run;
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

test('pull refresh joins an existing scan and remains visible until new packages are checked', async () => {
  const f = fixture(), ui = f.ui, batches = [];
  f.localVersion = -1;
  delete ui.refreshCatalogInstallState;
  f.bridgeClass.prototype.installedBundleVersions = names => {
    const work = deferred(); batches.push({ names: [...names], ...work }); return work.promise;
  };
  const existing = ui.confirmCatalogVersionsViaDevice(['app.one']);
  const pull = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([
    { id: 1, latestAsset: { bundleName: 'app.one' } },
    { id: 2, latestAsset: { bundleName: 'app.two' } }
  ]));
  await tick();
  assert.equal(ui.catalogRefreshing, true);
  assert.equal(batches.length, 1);
  batches[0].resolve(new Map([['app.one', 123]])); await tick();
  assert.equal(ui.catalogRefreshing, true);
  assert.deepEqual(batches[1].names, ['app.two']);
  batches[1].resolve(new Map([['app.two', 456]]));
  await Promise.all([existing, pull]);
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.installedVersions.get(1), 123);
  assert.equal(ui.installedVersions.get(2), 456);
});

test('a failed device scan releases pull refresh without erasing confirmed versions', async () => {
  const f = fixture(), ui = f.ui, device = deferred();
  f.localVersion = -1;
  ui.installedVersions.set(1, 123);
  delete ui.refreshCatalogInstallState;
  f.bridgeClass.prototype.installedBundleVersions = () => device.promise;
  const pull = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([{ id: 1, latestAsset: { bundleName: 'app.one' } }]));
  await tick(); assert.equal(ui.catalogRefreshing, true);
  device.reject(Error('wireless port closed')); await pull;
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.catalogProbeBusy, false);
  assert.equal(ui.installedVersions.get(1), 123);
});

test('failed automatic reconnect opens a sheet and successful manual connection resumes the same refresh', async () => {
  const f = fixture(), ui = f.ui;
  f.localVersion = -1; f.deviceConnected = false;
  ui.pageVisible = true; ui.showReconnect = false; ui.resumeJobId = ''; ui.reconnectPort = '45678';
  delete ui.refreshCatalogInstallState;
  let probes = 0, connects = 0;
  f.bridgeClass.prototype.installedBundleVersions = async () => {
    probes++;
    if (!f.deviceConnected) throw Error('saved port could not reconnect');
    return new Map([['app.one', 123]]);
  };
  f.bridgeClass.prototype.connect = async () => {
    connects++;
    if (connects === 1) return false;
    f.deviceConnected = true; return true;
  };
  f.bridgeClass.prototype.connectionFailureMessage = () => '端口未开启';
  const pull = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([{ id: 1, latestAsset: { bundleName: 'app.one' } }]));
  await tick();
  assert.equal(probes, 1, 'the inventory already tried automatic reconnect');
  assert.equal(ui.showReconnect, true);
  assert.equal(ui.catalogRefreshing, true);
  await ui.reconnect();
  assert.equal(ui.showReconnect, true, 'bad manual port leaves the sheet available for retry');
  assert.equal(ui.catalogRefreshing, true);
  assert.equal(ui.reconnectBusy, false);
  await ui.reconnect(); await pull;
  assert.equal(probes, 2, 'resume the existing batch, without an extra parallel scan');
  assert.equal(ui.showReconnect, false);
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.installedVersions.get(1), 123);
});

test('cancelling the connection sheet ends refresh and does not ask again for later batches', async () => {
  const f = fixture(), ui = f.ui;
  f.localVersion = -1; f.deviceConnected = false;
  ui.pageVisible = true; ui.showReconnect = false;
  delete ui.refreshCatalogInstallState;
  f.bridgeClass.prototype.installedBundleVersions = async () => { throw Error('offline'); };
  const pull = ui.pullRefreshCatalog();
  f.requests[0].resolve(page([{ id: 1, latestAsset: { bundleName: 'app.one' } }]));
  await tick(); assert.equal(ui.showReconnect, true);
  const joined = ui.confirmCatalogVersionsViaDevice(['app.two']);
  ui.completeRefreshConnection(false); ui.showReconnect = false;
  await Promise.all([pull, joined]);
  assert.equal(ui.catalogRefreshing, false);
  assert.equal(ui.showReconnect, false);
  assert.equal(ui.installedVersions.get(1), -1);
});

test('opening wireless settings preserves the pending refresh while ordinary navigation cancels it', async () => {
  const f = fixture(), ui = f.ui;
  ui.catalogRefreshBusy = true; ui.pageVisible = true; ui.showReconnect = false; ui.resumeJobId = '';
  f.bridgeClass.prototype.openWirelessSettings = async () => {};
  let ended = false;
  const wait = ui.waitForRefreshConnection().then(value => { ended = true; return value; });
  await ui.openReconnectSettings(); ui.onPageHide(); await tick();
  assert.equal(ended, false);
  assert.equal(ui.showReconnect, true);
  ui.pageVisible = true; ui.refreshOpeningSettings = false;
  ui.completeRefreshConnection(true);
  assert.equal(await wait, true);
  const cancelled = ui.waitForRefreshConnection(); ui.onPageHide();
  assert.equal(await cancelled, false);
  assert.equal(ui.showReconnect, false);
});

test('overlapping system refreshes discard the stale snapshot and share completion of the newest catalog', async () => {
  const f = fixture(), ui = f.ui, old = deferred(), newer = deferred();
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'app.old' } }];
  delete ui.refreshCatalogInstallState;
  const queried = [];
  f.localBundles.liveInstalledState = name => {
    queried.push(name); return name === 'app.old' ? old.promise : newer.promise;
  };
  const first = ui.refreshCatalogInstallState();
  ui.apps = [{ id: 2, latestAsset: { bundleName: 'app.new' } }];
  const joined = ui.refreshCatalogInstallState(true);
  assert.equal(first, joined);
  old.resolve({ versionCode: 1, versionName: 'old' }); await tick();
  assert.equal(ui.installedVersions.has(1), false);
  assert.deepEqual(queried, ['app.old', 'app.new']);
  newer.resolve({ versionCode: 2, versionName: 'new' }); await joined;
  assert.equal(ui.installedVersions.get(2), 2); assert.equal(ui.installedVersions.has(1), false);
});
test('the asynchronous dispatcher limits system queries to four outstanding calls', async () => {
  const f = fixture(), ui = f.ui, gates = [], names = [];
  ui.apps = Array.from({ length: 9 }, (_, id) => ({ id, latestAsset: { bundleName: 'app.n' + id } }));
  delete ui.refreshCatalogInstallState;
  f.localBundles.liveInstalledState = name => { names.push(name); const gate = deferred(); gates.push(gate); return gate.promise; };
  const work = ui.refreshCatalogInstallState(); assert.equal(names.length, 4);
  gates[0].resolve({ versionCode: 1, versionName: '1' }); await tick(); assert.equal(names.length, 5);
  for (let i = 1; i < 9; i++) { gates[i].resolve({ versionCode: 1, versionName: '1' }); await tick(); }
  await work; assert.equal(ui.installedVersions.size, 9);
});

test('unchanged device observations preserve visible maps and do not rebuild Management; catalog changes still recompute updates', () => {
  const f = fixture(), ui = f.ui;
  ui.apps = [{ id: 1, latestAsset: { bundleName: 'com.example.one' } }];
  let projections = 0; ui.syncDetectedInstalled = () => projections++;
  ui.applyDetectedCatalogVersion('com.example.one', 7);
  const display = ui.installedDisplay, versions = ui.installedVersions;
  assert.equal(projections, 1);
  for (let i = 0; i < 30; i++) ui.applyDetectedCatalogVersion('com.example.one', 7);
  assert.equal(projections, 1); assert.equal(ui.installedDisplay, display); assert.equal(ui.installedVersions, versions);
  ui.apps = [...ui.apps, { id: 2 }];
  ui.commitCatalogVersions(new Map(display), new Map(versions)); assert.equal(projections, 2);
  ui.applyDetectedCatalogVersion('com.example.one', 0);
  assert.equal(ui.installedVersions.get(1), 0); assert.equal(projections, 3);
});
