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
test('layout and toolbar rows survive restart alongside concurrent sorting changes', async () => {
  const disk = new Map(), a = prefs(disk); await a.load({});
  assert.equal(a.currentLayout(), 'normal');
  await Promise.all([a.saveLayout({}, 'sidebar'), a.saveToolbarRows({}, 2), a.save({}, 'downloads', 'asc')]);
  const b = prefs(disk); await b.load({});
  assert.equal(b.currentLayout(), 'sidebar'); assert.equal(b.current().key, 'downloads');
  assert.equal(b.current().direction, 'asc');
  assert.equal(b.currentToolbarRows(), 2);
  await b.saveLayout({}, 'unrecognized'); const c = prefs(disk); await c.load({});
  assert.equal(c.currentLayout(), 'normal'); assert.equal(c.current().key, 'downloads');
});
test('category order persists, appends new categories and can be reset', async () => {
  const disk = new Map(), a = prefs(disk);
  await a.saveCategoryOrder({}, ['游戏', '工具', '阅读']);
  const b = prefs(disk); await b.load({});
  assert.deepEqual(Array.from(b.orderedCategories(['工具', '生活', '游戏'])), ['游戏', '工具', '生活']);
  await b.saveCategoryOrder({}, []);
  const c = prefs(disk); await c.load({});
  assert.deepEqual(Array.from(c.orderedCategories(['工具', '生活', '游戏'])), ['工具', '生活', '游戏']);
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
  const at = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.ok(at >= 0, name);
  return source.slice(at, source.indexOf('\n  }', at) + 4);
}
test('channel settling starts immediately for retained scenes and loads only after the slide', () => {
  for (const mounted of [false, true]) {
    const frames = [], animations = [], loads = [];
    const box = { Index: { CHANNEL_SWITCH_MS: 300 }, Curve: { EaseOut: 'ease-out' },
      ForegroundIdle: { interaction() {} }, afterPaint: (_context, frame) => frames.push(frame) };
    const methods = ['mountHomeChannel', 'channelSettleDuration', 'settleChannelTo'].map(n => method(indexSource, n)).join('\n');
    vm.runInNewContext(ts.transpileModule('class Page {' + methods + '};globalThis.Page=Page;', {
      compilerOptions: { target: ts.ScriptTarget.ES2020 }
    }).outputText, box);
    const page = Object.assign(new box.Page(), { homeChannel: 'discover', channelProgress: 0.72,
      channelTransition: 0, channelTransitioning: false, catalogChannelMounted: mounted,
      catalogResumeOffset: 38, catalogScroller: { scrollTo() { throw Error('retained offset must not scroll again'); } },
      scrollerOffset: () => 38,
      discoverMotion: { scrollOffset: 26, revealChannelRow() { this.scrollOffset = 0; } },
      afterChannelSwitch() {}, prepareChannel(channel) { loads.push(channel); },
      getUIContext: () => ({ animateTo(options, action) { animations.push(options); action(); } }) });
    Object.defineProperty(page, 'channelDragging', { set(dragging) {
      assert.equal(dragging, false);
      assert.equal(page.channelTransitioning, true, 'no toolbar exposure between drag and settle');
    } });
    page.settleChannelTo(1);
    assert.equal(page.discoverMotion.scrollOffset, 0);
    assert.equal(frames.length, mounted ? 0 : 1);
    assert.equal(animations.length, mounted ? 1 : 0);
    if (!mounted) frames.shift()();
    assert.equal(animations[0].curve, 'ease-out');
    assert.equal(animations[0].duration, 110, 'finishing the last 28% must not take another full 300ms');
    assert.deepEqual(loads, []);
    animations[0].onFinish();assert.deepEqual(loads, ['apps']);assert.equal(page.homeChannel, 'apps');
    assert.equal(page.catalogChannelMounted, true, 'scene remains mounted for the next drag');
  }
});

test('idle prewarming mounts only the view and skips work when the page is hidden', () => {
  const work = [];
  const box = { Index: { TAB_DISCOVER: 0 }, ForegroundIdle: { defer: (_key, fn) => work.push(fn) } };
  vm.runInNewContext(ts.transpileModule('class Page {' + method(indexSource, 'warmHomeChannels') + '};globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const page = Object.assign(new box.Page(), { pageVisible: true, currentTab: 0, catalogChannelMounted: false });
  page.warmHomeChannels();assert.equal(page.catalogChannelMounted, false);work.shift()();assert.equal(page.catalogChannelMounted, true);
  page.warmHomeChannels();assert.equal(work.length, 0);
  page.catalogChannelMounted = false;page.warmHomeChannels();page.pageVisible = false;work.shift()();assert.equal(page.catalogChannelMounted, false);
});
test('horizontal gestures switch either catalog layout and cancel back to the starting channel', () => {
  const methods = ['channelGestureProgress', 'channelGestureStart', 'channelGestureUpdate',
    'channelGestureEnd', 'channelGestureCancel', 'finishChannelDrag'].map(name => method(indexSource, name)).join('\n');
  const box = { ForegroundIdle: { interaction() {} } };
  vm.runInNewContext(ts.transpileModule('class Page {' + methods + '};globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  for (const layout of ['normal', 'sidebar']) {
    const targets = [];
    const page = Object.assign(new box.Page(), {
      homeChannel: 'discover', channelProgress: 0, collectionKey: '', viewportWidth: 400,
      discoverLayout: layout, discoverMotion: { revealChannelRow() {} },
      prepareChannel() { throw Error('dragging must not start a catalog read'); }, mountHomeChannel() { return true; },
      settleChannelTo(target) { this.channelDragging = false; targets.push(target); }
    });
    page.channelGestureStart(12);
    page.channelGestureUpdate(120);
    page.channelGestureEnd(120, 500);
    assert.deepEqual(targets, []);
    page.collectionKey = 'downloads';
    page.channelGestureStart(-12);
    page.channelGestureUpdate(-120);
    page.channelGestureEnd(-120, -500);
    assert.deepEqual(targets, [1]);
    assert.equal(page.collectionKey, 'downloads', 'swiping channels must retain the open collection');
    targets.length = 0;
    page.channelProgress = 0;
    page.collectionKey = '';
    page.channelGestureStart(-12);
    page.channelGestureCancel();
    assert.equal(page.channelDragging, false);
    assert.deepEqual(targets, []);
    page.channelGestureStart(-12);
    page.channelGestureUpdate(-100);
    assert.equal(page.channelProgress, 0.25);
    page.channelGestureEnd(-100, 0);
    assert.deepEqual(targets, [1]);
    page.homeChannel = 'apps';
    page.collectionKey = 'downloads';
    page.channelProgress = 1;
    page.channelGestureStart(12);
    page.channelGestureUpdate(40);
    page.channelGestureEnd(40, 500);
    assert.deepEqual(targets, [1, 0]);
    page.channelProgress = 1;
    page.channelGestureStart(12);
    page.channelGestureUpdate(250);
    page.channelGestureCancel();
    assert.deepEqual(targets, [1, 0, 1]);
  }
});
function discoveryScroll(layout, offset) {
  const calls = [];
  const box = { Edge:{Top:'top'}, Number, ForegroundIdle:{interaction:()=>calls.push('interaction')} };
  const methods = ['normalHomeLayout','channelScroller','discoverScrollOffset','scrollerOffset','syncDiscoverScroll','revealDiscoverTop','backToDiscoverTop','showHomeNavigation','updateHomeNavigationAfterPaint',
    'selectDiscoveryCategory'].map(n => method(indexSource,n)).join('\n');
  vm.runInNewContext(ts.transpileModule(`class Index { ${methods} };globalThis.Index=Index;`,
    {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page = Object.assign(new box.Index(), { homeChannel:'apps', discoverLayout:layout, discoverCanRefresh:false,
    activeCategory:'', homeNavigationHidden:false,
    discoverScroller:{scrollEdge:()=>calls.push('discover-top'),currentOffset:()=>({yOffset:17})},
    catalogScroller:{scrollEdge:()=>calls.push('normal-top'),currentOffset:()=>{
      calls.push('normal-offset'); if(offset instanceof Error)throw offset; return offset;
    }}, sidebarScroller:{scrollEdge:()=>calls.push('sidebar-top')},
    discoverMotion:{reachStart:x=>calls.push(['reach',x]),scroll:x=>x},
    resetCatalogFilter:delay=>calls.push(['filter',delay]) });
  return {page,calls};
}
test('home navigation hides on downward browsing and returns after a deliberate reversal', () => {
  const methods = ['trackHomeNavigation', 'showHomeNavigation', 'updateHomeNavigationAfterPaint', 'navigationAutoHideChanged']
    .map(name => method(indexSource, name)).join('\n');
  const frames = [];
  const finishes = [];
  const box = { afterPaint: (_, fn) => frames.push(fn), Curve: { EaseInOut: 'ease' } };
  vm.runInNewContext(ts.transpileModule('class Index { static TAB_DISCOVER = 0; ' + methods +
    '};globalThis.Page=Index;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Page(), { pageVisible: true, currentTab: 0, autoHideNavigation: true,
    homeNavigationHidden: false, homeNavigationCollapsed: false, homeNavigationProgress: 0, homeNavigationAnimationRevision: 0,
    getUIContext: () => ({ animateTo: (options, update) => { update(); finishes.push(options.onFinish); } }) });
  page.showHomeNavigation();
  page.trackHomeNavigation(10);
  page.trackHomeNavigation(-3);
  page.trackHomeNavigation(23);
  assert.equal(page.homeNavigationHidden, false);
  page.trackHomeNavigation(1);
  assert.equal(page.homeNavigationHidden, false, 'scroll never updates the native bar during layout');
  frames.shift()();
  assert.equal(page.homeNavigationHidden, true);
  assert.equal(page.homeNavigationProgress, 1);
  assert.equal(page.homeNavigationCollapsed, false, 'the native bar stays mounted during the fade');
  page.trackHomeNavigation(-11);
  assert.equal(page.homeNavigationHidden, true);
  page.trackHomeNavigation(-1);
  frames.shift()();
  assert.equal(page.homeNavigationHidden, false);
  assert.equal(page.homeNavigationProgress, 0);
  finishes.shift()();
  assert.equal(page.homeNavigationCollapsed, false, 'an interrupted fade cannot hide the revealed bar');
  finishes.shift()();
  page.channelDragging = true;
  page.trackHomeNavigation(50);
  page.channelDragging = false;
  page.currentTab = 1;
  page.trackHomeNavigation(50);
  assert.equal(page.homeNavigationHidden, false);
  page.currentTab = 0;
  page.trackHomeNavigation(30);
  page.showHomeNavigation();
  assert.equal(frames.length, 1, 'reversals update the same pending frame');
  frames.shift()();
  assert.equal(page.homeNavigationHidden, false);
  page.trackHomeNavigation(30);
  frames.shift()();
  finishes.shift()();
  assert.equal(page.homeNavigationCollapsed, true, 'the faded bar stops receiving touch');
  page.showHomeNavigation();
  frames.shift()();
  assert.equal(page.homeNavigationCollapsed, false);
  page.trackHomeNavigation(24);
  frames.shift()();
  const finishHide = finishes.pop();
  page.autoHideNavigation = false;
  page.navigationAutoHideChanged();
  finishHide();
  page.trackHomeNavigation(100);
  assert.equal(page.homeNavigationHidden, false);
  assert.equal(page.homeNavigationCollapsed, false);
  assert.equal(page.homeNavigationProgress, 0);
  assert.equal(frames.length, 0);
});

test('sidebar navigation and install action share a reversible timeline, including a reveal queued before hide finishes', () => {
  const methods = ['trackHomeNavigation', 'showHomeNavigation', 'updateHomeNavigationAfterPaint']
    .map(name => method(indexSource, name)).join('\n');
  const frames = [], animations = [];
  const box = { afterPaint: (_, fn) => frames.push(fn), Curve: { EaseInOut: 'ease' } };
  vm.runInNewContext(ts.transpileModule('class Index { static TAB_DISCOVER = 0; ' + methods +
    '};globalThis.Page=Index;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Page(), { pageVisible: true, currentTab: 0, autoHideNavigation: true,
    homeChannel: 'apps', discoverLayout: 'sidebar', homeNavigationHidden: false,
    homeNavigationCollapsed: false, homeNavigationProgress: 0, homeNavigationTravel: 0, homeNavigationAnimationRevision: 0,
    getUIContext: () => ({ animateTo: (options, update) => { update(); animations.push(options); } }) });
  page.trackHomeNavigation(24);
  assert.equal(page.homeNavigationProgress, 0, 'scroll layout cannot mutate the dock');
  frames.shift()();
  assert.equal(page.homeNavigationProgress, 1);
  assert.equal(animations[0].duration, 300);
  page.trackHomeNavigation(-12);
  animations[0].onFinish();
  assert.equal(page.homeNavigationCollapsed, false, 'a pending reversal must not blink the native bar off');
  frames.shift()();
  assert.equal(page.homeNavigationProgress, 0);
  assert.equal(animations[1].duration, animations[0].duration);
  assert.equal(animations[1].curve, animations[0].curve);
  animations[0].onFinish();
  assert.equal(page.homeNavigationCollapsed, false);
  page.trackHomeNavigation(24);
  frames.shift()();
  animations[2].onFinish();
  assert.equal(page.homeNavigationCollapsed, true);
  page.showHomeNavigation();
  frames.shift()();
  assert.equal(page.homeNavigationCollapsed, false);
  assert.equal(page.homeNavigationProgress, 0);
});

test('carousel countdown advances from the six-second progress animation only while active', () => {
  const bannerSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/DiscoverBanner.ets'), 'utf8');
  const start = bannerSource.indexOf('  aboutToAppear()');
  const end = bannerSource.indexOf('  @Builder\n  private marker', start);
  const frames = [], animations = [], advances = [];
  const box = { afterPaint: (_, fn) => frames.push(fn), Curve: { Linear: 'linear' },
    TouchType: { Down: 0, Up: 1, Cancel: 2 } };
  vm.runInNewContext(ts.transpileModule(bannerSource.match(/const BANNER_DWELL_MS[^;]+;/)[0] +
    'class Banner {' + bannerSource.slice(start, end) + '};globalThis.Banner=Banner;',
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const banner = Object.assign(new box.Banner(), { blocks: [{ key: 'stars' }, { key: 'downloads' }],
    selected: 0, slideIndex: 0, remaining: 1, active: true, foreground: true, revision: 0,
    controller: { showNext: () => advances.push('next') },
    getUIContext: () => ({ animateTo: (options, update) => {
      update(); if (options.onFinish) animations.push(options);
    } }) });
  const paint = () => frames.splice(0).forEach(frame => frame());
  banner.aboutToAppear();
  paint();
  assert.equal(animations.length, 0);
  banner.updateVisibility(true, 1);
  paint();
  assert.equal(animations[0].duration, 6000);
  assert.equal(animations[0].curve, 'linear');
  assert.equal(banner.remaining, 0);
  banner.blocks = [{ key: 'stars' }, { key: 'downloads' }];
  banner.syncSlides();
  assert.equal(frames.length, 0, 'a refresh of the same slides leaves the countdown running');
  banner.updateTouch({ type: box.TouchType.Down });
  animations.shift().onFinish();
  assert.equal(advances.length, 0);
  assert.equal(banner.remaining, 0, 'callbacks must not start animation transactions before paint');
  paint();
  banner.updateTouch({ type: box.TouchType.Up });
  paint();
  const beforeRotation = animations.shift();
  beforeRotation.onFinish();
  assert.equal(advances.length, 0, 'native countdown completion must not reenter the Swiper');
  banner.updateSize({ width: 380, height: 162 }, { width: 415, height: 162 });
  paint();
  assert.equal(advances.length, 0, 'resize retires a queued turn from the previous geometry');
  assert.equal(banner.remaining, 1);
  paint();
  animations.shift().onFinish();
  paint();
  assert.equal(advances.length, 1);
  banner.restartCountdown();
  banner.foreground = false;
  banner.restartCountdown();
  paint();
  assert.equal(animations.length, 0, 'a queued restart cannot run in the background');
  banner.foreground = true;
  banner.restartCountdown();
  paint();
  animations.shift().onFinish();
  banner.aboutToDisappear();
  paint();
  assert.equal(advances.length, 1, 'a detached Swiper never receives the queued turn');
});
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
test('discover channel can scroll while the saved catalog mode is sidebar', () => {
  const {page,calls} = discoveryScroll('sidebar',new Error('unmounted'));
  page.homeChannel = 'discover';
  page.backToDiscoverTop();
  assert.deepEqual(calls,['discover-top',['reach',17]]);
});
test('starfield uses existing card tiers only in dark split discovery', () => {
  const box = {};
  const methods = ['splitFeaturedStars', 'sidebarFeaturedStars', 'splitOnStarfield',
    'featuredTier', 'featuredColors'].map(n => method(indexSource, n)).join('\n');
  vm.runInNewContext(ts.transpileModule(`class Index { static TAB_DISCOVER=0; static STARRED_MIN_STARS=100; ${methods} };globalThis.Index=Index;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const view = Object.assign(new box.Index(), { homeChannel:'apps', darkMode:true, discoverLayout:'sidebar', currentTab:0, sidebarSelectedId:1,
    appBackground: { theme: 'default' },
    apps:[{id:1,stars:99},{id:2,stars:200},{id:3,stars:1500},{id:4,stars:12000}] });
  assert.equal(view.splitOnStarfield(), false);
  for (const [id, tier] of [[2,1],[3,2],[4,3]]) {
    view.sidebarSelectedId=id; assert.equal(view.splitOnStarfield(), true);
    assert.equal(view.featuredTier(view.splitFeaturedStars()), tier);
    assert.equal(view.featuredColors(view.splitFeaturedStars()).length, 3);
  }
  view.appBackground = { theme: 'fern' }; assert.equal(view.splitOnStarfield(), false);
  view.appBackground = { theme: 'default' };
  view.homeChannel='discover'; assert.equal(view.splitOnStarfield(), false);
  view.homeChannel='apps';
  view.darkMode=false; assert.equal(view.splitOnStarfield(), false);
  view.darkMode=true;
  view.discoverLayout='normal'; assert.equal(view.splitOnStarfield(), false);
  view.discoverLayout='sidebar'; view.currentTab=1; assert.equal(view.splitOnStarfield(), false);
});
test('embedded detail and ordinary detail both follow the selected theme', () => {
  const start = source.indexOf('  private colors(): Palette {');
  const line = source.slice(start, source.indexOf('\n', start));
  assert.ok(start >= 0);
  const box = { Palette: { forMode: dark => dark ? 'dark' : 'light' } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${line} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = new box.Page();
  for (const embedded of [true, false]) {
    page.embedded = embedded;
    page.darkMode = false; assert.equal(page.colors(), 'light');
    page.darkMode = true; assert.equal(page.colors(), 'dark');
  }
});

test('collection opening fetches beyond its eight preview rows, then appends the next page', async () => {
  const entries = (first, count) => Array.from({length:count}, (_,i) => ({ app:{id:first+i} }));
  const callbacks = [], requests = [];
  const box = { Index:{COLLECTION_SWITCH_MS:200}, Curve:{FastOutSlowIn:1}, getContext:()=>({}),
    StoreClient:class {
      async collections(days, limit, key, page) {
        requests.push([days,limit,key,page]);
        const rows=page===1 ? entries(1,24) : entries(25,5);
        return {block:()=>({key,page,pageSize:24,total:29,basis:'',entries:rows}),apps:()=>[]};
      }
    } };
  const methods = ['openCollectionsMore','loadCollectionDetail'].map(n => method(indexSource,n)).join('\n');
  vm.runInNewContext(ts.transpileModule('class Page {'+methods+'};globalThis.Page=Page;', {
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page = Object.assign(new box.Page(), {collectionKey:'',collectionRequest:0,
    collections:{block:()=>({basis:'',entries:entries(1,8),total:29})},
    getUIContext:()=>({animateTo:(_options,callback)=>callbacks.push(callback)}),
    discoverMotion:{reachStart(){}},backToDiscoverTop(){},scrollerOffset:()=>56,loadCatalogIcons(){}});
  page.openCollectionsMore('downloads');
  assert.deepEqual(requests,[]);
  callbacks.shift()();
  assert.equal(page.collectionEntries.length,8);
  assert.equal(page.collectionLoading,true);
  await page.loadCollectionDetail('downloads');
  assert.deepEqual(requests,[[7,24,'downloads',1]]);
  assert.equal(page.collectionEntries.length,24);
  await page.loadCollectionDetail('downloads');
  assert.equal(page.collectionEntries.length,29);
  assert.equal(page.collectionHasMore,false);
  await page.loadCollectionDetail('downloads');
  assert.deepEqual(requests,[[7,24,'downloads',1],[7,24,'downloads',2]]);
});


test('a warmed hidden sidebar defers its detail scene until the channel is visible', () => {
  const { pane } = sidebarPane();
  pane.visible = false;pane.appId = 6;pane.aboutToAppear();
  assert.deepEqual(Array.from(pane.scenes), []);
  pane.appId = 7;pane.selectApp();assert.deepEqual(Array.from(pane.scenes), []);
  pane.visible = true;pane.activateScene();assert.deepEqual(Array.from(pane.scenes), [7]);
  assert.equal(pane.currentId, 7);assert.equal(pane.revealedId, 7);
});
