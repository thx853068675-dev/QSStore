const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const names = ['managementIconApps', 'managedIconFor', 'isCurrentManagementIcon', 'loadManagementIcon',
  'loadManagementIcons', 'runManagementIconBatches', 'jobIcon'];
const methods = names.map(name => {
  const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
});
const code = ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;
const tick = () => new Promise(setImmediate);
const app = id => ({ id, iconRev: 'r1', iconUrl: '/icon/' + id });
const bytes = value => Uint8Array.from([value]).buffer;
function fixture(count = 1) {
  const f = { catalog: Array.from({ length: count }, (_, i) => app(i + 1)), disk: new Map(),
    requests: [], released: [], active: 0, peak: 0, decodes: 0, saves: [] };
  f.fetch = async a => bytes(a.id);
  const box = { AppIcon: class {}, CachedIcon: class {}, getContext: () => ({}),
    ForegroundIdle: { wait: () => f.displayGate || Promise.resolve() },
    StoreClient: class { async appIconBytes(a) {
      f.requests.push(a.id); f.peak = Math.max(f.peak, ++f.active);
      try { return await f.fetch(a); } finally { f.active--; }
    } },
    CatalogCache: { async loadIcons(_, apps) {
      return new Map(apps.filter(a => f.disk.get(a.id)?.rev === a.iconRev)
        .map(a => [a.id, f.disk.get(a.id).bytes]));
    }, iconWithinLimit: () => true, async saveIcons(_, rows) {
      for (const row of rows) {
        f.saves.push(row); f.disk.set(Number(row.id), { rev: row.rev,
          bytes: Uint8Array.from(Buffer.from(row.data, 'base64')).buffer });
      }
    } },
    util: { Base64Helper: class { encodeToStringSync(value) { return Buffer.from(value).toString('base64'); } } },
    image: { createImageSource(data) { return { async createPixelMap(options) {
      f.decodes++; assert.equal(options.desiredSize.width, 192);
      if (new Uint8Array(data)[0] === 0) throw Error('broken image');
      return { value: new Uint8Array(data)[0], async release() { f.released.push('pixels'); } };
    }, async release() { f.released.push('source'); } }; } }
  };
  vm.runInNewContext(code, box);
  f.ui = Object.assign(new box.Page(), { apps: [], appIcons: [], managementIcons: [], localIcons: [],
    myApps: [], pendingJobs: [], managementIconFlights: new Map(), activeQuery: 'unrelated-search',
    catalogLookup: () => { const key = JSON.stringify(f.catalog); if (f.lookupKey !== key) { f.lookupKey = key; f.lookup = {}; } return f.lookup; },
    allInstalledJobs: () => f.catalog.map(a => ({ id: 'job-' + a.id, appId: a.id, bundleName: 'com.example.app' + a.id })),
    catalogForJob: job => f.catalog.find(a => a.id === job.appId), catalogApp: id => f.catalog.find(a => a.id === id) });
  return f;
}
test('Management loads installed icons outside Discover and retains them when search results reset', async () => {
  const f = fixture(3); await f.ui.loadManagementIcons();
  assert.deepEqual(f.requests, [1, 2, 3]);
  const before = f.ui.jobIcon(f.ui.allInstalledJobs()[1]);
  assert.equal(before.value, 2);
  f.ui.apps = [app(99)]; f.ui.appIcons = []; f.ui.activeQuery = 'another-search';
  await f.ui.loadManagementIcons();
  assert.equal(f.ui.jobIcon(f.ui.allInstalledJobs()[1]), before);
  assert.equal(f.requests.length, 3);
});
test('a cold Management start restores matching cached icons without API requests', async () => {
  const f = fixture(2); f.catalog.forEach(a => f.disk.set(a.id, { rev: a.iconRev, bytes: bytes(a.id) }));
  await f.ui.loadManagementIcons();
  assert.equal(f.ui.managementIcons.length, 2); assert.equal(f.requests.length, 0);
  assert.equal(f.ui.apps.length, 0);
});

test('a decoded icon waits for interaction to end and rechecks its revision before publication', async () => {
  const f = fixture(); let release;
  f.displayGate = new Promise(resolve => release = resolve);
  const work = f.ui.loadManagementIcons(); await tick();
  assert.equal(f.decodes, 1); assert.equal(f.ui.managementIcons.length, 0);
  f.catalog[0] = { ...app(1), iconRev: 'r2' };
  release(); await work;
  assert.equal(f.ui.managementIcons.length, 0);
  assert(f.released.includes('pixels'));
});
test('overlapping loads share requests and limit network/decode work to four workers', async () => {
  const f = fixture(12); let release;
  const gate = new Promise(r => release = r); f.fetch = async a => { await gate; return bytes(a.id); };
  const first = f.ui.loadManagementIcons(), joined = f.ui.loadManagementIcons();
  await tick(); assert.equal(f.requests.length, 4); release(); await Promise.all([first, joined]);
  assert.equal(f.requests.length, 12); assert.equal(f.peak, 4);
  assert.equal(f.ui.managementIconFlights.size, 0);
});
test('failed new revisions retain the previous icon and are retried on the next load', async () => {
  const f = fixture(); const old = { value: 'old' };
  f.ui.managementIcons = [{ id: 1, rev: 'r0', pixels: old }];
  f.fetch = async () => { throw Error('offline'); }; await f.ui.loadManagementIcons();
  assert.equal(f.ui.managedIconFor(f.catalog[0]), old); assert.equal(f.requests.length, 2);
  f.fetch = async () => bytes(1); await f.ui.loadManagementIcons();
  assert.equal(f.ui.managedIconFor(f.catalog[0]).value, 1); assert.equal(f.saves[0].rev, 'r1');
});
test('an obsolete revision is discarded while a search change cannot cancel current Management icons', async () => {
  const f = fixture(); let release;
  f.fetch = () => new Promise(r => release = r);
  const old = f.ui.loadManagementIcons(); await tick();
  f.catalog[0] = { ...app(1), iconRev: 'r2' }; release(bytes(1)); await old;
  assert.equal(f.ui.managementIcons.length, 0); assert(f.released.includes('pixels'));
  f.fetch = async () => bytes(2); f.ui.activeQuery = 'changed'; await f.ui.loadManagementIcons();
  assert.equal(f.ui.managementIcons[0].rev, 'r2'); assert.equal(f.ui.managementIcons[0].pixels.value, 2);
});
test('matching Discover pixels are shared and uploaded/pending apps are loaded only once', async () => {
  const f = fixture(); const shared = { id: 1, rev: 'r1', pixels: { value: 'shared' } };
  f.ui.appIcons = [shared]; f.ui.myApps = [app(1), app(2)];
  f.catalog.push(app(2)); f.ui.pendingJobs = [{ appId: 2 }];
  await f.ui.loadManagementIcons();
  assert.equal(f.ui.managementIcons.find(a => a.id === 1), shared);
  assert.deepEqual(f.requests, [2]); assert.equal(f.decodes, 1);
});
test('a broken disk image falls back to fresh bytes and repairs its cache record', async () => {
  const f = fixture(); f.disk.set(1, { rev: 'r1', bytes: bytes(0) });
  await f.ui.loadManagementIcons();
  assert.deepEqual(f.requests, [1]); assert.equal(f.ui.managedIconFor(f.catalog[0]).value, 1);
  assert.equal(new Uint8Array(f.disk.get(1).bytes)[0], 1);
});
test('new installed apps join the current batch without exceeding the four-request limit', async () => {
  const f = fixture(4); let release;
  const gate = new Promise(r => release = r); f.fetch = async a => { await gate; return bytes(a.id); };
  const current = f.ui.loadManagementIcons(); await tick();
  f.catalog.push(app(5), app(6)); const joined = f.ui.loadManagementIcons(); await tick();
  assert.equal(current, joined); assert.equal(f.requests.length, 4);
  release(); await joined;
  assert.equal(f.requests.length, 6); assert.equal(f.peak, 4);
  assert.equal(f.ui.managementIcons.length, 6);
});
