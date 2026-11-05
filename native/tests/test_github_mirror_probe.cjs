const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets/data');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
const official = 'https://github.com/owner/repo/releases/download/v1.2/app-1.2.hap';
const app = url => ({ latestAssets: [{ url }], latestAsset: undefined });
const response = (code = 200, header = { 'Content-Type': 'application/octet-stream' }, result = '') => ({ responseCode: code, header, result });
function fixture() {
  const f = { now: 10000, timers: new Map(), nextTimer: 0, allowed: true, caches: new Map(), cacheReads: [],
    cacheGate: undefined, requests: [], response: response(), httpGate: undefined, createError: undefined };
  const modules = new Map();
  const mocks = {
    '@kit.ArkTS': { url: { URL } }, '@kit.AbilityKit': {}, '@kit.ArkData': {},
    './CatalogApp': {},
    './PrivacyConsent': { PrivacyConsent: { assertBusinessAllowed: () => {
      if (!f.allowed) throw Error('ACCOUNT_PRIVATE_SECRET');
    } } },
    './CatalogCache': { CatalogCache: { load: async (_context, sort, direction) => {
      f.cacheReads.push([sort, direction]);
      if (f.cacheGate) await f.cacheGate.promise;
      return f.caches.get(sort + '-' + direction) ?? [];
    } } },
    '@kit.NetworkKit': { http: { RequestMethod: { HEAD: 'HEAD' }, createHttp: () => {
      if (f.createError) throw f.createError;
      const call = { destroyed: 0, options: undefined, url: '' }; f.requests.push(call);
      return { request: async (url, options) => {
        call.url = url; call.options = options;
        if (f.httpGate) return f.httpGate.promise;
        return f.response;
      }, destroy: () => { call.destroyed++; } };
    } } }
  };
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {}; modules.set(name, exports);
    const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
    vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
    } }).outputText, { exports, Date: { now: () => f.now },
      setTimeout: (run, delay) => { const id = ++f.nextTimer; f.timers.set(id, { run, at: f.now + delay }); return id; },
      clearTimeout: id => f.timers.delete(id), require: name => mocks[name] ?? load(name.replace(/^\.\//, '')) });
    return exports;
  }
  f.probe = new (load('GitHubMirrorProbe').GitHubMirrorProbe)();
  f.check = prefix => f.probe.check({ filesDir: '/test/app' }, prefix ?? 'https://mirror.example/proxy');
  f.advance = async ms => {
    f.now += ms;
    for (const [id, timer] of [...f.timers]) if (timer.at <= f.now) { f.timers.delete(id); timer.run(); }
    await tick();
  };
  return f;
}

test('a cached real release is checked with one bounded HEAD and no credentials, private CA, body or API discovery', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]);
  const result = await f.check();
  assert.equal(result.state, 'success'); assert.equal(result.message, '连接检查通过');
  assert.deepEqual(f.cacheReads, [['stars', 'desc']]);
  assert.equal(f.requests.length, 1);
  const call = f.requests[0]; assert.equal(call.url, 'https://mirror.example/proxy/' + official);
  assert.equal(call.options.method, 'HEAD'); assert.equal(call.options.usingCache, false);
  assert.ok(call.options.connectTimeout > 0 && call.options.connectTimeout <= 6000);
  assert.ok(call.options.readTimeout > 0 && call.options.readTimeout <= 6000);
  assert.ok(call.options.maxLimit <= 1024); assert.equal(call.destroyed, 1);
  for (const field of ['header', 'body', 'extraData', 'caPath', 'caData', 'certificatePinning', 'clientCert', 'serverAuthentication']) {
    assert.equal(Object.hasOwn(call.options, field), false, field);
  }
  assert.equal(f.timers.size, 0);
});
test('no cached target remains unconfirmed without creating any request', async () => {
  const f = fixture();
  f.caches.set('stars-desc', [app('https://gitee.com/a/r/releases/download/v1/app.hap'),
    app('https://github.com.evil/a/r/releases/download/v1/app.hap'), app('https://github.com/a/r/releases')]);
  const result = await f.check();
  assert.equal(result.state, 'unconfirmed'); assert.equal(result.message, '地址格式有效，下载时检验');
  assert.equal(f.requests.length, 0); assert.equal(f.cacheReads.length, 6); assert.equal(f.timers.size, 0);
});
test('other locally saved sorting scopes and the singular latestAsset may supply the target', async () => {
  const f = fixture();
  f.caches.set('downloads-desc', [{ latestAssets: [], latestAsset: { url: official } }]);
  const result = await f.check(); assert.equal(result.state, 'success');
  assert.deepEqual(f.cacheReads, [['stars', 'desc'], ['stars', 'asc'], ['downloads', 'desc']]);
  assert.equal(f.requests.length, 1);
});
test('encoded package-selector values are removed without decoding or altering the actual asset URL', async () => {
  const f = fixture(), zip = 'https://github.com/owner/repo/releases/download/v1.2/%E4%BD%A0%E5%A5%BD.zip';
  f.caches.set('stars-desc', [app(zip + '#qingqi-package=%E6%A8%A1%E5%9D%97%2Fentry.hap')]);
  await f.check(); assert.equal(f.requests[0].url, 'https://mirror.example/proxy/' + zip);
  assert.equal(f.requests[0].url.includes('qingqi-package'), false);
});
test('query-bearing releases are skipped without forwarding URL credentials to the mirror', async () => {
  const f = fixture();
  f.caches.set('stars-desc', [app(official + '?access_token=TEST_ONLY#qingqi-package=entry.hap'),
    app(official + '?download=1')]);
  const unconfirmed = await f.check();
  assert.equal(unconfirmed.state, 'unconfirmed'); assert.equal(f.requests.length, 0);
  f.caches.set('downloads-desc', [app(official + '#qingqi-package=entry.hap')]);
  const confirmed = await f.check();
  assert.equal(confirmed.state, 'success'); assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].url, 'https://mirror.example/proxy/' + official);
  assert.equal(f.requests[0].url.includes('TEST_ONLY'), false);
});
test('HTTP failures warn but unsupported HEAD and HTML responses are not declared unavailable or successful', async () => {
  for (const code of [404, 429, 503]) {
    const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.response = response(code);
    const result = await f.check(); assert.equal(result.state, 'warning'); assert.match(result.message, new RegExp('HTTP ' + code));
    assert.equal(f.requests[0].destroyed, 1);
  }
  for (const reply of [response(405), response(501), response(200, { 'content-type': 'text/html; charset=UTF-8' }),
    response(200, { 'CONTENT-TYPE': 'application/xhtml+xml' }), response(200, {}, '<!DOCTYPE html><html>challenge</html>')]) {
    const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.response = reply;
    const result = await f.check(); assert.equal(result.state, 'unconfirmed'); assert.equal(f.requests[0].destroyed, 1);
  }
});
test('a hanging HTTP check finishes at eight seconds and destroys the request even when the transport never settles', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.httpGate = deferred();
  const checking = f.check(); await tick(); let settled = false; checking.then(() => { settled = true; });
  await f.advance(7999); assert.equal(settled, false);
  await f.advance(1); const result = await checking;
  assert.equal(result.state, 'warning'); assert.match(result.message, /超时/); assert.equal(f.requests[0].destroyed, 1);
  f.httpGate.resolve(response()); await tick(); assert.equal(f.requests[0].destroyed, 1); assert.equal(f.timers.size, 0);
});
test('the total timeout includes a hanging local cache read and its late completion never opens HTTP', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.cacheGate = deferred();
  const checking = f.check(); await tick(); await f.advance(8000);
  assert.match((await checking).message, /超时/); assert.equal(f.requests.length, 0);
  f.cacheGate.resolve(); await tick(); assert.equal(f.requests.length, 0); assert.equal(f.cacheReads.length, 1);
});
test('slow cache access leaves only the remaining timeout budget for HTTP', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.cacheGate = deferred(); f.httpGate = deferred();
  const checking = f.check(); await tick(); await f.advance(5000);
  f.cacheGate.resolve(); await tick();
  assert.equal(f.requests[0].options.connectTimeout, 3000); assert.equal(f.requests[0].options.readTimeout, 3000);
  await f.advance(3000); assert.match((await checking).message, /超时/); assert.equal(f.requests[0].destroyed, 1);
});
test('cancelling during a cache read resolves immediately and prevents later requests', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.cacheGate = deferred();
  const checking = f.check(); await tick(); f.probe.cancel();
  assert.equal((await checking).state, 'unconfirmed'); assert.equal(f.requests.length, 0); assert.equal(f.timers.size, 0);
  f.cacheGate.resolve(); await tick(); assert.equal(f.requests.length, 0);
});
test('cancelling HTTP and starting another check keeps old completion from destroying the new request', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); const old = deferred(); f.httpGate = old;
  const first = f.check(); await tick(); f.probe.cancel();
  assert.match((await first).message, /取消/); assert.equal(f.requests[0].destroyed, 1);
  const next = deferred(); f.httpGate = next; const second = f.check('https://another.example'); await tick();
  old.resolve(response()); await tick(); assert.equal(f.requests[1].destroyed, 0);
  next.resolve(response()); assert.equal((await second).state, 'success'); assert.equal(f.requests[1].destroyed, 1);
});
test('privacy refusal and invalid input stop before cache or network access without disclosing private errors', async () => {
  const f = fixture(); f.allowed = false;
  const result = await f.check(); assert.equal(result.state, 'unconfirmed'); assert.doesNotMatch(result.message, /PRIVATE_SECRET/);
  assert.equal(f.cacheReads.length, 0); assert.equal(f.requests.length, 0);
  f.allowed = true; assert.equal((await f.check('http://mirror.example')).state, 'warning');
  assert.equal((await f.check('')).state, 'unconfirmed'); assert.equal(f.cacheReads.length, 0);
});
test('privacy withdrawal during cache access prevents the pending network check', async () => {
  const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.cacheGate = deferred();
  const checking = f.check(); await tick(); f.allowed = false; f.cacheGate.resolve();
  assert.equal((await checking).state, 'unconfirmed'); assert.equal(f.requests.length, 0);
});
test('network and platform timeout failures resolve as bounded warnings and release request resources', async () => {
  for (const error of [Error('connection refused'), Object.assign(Error('net'), { code: 2300028 })]) {
    const f = fixture(); f.caches.set('stars-desc', [app(official)]); f.httpGate = deferred();
    const checking = f.check(); await tick(); f.httpGate.reject(error);
    const result = await checking; assert.equal(result.state, 'warning');
    assert.match(result.message, error.code === 2300028 ? /超时/ : /失败/);
    assert.equal(f.requests[0].destroyed, 1); assert.equal(f.timers.size, 0);
  }
});
