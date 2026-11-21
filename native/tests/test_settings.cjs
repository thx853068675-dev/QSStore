const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks, globals = {}) {
  const exports = {};
  if (file === 'data/SettingsCache' && !mocks['./ApplicationIcons']) mocks['./ApplicationIcons'] = { applicationIcons: () => ({ stats: () => ({ bytes: 0 }), clear: () => {} }) };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, require: name => mocks[name] || {}, ...globals });
  return exports;
}
function appearanceFixture(disk = new Map()) {
  const storage = new Map(), native = [], events = [];
  const staged = new Map(disk);
  let failing = false;
  const prefs = { preferences: { getPreferences: async (_ctx, store) => {
    assert.equal(store, 'qingqi-settings');
    return { get: async (key, fallback) => staged.get(key) ?? fallback,
      put: async (key, value) => staged.set(key, value),
      flush: async () => {
        if (failing) throw Error('disk full');
        for (const [key, value] of staged) disk.set(key, value);
      } };
  } } };
  const globals = { AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) } };
  const { AppearancePreferences } = load('data/AppearancePreferences', {
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: {
      COLOR_MODE_NOT_SET: -1, COLOR_MODE_LIGHT: 0, COLOR_MODE_DARK: 1
    } } },
    '@kit.ArkData': prefs
  }, globals);
  const { AppBackgroundPreferences } = load('data/AppBackgroundPreferences', {
    '@kit.ArkData': prefs, './AppearancePreferences': { AppearancePreferences }
  }, globals);
  const context = { getApplicationContext: () => ({ setColorMode: mode => native.push(mode) }),
    eventHub: { emit: name => events.push(name) } };
  return { service: AppearancePreferences, background: AppBackgroundPreferences, context, storage, native, events, disk,
    fail: () => { failing = true; } };
}

function managementFixture(disk = new Map()) {
  const storage = new Map(), memory = new Map(disk);
  let failing = false, flushGate;
  const { ManagementPreferences } = load('data/ManagementPreferences', {
    '@kit.ArkData': { preferences: { getPreferences: async (_ctx, name) => {
      assert.equal(name, 'management-layout');
      if (failing) throw Error('preferences unavailable');
      return { get: async (key, fallback) => memory.get(key) ?? fallback,
        put: async (key, value) => memory.set(key, value),
        flush: async () => {
          if (flushGate) await flushGate;
          for (const [key, value] of memory) disk.set(key, value);
        } };
    } } }
  }, { AppStorage: { setOrCreate: (key, value) => storage.set(key, value) } });
  return { service: ManagementPreferences, context: {}, disk, storage,
    fail: value => { failing = value; },
    holdFlush: () => { let release; flushGate = new Promise(resolve => { release = resolve; }); return release; } };
}

function developerModeFixture(disk = new Map()) {
  const storage = new Map(), memory = new Map(disk);
  let failing = false;
  const { LocalDeveloperMode, localTools } = load('data/LocalTools', {
    './I18n': { I18n: { t: key => key } },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      get: async (key, fallback) => memory.get(key) ?? fallback,
      put: async (key, value) => memory.set(key, value),
      flush: async () => {
        if (failing) throw Error('disk full');
        for (const [key, value] of memory) disk.set(key, value);
      }
    }) } }
  }, { $r: key => key, AppStorage: { get: key => storage.get(key),
    setOrCreate: (key, value) => storage.set(key, value) } });
  return { LocalDeveloperMode, localTools, disk, fail: value => { failing = value; } };
}

test('AppGallery extraction is hidden by default and unlocked on this installation after a durable save', async () => {
  const first = developerModeFixture();
  const toolIds = f => Array.from(f.localTools(f.LocalDeveloperMode.enabled()), tool => tool.id);
  await first.LocalDeveloperMode.restore({});
  assert.deepEqual(toolIds(first), ['local-install-tool', 'local-editor-tool', 'local-app-list-tool']);
  first.fail(true);
  await assert.rejects(first.LocalDeveloperMode.enable({}), /disk full/);
  await first.LocalDeveloperMode.restore({});
  assert.equal(toolIds(first).includes('local-grab-tool'), false);
  first.fail(false);
  await first.LocalDeveloperMode.enable({});
  assert.equal(toolIds(first).at(-1), 'local-grab-tool');
  const restarted = developerModeFixture(first.disk);
  await restarted.LocalDeveloperMode.restore({});
  assert.deepEqual(toolIds(restarted), toolIds(first));
});

test('only six consecutive version taps enable developer mode and concurrent taps share the save', async () => {
  const source = fs.readFileSync(path.join(root, 'pages/Settings.ets'), 'utf8');
  const start = source.indexOf('  private async tapVersion(');
  const end = source.indexOf('  @Builder private information(', start);
  let now = 10000, calls = 0, enabled = false, finishSave;
  const toasts = [];
  const sandbox = { Date: { now: () => now }, getContext: () => ({}),
    I18n: { t: key => key }, promptAction: { showToast: ({ message }) => toasts.push(message) },
    LocalDeveloperMode: {
      enabled: () => enabled,
      enable: async () => {
        calls++;
        await new Promise(resolve => { finishSave = resolve; });
        enabled = true;
      }
    } };
  vm.runInNewContext(ts.transpileModule('class Settings {' + source.slice(start, end) + '};globalThis.Page=Settings;',
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);
  const page = Object.assign(new sandbox.Page(), { visible: true, versionCode: '2026111005', versionTapCount: 0 });
  for (let i = 0; i < 5; i++) { await page.tapVersion(); now += 200; }
  assert.equal(calls, 0);
  now += 3000;
  for (let i = 0; i < 5; i++) { await page.tapVersion(); now += 200; }
  assert.equal(calls, 0, 'an earlier series must expire');
  const pending = page.tapVersion();
  await page.tapVersion();
  assert.equal(calls, 1);
  finishSave(); await pending;
  await page.tapVersion();
  assert.equal(calls, 1);
  assert.deepEqual(toasts, ['已开启开发者模式']);
});

test('management section choices survive restart independently', async () => {
  const first = managementFixture();
  await first.service.load(first.context);
  assert.equal(first.storage.get('managementPublishedCollapsed'), false);
  assert.equal(first.storage.get('managementInstalledCollapsed'), false);
  await first.service.save(first.context, true, true);
  await first.service.save(first.context, false, true);
  const restarted = managementFixture(first.disk);
  await restarted.service.load(restarted.context);
  assert.equal(restarted.storage.get('managementPublishedCollapsed'), true);
  assert.equal(restarted.storage.get('managementInstalledCollapsed'), true);
  await restarted.service.save(restarted.context, true, false);
  const again = managementFixture(first.disk);
  await again.service.load(again.context);
  assert.equal(again.storage.get('managementPublishedCollapsed'), false);
  assert.equal(again.storage.get('managementInstalledCollapsed'), true);
});

test('rapid section toggles and restore wait for durable writes in order', async () => {
  const f = managementFixture(), release = f.holdFlush();
  const one = f.service.save(f.context, true, true);
  const two = f.service.save(f.context, true, false);
  const three = f.service.save(f.context, false, true);
  const restore = f.service.load(f.context);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.disk.size, 0);
  assert.equal(f.storage.size, 0, 'restore must not read an unfinished older write');
  release(); await Promise.all([one, two, three, restore]);
  assert.equal(f.disk.get('publishedCollapsed'), false);
  assert.equal(f.disk.get('installedCollapsed'), true);
  assert.equal(f.storage.get('managementPublishedCollapsed'), false);
  assert.equal(f.storage.get('managementInstalledCollapsed'), true);
});

test('unavailable layout preferences use defaults and a failed save does not poison later writes', async () => {
  const f = managementFixture(); f.fail(true);
  await f.service.load(f.context);
  assert.equal(f.storage.get('managementPublishedCollapsed'), false);
  assert.equal(f.storage.get('managementInstalledCollapsed'), false);
  await assert.rejects(f.service.save(f.context, true, true), /preferences unavailable/);
  f.fail(false);
  await f.service.save(f.context, true, true);
  const restarted = managementFixture(f.disk); await restarted.service.load(restarted.context);
  assert.equal(restarted.storage.get('managementPublishedCollapsed'), true);
});

test('appearance survives process restart and system mode releases the native override', async () => {
  const first = appearanceFixture();
  await first.service.save(first.context, 'dark');
  const restarted = appearanceFixture(first.disk);
  await restarted.service.load(restarted.context);
  assert.equal(restarted.storage.get('appearanceMode'), 'dark');
  assert.deepEqual(restarted.native, [1]);
  await restarted.service.save(restarted.context, 'light');
  await restarted.service.save(restarted.context, 'system');
  assert.deepEqual(restarted.native, [1, 0, -1]);
  assert.equal(restarted.disk.get('appearanceMode'), 'system');
  assert.equal(restarted.events.length, 3);
});
test('invalid saved appearance follows the system and a failed save does not change the visible theme', async () => {
  const f = appearanceFixture(new Map([['appearanceMode', 'invalid']]));
  await f.service.load(f.context);
  assert.equal(f.storage.get('appearanceMode'), 'system');
  f.fail();
  await assert.rejects(f.service.save(f.context, 'dark'), /disk full/);
  assert.equal(f.storage.get('appearanceMode'), 'system');
  assert.deepEqual(f.native, [-1]);
});
test('cache measurement cannot follow symlinks or include signing materials and editor drafts', async () => {
  const paths = [];
  const stat = (size, file = true, link = false) => ({ size, isFile: () => file,
    isDirectory: () => !file, isSymbolicLink: () => link });
  const files = { '/sandbox/install-jobs': stat(0, false), '/sandbox/install-jobs/job.hap': stat(4096),
    '/sandbox/install-jobs/symlink.app': stat(100000, true, true), '/sandbox/install-jobs/nested.zip': stat(0, false) };
  const { SettingsCache } = load('data/SettingsCache', { './CatalogCache': { CatalogCache: { size: async () => 2048 } },
    './DeviceArtwork': { DeviceArtwork: { size: async () => 512 } },
    '../jobs/DownloadIconCache': { DownloadIconCache: { size: async () => 1024 } }, '@kit.CoreFileKit': { fileIo: {
    lstat: async file => { paths.push(file); if (!files[file]) throw Error('gone'); return files[file]; },
    listFile: async () => ['job.hap', 'symlink.app', 'nested.zip', 'gone.part', '../identity.pem', 'identity.pem', 'metadata.json']
  } } });
  assert.equal(await SettingsCache.size({ filesDir: '/sandbox' }), 7680);
  assert.ok(paths.every(file => file.startsWith('/sandbox/install-jobs') && !file.includes('..') && !file.endsWith('.pem')));
});
test('cache cleanup combines public catalog cleanup with protected jobs, preserving signing materials and drafts', async () => {
  const calls = [], context = { filesDir: '/sandbox', cacheDir: '/cache' };
  const { SettingsCache } = load('data/SettingsCache', {
    './DeviceArtwork': { DeviceArtwork: { clear: async () => calls.push('device-art') } },
    './CatalogCache': { CatalogCache: { clear: async ctx => { assert.equal(ctx, context); calls.push('catalog'); } } },
    '../jobs/DownloadIconCache': { DownloadIconCache: { clear: async ctx => { assert.equal(ctx, context); calls.push('download-icons'); } } },
    '../jobs/JobStore': { JobStore: { open: async ctx => {
    assert.equal(ctx, context); calls.push('open');
    return { pruneCompleted: async ctx => { assert.equal(ctx, context); calls.push('completed'); },
      pruneSupersededFailures: async ctx => { assert.equal(ctx, context); calls.push('superseded'); },
      cleanupOrphanedPackages: async ctx => { assert.equal(ctx, context); calls.push('orphans'); } };
  } } } });
  await SettingsCache.clean(context);
  assert.deepEqual(calls, ['open', 'completed', 'superseded', 'orphans', 'catalog', 'download-icons', 'device-art']);
});

test('phone icon cache is counted even when there are no installation working files', async () => {
  const { SettingsCache } = load('data/SettingsCache', {
    './CatalogCache': { CatalogCache: { size: async () => 8192 } },
    './DeviceArtwork': { DeviceArtwork: { size: async () => 512 } },
    '../jobs/DownloadIconCache': { DownloadIconCache: { size: async () => 4096 } },
    '@kit.CoreFileKit': { fileIo: { lstat: async () => { throw Error('no install files'); } } }
  });
  assert.equal(await SettingsCache.size({ filesDir: '/sandbox' }), 12800);
});
test('management refresh keeps its indicator until both server lists and device inventory finish', async () => {
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private async refreshManagement(');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const sandbox = {};
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page(), gates = [], calls = [];
  ui.syncFollowing = async () => {};
  for (const name of ['loadMyApps', 'refreshInstalled', 'loadUpdateCatalog']) {
    ui[name] = () => { calls.push(name); return new Promise(resolve => gates.push(resolve)); };
  }
  const run = ui.refreshManagement();
  await ui.refreshManagement(); assert.equal(calls.length, 3);
  gates[0](); gates[1](); await Promise.resolve(); assert.equal(ui.managementRefreshing, true);
  gates[2](); await run; assert.equal(ui.managementRefreshing, false);
});

test('settings material and page back callbacks merge into one return to the home page', () => {
  const source = fs.readFileSync(path.join(root, 'pages/Settings.ets'), 'utf8');
  const start = source.indexOf('  private back(');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const routes = [], timers = [], sandbox = { StorePageMotion: { prepare() {} }, router: { back: route => routes.push(route.url) },
    setTimeout: callback => { timers.push(callback); return timers.length; } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page(); ui.visible = true;
  ui.back(); ui.back();
  assert.equal(ui.visible, false); assert.equal(timers.length, 1);
  assert.equal(routes.length, 0, 'route only after material overlays have been hidden');
  timers[0](); assert.deepEqual(routes, ['pages/Index']);
  const destroyed = new sandbox.Page(); destroyed.back(); destroyed.disposed = true;
  timers[1](); assert.equal(routes.length, 1, 'destroyed pages cannot route later');
});

test('theme saves independent card and image overlay opacity with the appearance', async () => {
  const f = appearanceFixture(new Map([['appearanceMode', 'light']]));
  await f.service.load(f.context);
  await f.background.load(f.context);
  assert.equal(f.background.current().containerOpacity, 100);
  assert.equal(f.background.current().photoMaskOpacity, 0);
  await f.background.save(f.context, 'fern', 'cover', '', 'dark', 0, 37);
  assert.equal(f.native.at(-1), 1);
  const restarted = appearanceFixture(f.disk);
  await restarted.service.load(restarted.context);
  await restarted.background.load(restarted.context);
  assert.equal(restarted.storage.get('appearanceMode'), 'dark');
  assert.equal(restarted.background.current().theme, 'fern');
  assert.equal(restarted.background.current().containerOpacity, 0);
  assert.equal(restarted.background.current().photoMaskOpacity, 37);
  restarted.fail();
  await assert.rejects(restarted.background.save(restarted.context, 'violet', 'cover', '', 'light', 45), /disk full/);
  assert.equal(restarted.background.current().theme, 'fern');
  assert.equal(restarted.background.current().containerOpacity, 0);
  assert.deepEqual(restarted.native, [1]);
  const { Palette } = load('theme/Palette', {});
  assert.equal(Palette.containerPaint('#FFFFFF', 63), '#a1FFFFFF');
  assert.equal(Palette.containerPaint('#80FFFFFF', 50), '#40FFFFFF');
  assert.equal(Palette.containerPaint('#FFFFFF', 100), '#FFFFFF');
});

test('installed application market icons are counted and cleared with other caches', async () => {
  const calls = [], context = {filesDir:'/sandbox',cacheDir:'/cache'};
  const {SettingsCache} = load('data/SettingsCache', {
    './ApplicationIcons': {applicationIcons: dir => {assert.equal(dir,'/cache');return {stats:()=>({bytes:321}),clear:()=>calls.push('icons')};}},
    './CatalogCache':{CatalogCache:{size:async()=>0,clear:async()=>{}}},
    './DeviceArtwork':{DeviceArtwork:{size:async()=>0,clear:async()=>{}}},
    '../jobs/DownloadIconCache':{DownloadIconCache:{size:async()=>0,clear:async()=>{}}},
    '../jobs/JobStore':{JobStore:{open:async()=>({pruneCompleted:async()=>{},pruneSupersededFailures:async()=>{},cleanupOrphanedPackages:async()=>{}})}},
    '@kit.CoreFileKit':{fileIo:{lstat:async()=>{throw Error('missing');}}}
  });
  assert.equal(await SettingsCache.size(context),321);await SettingsCache.clean(context);assert.deepEqual(calls,['icons']);
});
