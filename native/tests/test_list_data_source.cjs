const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture() {
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/ListDataSource.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { exports });
  const data = new exports.ListDataSource(row => String(row.id), row => JSON.stringify(row));
  const events = [];
  const listener = { onDataAdd: index => events.push(['add', index, data.totalCount()]),
    onDataChange: index => events.push(['change', index]),
    onDataReloaded: () => events.push(['reload']) };
  data.registerDataChangeListener(listener); data.registerDataChangeListener(listener);
  return { data, events, listener };
}
test('pagination appends lazily without replacing previous rows or keys', () => {
  const f = fixture(); const first = Array.from({ length: 1000 }, (_, id) => ({ id, name: 'app' + id }));
  f.data.update(first);
  const row = f.data.getData(0), key = f.data.key(row); f.events.length = 0;
  const more = Array.from({ length: 20 }, (_, n) => ({ id: 1000 + n, name: 'next' + n }));
  f.data.update([...first.map(row => ({ ...row })), ...more]);
  assert.equal(f.data.totalCount(), 1020); assert.equal(f.data.getData(0), row);
  assert.equal(f.data.key(row), key);
  assert.deepEqual(f.events, more.map((_, n) => ['add', 1000 + n, 1001 + n]));
  f.events.length = 0; f.data.update([...first, ...more]); assert.equal(f.events.length, 0);
});
test('channel, icon and package changes invalidate only changed rows and retain correct current payload', () => {
  const f = fixture(); const a = { id: 1, iconRev: '1', latestAsset: { versionCode: 1, url: 'old' } }, b = { id: 2 };
  f.data.update([a, b]); const oldKey = f.data.key(a), otherKey = f.data.key(b);
  f.events.length = 0;
  const changed = { ...a, previewChannel: true, iconRev: '2', latestAsset: { versionCode: 1, url: 'new' } };
  f.data.update([changed, { ...b }]);
  assert.notEqual(f.data.key(changed), oldKey); assert.equal(f.data.key(b), otherKey);
  assert.equal(f.data.getData(0).latestAsset.url, 'new'); assert.deepEqual(f.events, [['change', 0]]);
  // Empty preview must not retain the old install target.
  f.data.update([{ id: 1, previewChannel: true, channelUnavailable: true }, b]);
  assert.equal(f.data.getData(0).latestAsset, undefined);
});
test('filtering, reordering, clearing and unregistering never retain obsolete displayed rows', () => {
  const f = fixture(), a = { id: 1 }, b = { id: 2 };
  f.data.update([a, b]); const key = f.data.key(b);
  f.data.update([b, a]); assert.equal(f.data.getData(0).id, 2); assert.equal(f.data.key(b), key);
  f.data.update([b]); assert.equal(f.data.totalCount(), 1); assert.equal(f.data.getData(0).id, 2);
  f.data.update([]); assert.equal(f.data.totalCount(), 0);
  f.data.unregisterDataChangeListener(f.listener); f.events.length = 0;
  f.data.update([a]); assert.equal(f.events.length, 0);
});
test('title measurement is reused when only version or available width changes', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/CatalogAppTitle.ets'), 'utf8');
  const start = source.indexOf('  private updateBadge('), end = source.indexOf('\n  }', start) + 4;
  const exports = {};
  vm.runInNewContext(ts.transpileModule(`class Title { ${source.slice(start, end)} }; exports.Title=Title;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, displayVersion: (version) => version, FontWeight: { Bold: 'bold' }, fitVersionBadge: (version, available, measure) => {
    const width = measure(version); return { text: version, width: Math.min(available, width) };
  } });
  const ui = new exports.Title(), measured = [];
  Object.assign(ui, { title: '应用名称', titleSize: 17, version: '1.0', rowWidth: 200,
    measuredTitle: '', measuredTitleSize: -1,
    getUIContext: () => ({ px2vp: n => n, getMeasureUtils: () => ({ measureText: spec => {
      measured.push(spec.textContent); return spec.textContent.length * spec.fontSize;
    } }) }) });
  ui.updateBadge(); ui.version = '1.1'; ui.updateBadge(); ui.rowWidth = 150; ui.updateBadge();
  assert.equal(measured.filter(s => s === '应用名称').length, 1);
  assert(ui.titleWidth <= 150 - ui.badgeWidth - 5);
  ui.titleSize = 19; ui.updateBadge(); assert.equal(measured.filter(s => s === '应用名称').length, 2);
  ui.title = '新名称'; ui.updateBadge(); assert.equal(measured.at(-1), '新名称');
});

test('Management coalesces related mutations and updates both groups, queue and counters from the final state', () => {
  const f = fixture();
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private syncManagementRows('), end = source.indexOf('\n  }', start) + 4;
  const exports = {}, timers = [];
  vm.runInNewContext(ts.transpileModule(`class Page { ${source.slice(start, end)} }; exports.Page=Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, setTimeout: fn => { timers.push(fn); return timers.length; } });
  const ui = new exports.Page();
  Object.assign(ui, { managementRowsTimer: -1, queueRows: f.data,
    onlineInstalledRows: fixture().data, offlineInstalledRows: fixture().data, publishedRows: fixture().data,
    queued: [], online: [], offline: [], myApps: [],
    managementQueueJobs() { return this.queued; },
    managementInstalledJobs(localOnly) { return localOnly ? this.offline : this.online; } });
  for (let i = 0; i < 20; i++) ui.syncManagementRows();
  ui.queued = [{ id: 'queue' }]; ui.online = [{ id: 'a' }, { id: 'b' }]; ui.offline = [{ id: 'c' }];
  ui.myApps = [{ id: 'published' }];
  assert.equal(timers.length, 1); timers.shift()();
  assert.equal(ui.managementRowsTimer, -1);
  assert.equal(ui.queueRowCount, 1); assert.equal(ui.onlineInstalledCount, 2); assert.equal(ui.offlineInstalledCount, 1);
  assert.equal(ui.publishedRows.getData(0).id, 'published');
  // A canceled queue item and an external uninstall disappear from the retained sources too.
  ui.queued = []; ui.offline = []; ui.syncManagementRows(); timers.shift()();
  assert.equal(ui.queueRows.totalCount(), 0); assert.equal(ui.offlineInstalledCount, 0);
  assert.equal(ui.onlineInstalledRows.totalCount(), 2);
});
