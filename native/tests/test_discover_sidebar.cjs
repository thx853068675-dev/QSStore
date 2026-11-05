const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { loadEts } = require('./load_ets.cjs');
const sort = loadEts('data/DiscoverSort');
function prefs(disk) {
  const kit = { preferences: { getPreferences: async () => ({
    get: async (k, d) => disk.get(k) ?? d,
    put: async (k, v) => { disk.set(k, v); }, flush: async () => {}
  }) } };
  return loadEts('data/DiscoverSortPreferences', { './DiscoverSort': sort, '@kit.ArkData': kit }).DiscoverSortPreferences;
}
test('layout choice survives restart and concurrent sorting changes independently', async () => {
  const disk = new Map(), a = prefs(disk); await a.load({});
  assert.equal(a.currentLayout(), 'normal');
  await Promise.all([a.saveLayout({}, 'sidebar'), a.save({}, 'downloads', 'asc')]);
  const b = prefs(disk); await b.load({});
  assert.equal(b.currentLayout(), 'sidebar'); assert.equal(b.current().key, 'downloads');
  assert.equal(b.current().direction, 'asc');
  await b.saveLayout({}, 'unrecognized'); const c = prefs(disk); await c.load({});
  assert.equal(c.currentLayout(), 'normal'); assert.equal(c.current().key, 'downloads');
});
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Detail.ets'), 'utf8');
const start = source.indexOf('  private async loadApp(): Promise<void> {');
const end = source.indexOf('\n  private async loadDetailIcon', start);
assert.ok(start >= 0 && end > start);
function detail(embedded, selected, route) {
  const requests = [];
  const box = { Promise, I18n: { t: x => x }, getContext: () => ({}), router: { getParams: () => route },
    errorText: e => e.message, ReleaseChannelRegistry: { restore: async () => {}, preview: id => id === 42 },
    StoreClient: class { async appDetail(id) { requests.push(id); return { id }; } } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${source.slice(start, end)} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Page(), { embedded, embeddedAppId: selected, disposed: false, detailLoading: false,
    restoreUpdatePolicy: async () => {}, syncInstallTask: () => {}, loadDetailIcon: async () => {},
    onEmbeddedReady: () => {},
    loadInitialReleases: async () => {}, loadReviews: async () => {} });
  return { page, requests };
}
test('embedded detail uses the selected application and its persisted channel, ignoring route parameters', async () => {
  const f = detail(true, 42, { id: 77, notificationPreview: 0 }); await f.page.loadApp();
  assert.deepEqual(f.requests, [42]); assert.equal(f.page.app.id, 42);
  assert.equal(f.page.loaded, true); assert.equal(f.page.showPreviewReleases, true);
  assert.equal(f.page.error, '');
});

function sidebarPane() {
  const text = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/SidebarDetailPane.ets'), 'utf8');
  const start = text.indexOf('  aboutToAppear(): void {'), end = text.indexOf('\n  build()', start);
  const box = { Curve: { EaseInOut: 'ease' } };
  vm.runInNewContext(ts.transpileModule(`class Pane { ${text.slice(start, end)} };globalThis.Pane=Pane;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const finishes = [];
  const pane = Object.assign(new box.Pane(), { appId:1, currentId:0, revealedId:0, scenes:[], disposed:false,
    visible:true,
    transitioning:false, transitionGeneration:0, getUIContext: () => ({ animateTo: (opts, action) => {
      action(); finishes.push(opts.onFinish);
    } }) });
  pane.aboutToAppear();
  return { pane, finish: () => finishes.shift()?.() };
}
test('slow or discarded details never blank the current scene or replace the latest selection', () => {
  const { pane, finish } = sidebarPane();
  pane.appId=2; pane.selectApp(); assert.deepEqual([...pane.scenes], [1,2]);
  assert.equal(pane.revealedId,1);
  pane.appId=3; pane.selectApp(); assert.deepEqual([...pane.scenes], [1,3]);
  pane.detailReady(2); assert.equal(pane.revealedId,1);
  pane.detailReady(3); assert.equal(pane.revealedId,3); assert.equal(pane.currentId,1);
  finish(); assert.equal(pane.currentId,3); assert.deepEqual([...pane.scenes],[3]);
});
test('rapid selections during a fade queue only the final app, and leaving cancels completion', () => {
  const { pane, finish } = sidebarPane();
  pane.appId=2; pane.selectApp(); pane.detailReady(2);
  pane.appId=3; pane.selectApp(); pane.appId=4; pane.selectApp();
  assert.deepEqual([...pane.scenes],[1,2]);
  finish(); assert.deepEqual([...pane.scenes],[2,4]); assert.equal(pane.currentId,2);
  pane.detailReady(4); pane.aboutToDisappear(); finish();
  assert.equal(pane.currentId,2);
});
test('the outgoing scene retains its own theme while the next theme loads and fades', () => {
  const { pane, finish } = sidebarPane();
  pane.starfield=true; pane.selectApp(); assert.equal(pane.currentStarfield,true);
  pane.appId=2; pane.starfield=false; pane.selectApp();
  assert.equal(pane.currentStarfield,true); assert.equal(pane.pendingStarfield,false);
  pane.detailReady(2);
  pane.appId=3; pane.starfield=true; pane.selectApp();
  assert.equal(pane.pendingStarfield,false);
  finish(); assert.equal(pane.currentId,2); assert.equal(pane.currentStarfield,false);
  assert.equal(pane.pendingStarfield,true);
});
test('scrolling stays available while loading and fading, while the old install action stays hidden', () => {
  const {pane,finish}=sidebarPane();
  pane.appId=2;pane.selectApp();
  assert.equal(pane.sceneAcceptsInput(1),true);
  assert.equal(pane.sceneAcceptsInput(2),false);
  assert.equal(pane.sceneActionsVisible(1),false,'old application must not be installable after selection changes');
  pane.detailReady(2);
  assert.equal(pane.sceneAcceptsInput(2),true,'incoming content can scroll before the fade finishes');
  assert.equal(pane.sceneAcceptsInput(1),false);
  finish();assert.equal(pane.sceneActionsVisible(2),true);
});
test('the sidebar is ready before slow icons or release reads finish', async () => {
  const {page}=detail(true,42,{});let iconReady,versionsReady,notified=false;
  page.loadDetailIcon=()=>new Promise(resolve=>{iconReady=resolve;});
  page.loadInitialReleases=()=>new Promise(resolve=>{versionsReady=resolve;});
  page.onEmbeddedReady=()=>{notified=true;};
  const pending=page.loadApp();await new Promise(setImmediate);
  assert.equal(page.loaded,true);assert.equal(notified,true);
  iconReady();versionsReady();await pending;
});
test('standalone detail continues to honor its route and notification channel', async () => {
  const f = detail(false, 42, { id: 77, notificationPreview: 1 }); await f.page.loadApp();
  assert.deepEqual(f.requests, [77]); assert.equal(f.page.app.id, 77);
  assert.equal(f.page.showPreviewReleases, true);
});

const indexSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(source, name) {
  const at = source.search(new RegExp(`^  private ${name}\\(`, 'm'));
  assert.ok(at >= 0, name);
  return source.slice(at, source.indexOf('\n  }', at) + 4);
}
function discoveryScroll(layout, offset) {
  const calls = [];
  const box = { Edge:{Top:'top'}, Number, ForegroundIdle:{interaction:()=>calls.push('interaction')} };
  const methods = ['discoverScrollOffset','syncDiscoverScroll','revealDiscoverTop','backToDiscoverTop',
    'selectDiscoveryCategory'].map(n => method(indexSource,n)).join('\n');
  vm.runInNewContext(ts.transpileModule(`class Index { ${methods} };globalThis.Index=Index;`,
    {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page = Object.assign(new box.Index(), { discoverLayout:layout, discoverCanRefresh:false,
    discoverTitleHeight:68, activeCategory:'',
    discoverScroller:{scrollEdge:()=>calls.push('normal-top'),currentOffset:()=>{
      calls.push('normal-offset'); if(offset instanceof Error)throw offset; return offset;
    }}, sidebarScroller:{scrollEdge:()=>calls.push('sidebar-top')},
    discoverMotion:{reachStart:x=>calls.push(['reach',x]),scroll:x=>x},
    resetCatalogFilter:delay=>calls.push(['filter',delay]) });
  return {page,calls};
}
test('sidebar category changes reset the sidebar without ever reading the unmounted normal list', () => {
  const {page,calls} = discoveryScroll('sidebar',new Error('unmounted'));
  page.selectDiscoveryCategory('影音');
  assert.deepEqual(calls,['sidebar-top',['reach',0],['filter',180]]);
  assert.equal(page.activeCategory,'影音'); assert.equal(page.discoverCanRefresh,true);
  page.syncDiscoverScroll(); assert.equal(calls.length,3,'late normal scroll callbacks are ignored');
});
test('normal layout keeps its real navigation offset and tolerates unbound transition frames', () => {
  const normal = discoveryScroll('normal',{yOffset:23}); normal.page.backToDiscoverTop();
  assert.deepEqual(normal.calls,['normal-top','normal-offset',['reach',23]]);
  for(const unavailable of [undefined,new Error('detached'),{yOffset:NaN}]){
    const f=discoveryScroll('normal',unavailable);f.page.backToDiscoverTop();f.page.syncDiscoverScroll();
    assert.equal(f.page.discoverCanRefresh,true);
    assert.ok(f.calls.some(call=>Array.isArray(call)&&call[0]==='reach'&&call[1]===0));
  }
});
test('starfield follows the selected app and the existing card tiers only in split discovery', () => {
  const box = {};
  const methods = ['splitFeaturedStars', 'splitOnStarfield', 'featuredTier', 'featuredColors'].map(n => method(indexSource, n)).join('\n');
  vm.runInNewContext(ts.transpileModule(`class Index { static TAB_DISCOVER=0; static STARRED_MIN_STARS=100; ${methods} };globalThis.Index=Index;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const view = Object.assign(new box.Index(), { discoverLayout:'sidebar', currentTab:0, sidebarSelectedId:1,
    apps:[{id:1,stars:99},{id:2,stars:200},{id:3,stars:1500},{id:4,stars:12000}] });
  assert.equal(view.splitOnStarfield(), false);
  for (const [id, tier] of [[2,1],[3,2],[4,3]]) {
    view.sidebarSelectedId=id; assert.equal(view.splitOnStarfield(), true);
    assert.equal(view.featuredTier(view.splitFeaturedStars()), tier);
    assert.equal(view.featuredColors(view.splitFeaturedStars()).length, 3);
  }
  view.discoverLayout='normal'; assert.equal(view.splitOnStarfield(), false);
  view.discoverLayout='sidebar'; view.currentTab=1; assert.equal(view.splitOnStarfield(), false);
});
test('embedded starfield uses readable dark detail colors without changing ordinary detail', () => {
  const start = source.indexOf('  private colors(): Palette {');
  const line = source.slice(start, source.indexOf('\n', start));
  assert.ok(start >= 0);
  const box = { Palette: { forMode: dark => dark ? 'dark' : 'light' } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${line} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Page(), { darkMode:false, embedded:true, embeddedStarfield:true });
  assert.equal(page.colors(), 'dark'); page.embeddedStarfield=false; assert.equal(page.colors(), 'light');
  page.embedded=false; page.embeddedStarfield=true; assert.equal(page.colors(), 'light');
  page.darkMode=true; assert.equal(page.colors(), 'dark');
});
