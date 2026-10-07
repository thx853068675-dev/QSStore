const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function ok(data, etag = 'revision') { return { responseCode: 200, header: { ETag: etag }, result: JSON.stringify({ ok: true, data }) }; }
function fixture(values = new Map()) {
  const f = { values, calls: [], queue: [], now: 100000, decodes: [], destroyed: 0 };
  const prefs = { get: async (key, fallback) => values.get(key) ?? fallback,
    put: async (key, value) => values.set(key, value), flush: async () => {} };
  const modules = new Map();
  const mocks = {
    '@kit.ArkData': { preferences: { getPreferences: async () => prefs } },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeToString(bytes) { return new TextDecoder().decode(bytes); } }, Base64Helper: class {
      decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); }
      encodeToStringSync(value) { return Buffer.from(value).toString('base64'); }
    } } },
    '@kit.ImageKit': { image: { createImageSource(bytes) { return {
      async createPixelMap() { f.decodes.push(bytes); if (new Uint8Array(bytes)[0] !== 42) throw Error('bad image'); return { image: true }; },
      async release() {}
    }; } } },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' },
      HttpDataType: { ARRAY_BUFFER: 1 }, createHttp: () => ({ async request(url, options) {
        f.calls.push({ url, options }); const next = f.queue.shift(); if (next instanceof Error) throw next; return await next;
      }, destroy() { f.destroyed++; } }) } }
  };
  function load(file) {
    if (modules.has(file)) return modules.get(file);
    const exports = {}; modules.set(file, exports);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInNewContext(code, { exports, ArrayBuffer, Uint8Array, Date: { now: () => f.now }, console,
      require: name => mocks[name] || (name.startsWith('.') ? load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name))) : {}) });
    return exports;
  }
  const { StoreClient } = load('data/StoreClient');
  const context = { resourceManager: { getRawFileContentSync: () => new Uint8Array() } };
  f.client = new StoreClient(context); f.another = () => new StoreClient(context);
  return f;
}
test('rapid detail entry shares requests across clients and reuses a bounded 30-second response', async () => {
  const f = fixture(), gate = deferred(); f.queue.push(gate.promise);
  const a = f.client.appDetail(42), b = f.another().appDetail(42);
  assert.equal(f.calls.length, 1); gate.resolve(ok({ id: 42, display_name: 'App' })); await Promise.all([a, b]);
  assert.equal((await f.client.appDetail(42)).displayName, 'App'); assert.equal(f.calls.length, 1);
  f.now += 30001; f.queue.push(ok({ id: 42, display_name: 'Updated' }, 'next'));
  assert.equal((await f.client.appDetail(42)).displayName, 'Updated'); assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].options.header['If-None-Match'], 'revision');
});
test('release caching separates application, channel and page while catalog refresh remains fresh', async () => {
  const f = fixture(); f.queue.push(...Array.from({ length: 5 }, () => ok({ items: [], page: 1, total: 0 })));
  await f.client.listReleases(1, 1, 20, false); await f.client.listReleases(1, 1, 20, true);
  await f.client.listReleases(1, 2, 20, true); await f.client.listReleases(1, 1, 20, false);
  assert.equal(f.calls.length, 3);
  await f.client.listApps(); await f.client.listApps(); assert.equal(f.calls.length, 4);
  await f.client.listApps(1, 30, 'updated', '', '', true); assert.equal(f.calls.length, 5);
});
test('failed reads clear their shared request and do not poison the next detail entry', async () => {
  const f = fixture(); f.queue.push(Error('timeout'), ok({ id: 42 }));
  await assert.rejects(f.client.appDetail(42), /timeout/);
  assert.equal((await f.another().appDetail(42)).id, 42); assert.equal(f.calls.length, 2); assert.equal(f.destroyed, 2);
});
test('repository refresh invalidates old responses and an older in-flight result cannot overwrite fresh data', async () => {
  const f = fixture(), old = deferred(); f.queue.push(old.promise, ok({ status: 'done' }), ok({ id: 42, display_name: 'New' }));
  const loading = f.client.appDetail(42); await f.client.refreshApp(42);
  assert.equal((await f.client.appDetail(42)).displayName, 'New');
  old.resolve(ok({ id: 42, display_name: 'Old' })); await loading;
  assert.equal((await f.client.appDetail(42)).displayName, 'New'); assert.equal(f.calls.length, 3);
});
test('detail icons reuse the persistent phone cache across restart and replace only changed revisions', async () => {
  const values = new Map([['icon-42', JSON.stringify({ id: '42', rev: 'one', data: 'Kg==' })]]);
  const app = { id: 42, iconUrl: '/api/v1/apps/42/icon', iconRev: 'one' };
  const f = fixture(values); assert.equal((await f.client.appIcon(app)).image, true); assert.equal(f.calls.length, 0);
  const restarted = fixture(values); assert.equal((await restarted.client.appIcon(app)).image, true); assert.equal(restarted.calls.length, 0);
  restarted.queue.push({ responseCode: 200, result: Uint8Array.from([42, 1]).buffer });
  await restarted.client.appIcon({ ...app, iconRev: 'two' });
  assert.equal(restarted.calls.length, 1); assert.equal(JSON.parse(values.get('icon-42')).rev, 'two');
});
test('a corrupt icon is fetched once again and concurrent detail pages share that download', async () => {
  const f = fixture(new Map([['icon-42', JSON.stringify({ id: '42', rev: 'one', data: 'AA==' })]]));
  const app = { id: 42, iconUrl: '/api/v1/apps/42/icon', iconRev: 'one' }, gate = deferred(); f.queue.push(gate.promise);
  const a = f.client.appIcon(app), b = f.another().appIcon(app);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.calls.length, 1);
  gate.resolve({ responseCode: 200, result: Uint8Array.from([42]).buffer });
  const results = await Promise.all([a, b]); assert.ok(results.every(row => row.image));
  assert.equal(f.calls.length, 1); assert.equal(JSON.parse(f.values.get('icon-42')).data, 'Kg==');
});
