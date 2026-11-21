const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
const tick = () => new Promise(setImmediate);
function ok(data, etag = 'revision') { return { responseCode: 200, header: { ETag: etag }, result: JSON.stringify({ ok: true, data }) }; }
function fixture(values = new Map()) {
  const f = { values, calls: [], queue: [], now: 100000, decodes: [], destroyed: 0,
    deviceInfo: { marketName: '', productModel: '' } };
  const prefs = { get: async (key, fallback) => values.get(key) ?? fallback,
    put: async (key, value) => values.set(key, value), flush: async () => {}, clear: async () => values.clear() };
  const modules = new Map();
  const mocks = {
    './AccountService': { AccountService: { current: async () => f.account, configure() {}, refresh: async account => account } },
    './StoreBuildConfig': {StoreBuildConfig:{configured:true,baseUrl:'https://store.example.invalid',publicKeySha256:'a'.repeat(43)+'=',caData:''}},
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
    '@kit.ArkData': { preferences: { getPreferences: async () => prefs } },
    '@kit.BasicServicesKit': { deviceInfo: f.deviceInfo },
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
  f.cache = load('data/CatalogCache').CatalogCache;
  f.StoreClient = StoreClient;
  const context = { resourceManager: { getRawFileContentSync: () => new Uint8Array() } };
  f.client = new StoreClient(context); f.another = () => new StoreClient(context);
  return f;
}
test('rapid detail entry shares requests across clients and reuses a bounded 30-second response', async () => {
  const f = fixture(), gate = deferred(); f.queue.push(gate.promise);
  const a = f.client.appDetail(42), b = f.another().appDetail(42);
  await tick();
  assert.equal(f.calls.length, 1); gate.resolve(ok({ id: 42, display_name: 'App' })); await Promise.all([a, b]);
  assert.equal((await f.client.appDetail(42)).displayName, 'App'); assert.equal(f.calls.length, 1);
  f.now += 30001; f.queue.push(ok({ id: 42, display_name: 'Updated' }, 'next'));
  assert.equal((await f.client.appDetail(42)).displayName, 'Updated'); assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].options.header['If-None-Match'], 'revision');
});

test('personal detail fallback sends account credentials without entering public cache or sharing an identity', async () => {
  const f=fixture();f.account={jwtToken:'alice-token',accessToken:'alice-access'};
  const denied=()=>({responseCode:404,result:JSON.stringify({ok:false,error:{message:'应用不存在'}})});
  f.queue.push(denied(),ok({id:42,distribution_region:'overseas',display_name:'Owned app'}));
  assert.equal((await f.client.appDetail(42)).overseas,true);
  assert.equal(f.calls[0].options.header.Authorization,undefined);
  assert.equal(f.calls[1].options.header.Authorization,'Bearer alice-token');
  f.account=undefined;f.queue.push(denied());
  await assert.rejects(f.another().appDetail(42),/应用不存在/);
  assert.equal(f.calls.length,3,'the private result must not refill the public cache');
});

test('personal inventory submission stays authenticated and does not inject apps into discovery responses',async()=>{
  const f=fixture();const account={jwtToken:'alice-token',accessToken:'alice-access'};
  f.queue.push(ok({items:[{id:42,distribution_region:'overseas'}]}),ok({items:[],page:1,page_size:30,total:0}));
  assert.equal((await f.client.personalCatalog(account,'device1',[{app_id:42,bundle_name:'com.example.app',version_code:1}]))[0].overseas,true);
  assert.equal(f.calls[0].options.header.Authorization,'Bearer alice-token');
  assert.equal(JSON.parse(f.calls[0].options.extraData).client_id,'device1');
  assert.equal((await f.client.listApps()).items.length,0);
});

test('reply actions address a single review thread and use the server page and permissions', async () => {
  const f = fixture();
  const account = { jwtToken: 'alice-token', accessToken: 'alice-access' };
  f.queue.push(ok({ replies_supported: true, items: [{ id: 7, reply_count: 2 }] }),
    ok({ total: 3, page: 1, page_size: 10, items: [{ id: 8, created_at: 123, body: 'Reply', can_delete: true }] }),
    ok({ total: 2, page: 1, page_size: 10, items: [] }));
  const reviews = await f.client.listReviews(42);
  assert.equal(reviews.repliesSupported, true);
  assert.equal(reviews.items[0].replyCount, 2);
  const thread = await f.client.postReviewReply(42, 7, 'Reply', account);
  assert.equal(thread.total, 3);
  assert.equal(thread.items[0].canDelete, true);
  assert.equal(thread.items[0].updatedAt, '123');
  assert.deepEqual(JSON.parse(f.calls[1].options.extraData), { body: 'Reply' });
  assert.equal(f.calls[1].options.header.Authorization, 'Bearer alice-token');
  assert.match(f.calls[1].url, /\/apps\/42\/reviews\/7\/replies\?order=asc&page_size=3$/);
  const deleted = await f.client.deleteReviewReply(42, 7, 8, 2, account);
  assert.equal(deleted.page, 1);
  assert.match(f.calls[2].url, /\/apps\/42\/reviews\/7\/replies\/8\?order=asc&page=2$/);
});

test('comments publish and read only the optional public device model', async () => {
  const f = fixture();
  const account = { jwtToken: 'alice-token', accessToken: 'alice-access' };
  Object.assign(f.deviceInfo, { marketName: '  HUAWEI Pura X  ', productModel: 'ALT-00', serial: 'private' });
  f.queue.push(ok({ items: [{ id: 7, device_model: 'HUAWEI Pura X' }, { id: 8 }] }),
    ok({ items: [{ id: 9, device_model: 'ALT-00' }] }));
  const reviews = await f.client.postReview(42, 5, 'Review', account);
  assert.equal(reviews.items[0].deviceModel, 'HUAWEI Pura X');
  assert.equal(reviews.items[1].deviceModel, '');
  assert.deepEqual(JSON.parse(f.calls[0].options.extraData), { stars: 5, body: 'Review', device_model: 'HUAWEI Pura X' });
  f.deviceInfo.marketName = 'Unknown';
  const replies = await f.client.postReviewReply(42, 7, 'Reply', account);
  assert.equal(replies.items[0].deviceModel, 'ALT-00');
  assert.deepEqual(JSON.parse(f.calls[1].options.extraData), { body: 'Reply', device_model: 'ALT-00' });
});

test('README expansion coalesces in-flight reads and fetches fresh documents on the next expansion', async () => {
  const f=fixture(),gate=deferred();f.queue.push(gate.promise);
  const a=f.client.repositoryReadme(3),b=f.another().repositoryReadme(3);
  await tick();
  assert.equal(f.calls.length,1);gate.resolve(ok({found:true,html:'<h1>README</h1>',source_url:'https://github.com/a/b'}));
  const [first,second]=await Promise.all([a,b]);assert.equal(first.html,second.html);
  f.queue.push(ok({found:false,html:''}));assert.equal((await f.client.repositoryReadme(4)).found,false);
  assert.equal(f.calls.length,2);
  f.queue.push(ok({found:true,html:'<h1>Next</h1>'},'next'));
  assert.equal((await f.client.repositoryReadme(3)).html,'<h1>Next</h1>');assert.equal(f.calls.length,3);
  assert.equal(f.calls[2].options.header['If-None-Match'], undefined);
});

test('README retry recovers without invalidating installed application metadata', async () => {
  const f=fixture();f.queue.push(ok({id:3,display_name:'App'}),Error('README timeout'),ok({found:true,html:'ok'}));
  await f.client.appDetail(3);await assert.rejects(f.client.repositoryReadme(3),/timeout/);
  assert.equal((await f.client.repositoryReadme(3,true)).html,'ok');
  assert.equal((await f.client.appDetail(3)).displayName,'App');assert.equal(f.calls.length,3);
});
test('concurrent README requests coalesce by UI language without mixing translated content', async () => {
  const f=fixture(), gate=deferred();f.queue.push(gate.promise,ok({found:true,html:'English'}));
  const chinese=f.client.repositoryReadme(3,false,'zh');
  const sameChinese=f.another().repositoryReadme(3,false,'zh');
  const english=f.client.repositoryReadme(3,false,'en');
  await tick();
  assert.equal(f.calls.length,2);
  assert.ok(f.calls[0].url.endsWith('/readme?lang=zh'));
  assert.ok(f.calls[1].url.endsWith('/readme?lang=en'));
  gate.resolve(ok({found:true,html:'中文'}));
  assert.deepEqual((await Promise.all([chinese,sameChinese,english])).map(value=>value.html),['中文','中文','English']);
  assert.equal(f.calls.length,2);
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
  const f = fixture(), old = deferred(); f.queue.push(old.promise, ok({ status: 'done' }), ok({ id: 42, display_name: 'New' }), { responseCode: 304 });
  const loading = f.client.appDetail(42); await f.client.refreshApp(42);
  assert.equal((await f.client.appDetail(42)).displayName, 'New');
  old.resolve(ok({ id: 42, display_name: 'Old' })); await loading;
  assert.equal((await f.client.appDetail(42)).displayName, 'New'); assert.equal(f.calls.length, 4);
});
test('a late invalidated detail response cannot roll discovery and management back through viewedApps', async () => {
  const f=fixture(), old=deferred();
  f.queue.push(old.promise,ok({status:'done'}),ok({id:42,display_name:'New',updated_at:200}),{responseCode:304});
  const loading=f.client.appDetail(42);await f.client.refreshApp(42);
  assert.equal((await f.client.appDetail(42)).updatedAt,'200');
  old.resolve(ok({id:42,display_name:'Old',updated_at:100}));await loading;
  const viewed=f.StoreClient.consumeViewedApps();
  assert.equal(viewed.length,1);assert.equal(viewed[0].displayName,'New');assert.equal(viewed[0].updatedAt,'200');
  assert.equal(f.StoreClient.consumeViewedApps().length,0);
});
test('a force detail read cannot replace a newer viewed snapshot with an older server revision',async()=>{
  const f=fixture();f.queue.push(ok({id:42,display_name:'New',updated_at:200}),ok({id:42,display_name:'Old',updated_at:100}));
  await f.client.appDetail(42);await f.client.appDetail(42,true);
  const viewed=f.StoreClient.consumeViewedApps();assert.equal(f.calls.length,2);assert.equal(viewed[0].updatedAt,'200');
});
test('missing and malformed detail revisions cannot replace a known fresh viewed snapshot',async()=>{
  for(const revision of ['', 'invalid', 0, -1]) {
    const f=fixture();f.queue.push(ok({id:42,display_name:'New',updated_at:200}),
      ok({id:42,display_name:'Unknown',updated_at:revision}));
    await f.client.appDetail(42);await f.client.appDetail(42,true);
    const viewed=f.StoreClient.consumeViewedApps();assert.equal(viewed[0].updatedAt,'200');
  }
});
test('explicit metadata refresh bypasses 30-second cache reuse and still uses conditional requests',async()=>{
  const f=fixture();f.queue.push(ok({id:42,updated_at:100}),ok({id:42,updated_at:200}),
    ok({items:[],total:0}),ok({items:[{tag:'v2',name:'Version 2',assets:[]}],total:1}));
  await f.client.appDetail(42);assert.equal((await f.client.appDetail(42,true)).updatedAt,'200');
  await f.client.listReleases(42,1,20,false);
  assert.equal((await f.client.listReleases(42,1,20,false,true)).items[0].tag,'v2');
  assert.equal(f.calls.length,4);assert.equal(f.calls[1].options.header['If-None-Match'],'revision');
  assert.equal(f.calls[3].options.header['If-None-Match'],'revision');
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
test('original icon export reuses source bytes from the matching revision without decoding or resizing', async () => {
  const original = Buffer.from([42, 1, 2, 3, 4, 5]);
  const f = fixture(new Map([['icon-42', JSON.stringify({ id: '42', rev: 'one', data: original.toString('base64') })]]));
  const bytes = await f.client.originalIconBytes({ id: 42, iconUrl: '/api/v1/apps/42/icon', iconRev: 'one' });
  assert.deepEqual(Buffer.from(bytes), original); assert.equal(f.calls.length, 0); assert.equal(f.decodes.length, 0);
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

test('clearing during an icon download preserves its display result without refilling disk', async () => {
  const f = fixture(), gate = deferred();
  const app = { id: 42, iconUrl: '/api/v1/apps/42/icon', iconRev: 'one' };
  f.queue.push(gate.promise);
  const reading = f.client.appIcon(app);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.length, 1);
  await f.cache.clear({});
  gate.resolve({ responseCode: 200, result: Uint8Array.from([42]).buffer });
  assert.equal((await reading).image, true);
  assert.equal(f.values.size, 0, 'the old download cannot persist after explicit cleanup');
  f.queue.push({ responseCode: 200, result: Uint8Array.from([42, 2]).buffer });
  assert.equal((await f.another().appIcon(app)).image, true);
  assert.equal(JSON.parse(f.values.get('icon-42')).data, 'KgI=');
});

test('new icon requests after clearing do not borrow an old generation in-flight cache writer', async () => {
  const f = fixture(), old = deferred(), fresh = deferred();
  const app = { id: 42, iconUrl: '/api/v1/apps/42/icon', iconRev: 'one' };
  f.queue.push(old.promise, fresh.promise);
  const before = f.client.appIcon(app);
  await new Promise(resolve => setImmediate(resolve));
  await f.cache.clear({});
  const after = f.another().appIcon(app);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.length, 2);
  fresh.resolve({ responseCode: 200, result: Uint8Array.from([42, 2]).buffer });
  assert.equal((await after).image, true);
  old.resolve({ responseCode: 200, result: Uint8Array.from([42, 1]).buffer });
  assert.equal((await before).image, true);
  assert.equal(JSON.parse(f.values.get('icon-42')).data, 'KgI=', 'old completion cannot overwrite fresh bytes');
});
