const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, require: name => mocks[name] || {}, ...globals });
  return exports;
}
function appearanceFixture(disk = new Map()) {
  const storage = new Map(), native = [], events = [];
  let failing = false;
  const { AppearancePreferences } = load('data/AppearancePreferences', {
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: {
      COLOR_MODE_NOT_SET: -1, COLOR_MODE_LIGHT: 0, COLOR_MODE_DARK: 1
    } } },
    '@kit.ArkData': { preferences: { getPreferences: async (_ctx, store) => {
      assert.equal(store, 'qingqi-settings');
      return { get: async (key, fallback) => disk.get(key) ?? fallback,
        put: async (key, value) => disk.set(key, value),
        flush: async () => { if (failing) throw Error('disk full'); } };
    } } }
  }, { AppStorage: { setOrCreate: (key, value) => storage.set(key, value) } });
  const context = { getApplicationContext: () => ({ setColorMode: mode => native.push(mode) }),
    eventHub: { emit: name => events.push(name) } };
  return { service: AppearancePreferences, context, storage, native, events, disk,
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
  const { SettingsCache } = load('data/SettingsCache', { './CatalogCache': { CatalogCache: { size: async () => 2048 } }, '@kit.CoreFileKit': { fileIo: {
    lstat: async file => { paths.push(file); if (!files[file]) throw Error('gone'); return files[file]; },
    listFile: async () => ['job.hap', 'symlink.app', 'nested.zip', 'gone.part', '../identity.pem', 'identity.pem', 'metadata.json']
  } } });
  assert.equal(await SettingsCache.size({ filesDir: '/sandbox' }), 6144);
  assert.ok(paths.every(file => file.startsWith('/sandbox/install-jobs') && !file.includes('..') && !file.endsWith('.pem')));
});
test('cache cleanup combines public catalog cleanup with protected jobs, preserving signing materials and drafts', async () => {
  const calls = [], context = { filesDir: '/sandbox', cacheDir: '/cache' };
  const { SettingsCache } = load('data/SettingsCache', {
    './CatalogCache': { CatalogCache: { clear: async ctx => { assert.equal(ctx, context); calls.push('catalog'); } } },
    '../jobs/JobStore': { JobStore: { open: async ctx => {
    assert.equal(ctx, context); calls.push('open');
    return { pruneCompleted: async ctx => { assert.equal(ctx, context); calls.push('completed'); },
      cleanupOrphanedPackages: async ctx => { assert.equal(ctx, context); calls.push('orphans'); } };
  } } } });
  await SettingsCache.clean(context);
  assert.deepEqual(calls, ['open', 'completed', 'orphans', 'catalog']);
});

test('phone icon cache is counted even when there are no installation working files', async () => {
  const { SettingsCache } = load('data/SettingsCache', {
    './CatalogCache': { CatalogCache: { size: async () => 8192 } },
    '@kit.CoreFileKit': { fileIo: { lstat: async () => { throw Error('no install files'); } } }
  });
  assert.equal(await SettingsCache.size({ filesDir: '/sandbox' }), 8192);
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

test('appearance selection closes the menu before applying the theme and Back dismisses it first', () => {
  const source = fs.readFileSync(path.join(root, 'pages/Settings.ets'), 'utf8');
  const methods = ['selectAppearance', 'back'].map(name => {
    const at = source.indexOf('  private ' + name + '(');
    return source.slice(at, source.indexOf('\n  }', at) + 4);
  }).join('\n');
  const timers = [], changes = [], sandbox = { StorePageMotion: { prepare() {} }, router: { back() {} },
    setTimeout: fn => { timers.push(fn); return timers.length; } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, sandbox);
  const ui = new sandbox.Page(); ui.appearanceMenuOpen = true;
  ui.changeAppearance = mode => changes.push({ mode, open: ui.appearanceMenuOpen });
  ui.selectAppearance('dark'); assert.deepEqual(changes, [{ mode: 'dark', open: false }]);
  ui.appearanceMenuOpen = true; ui.back(); assert.equal(ui.appearanceMenuOpen, false); assert.equal(timers.length, 0);
  ui.back(); assert.equal(timers.length, 1);
});
