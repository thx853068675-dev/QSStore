const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/GitHubMirrorPreferences.ets'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function fixture(disk = new Map()) {
  const f = { disk, buffers: new Map(), calls: [], failOpen: false, failRead: false, failFlush: false, readGate: undefined, flushGate: undefined };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, require: name => name === '@kit.ArkTS' ? { url: { URL } } : name === '@kit.ArkData' ? {
    preferences: { getPreferences: async (context, name) => {
      f.calls.push(['open', context.filesDir, name]);
      assert.equal(name, 'qingqi-settings');
      if (f.failOpen) throw Error('storage unavailable');
      if (!f.buffers.has(context.filesDir)) f.buffers.set(context.filesDir, new Map(f.disk.get(context.filesDir)));
      const buffer = f.buffers.get(context.filesDir);
      return {
        get: async (key, fallback) => {
          f.calls.push(['get', context.filesDir, key]);
          if (f.failRead) throw Error('read failed');
          const value = buffer.get(key) ?? fallback;
          if (f.readGate) await f.readGate.promise;
          return value;
        },
        put: async (key, value) => { f.calls.push(['put', context.filesDir, key, value]); buffer.set(key, value); },
        flush: async () => {
          f.calls.push(['flush', context.filesDir]);
          if (f.flushGate) await f.flushGate.promise;
          if (f.failFlush) throw Error('disk full');
          f.disk.set(context.filesDir, new Map(buffer));
        }
      };
    } }
  } : {} });
  f.api = exports.GitHubMirrorPreferences;
  f.Setting = exports.GitHubMirrorSetting;
  f.setting = (enabled, address) => Object.assign(new f.Setting(), { enabled, address });
  return f;
}
const ctx = { filesDir: '/app/a' };
function plain(value) { return { enabled: value.enabled, address: value.address }; }

test('HTTPS prefixes canonicalize host and default port, preserve path, and gain a trailing slash', () => {
  const f = fixture();
  assert.equal(f.api.normalize(''), '');
  assert.equal(f.api.normalize('HTTPS://Mirror.Example:443'), 'https://mirror.example/');
  assert.equal(f.api.normalize('https://mirror.example/github-proxy'), 'https://mirror.example/github-proxy/');
  assert.equal(f.api.normalize('https://mirror.example:8443/download/'), 'https://mirror.example:8443/download/');
  assert.equal(f.api.normalize('https://[2001:db8::1]/proxy'), 'https://[2001:db8::1]/proxy/');
});
test('unsafe or malformed routes never become mirror prefixes', () => {
  const f = fixture();
  for (const value of ['http://mirror.example', 'mirror.example', 'https://', 'https://user:secret@mirror.example/',
    'https://@mirror.example/', 'https://mirror.example/?', 'https://mirror.example/#', 'https://mirror.example?q=1',
    'https://mirror.example/#x', ' https://mirror.example/', 'https://mirror.example/a b', 'https://mir\nror.example/',
    'https://mirror.example\\evil/', 'https://mirror.example/{url}', 'https://mirror.example/%zz',
    'https://bad_host.example/', 'https://-bad.example/', 'https://bad..example/', 'https://%65xample.com/',
    'https://mirror.example:0/', 'https://mirror.example:65536/', 'https://[2001:::1]/']) {
    assert.throws(() => f.api.normalize(value), /HTTPS/, value);
  }
});
test('the default is disabled and both fields survive restart while disabling retains the address', async () => {
  const f = fixture();
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: false, address: '' });
  await f.api.save(ctx, f.setting(true, 'https://mirror.example/proxy'));
  const saved = await f.api.save(ctx, f.setting(false, 'https://mirror.example/proxy/'));
  assert.deepEqual(plain(saved), { enabled: false, address: 'https://mirror.example/proxy/' });
  const restarted = fixture(f.disk);
  assert.deepEqual(plain(await restarted.api.load(ctx)), plain(saved));
  const writes = f.calls.filter(row => row[0] === 'put');
  assert.deepEqual(writes.map(row => row[2]), ['githubMirrorEnabled', 'githubMirrorAddress', 'githubMirrorEnabled', 'githubMirrorAddress']);
});
test('empty addresses may be saved for a pending configuration and invalid drafts never touch storage', async () => {
  const f = fixture();
  assert.deepEqual(plain(await f.api.save(ctx, f.setting(true, ''))), { enabled: true, address: '' });
  const count = f.calls.length;
  await assert.rejects(f.api.save(ctx, f.setting(false, 'http://invalid.example')), /HTTPS/);
  assert.equal(f.calls.length, count);
});
test('different filesDir contexts retain independent choices and returned objects cannot mutate the cache', async () => {
  const f = fixture(), other = { filesDir: '/app/b' };
  const saved = await f.api.save(ctx, f.setting(true, 'https://one.example'));
  saved.enabled = false; saved.address = 'https://wrong.example/';
  const read = await f.api.load(ctx); read.address = 'https://wrong-again.example/';
  assert.deepEqual(plain(await f.api.load(other)), { enabled: false, address: '' });
  await f.api.save(other, f.setting(true, 'https://two.example'));
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: true, address: 'https://one.example/' });
  assert.deepEqual(plain(await f.api.load(other)), { enabled: true, address: 'https://two.example/' });
});
test('a delayed cold load finishes before a save and cannot publish over its newer durable value', async () => {
  const f = fixture(new Map([[ctx.filesDir, new Map([['githubMirrorEnabled', true], ['githubMirrorAddress', 'https://old.example/']])]]));
  f.readGate = deferred();
  const load = f.api.load(ctx); await tick();
  const save = f.api.save(ctx, f.setting(true, 'https://new.example'));
  await tick(); assert.equal(f.calls.some(row => row[0] === 'put'), false);
  f.readGate.resolve(); f.readGate = undefined;
  assert.equal((await load).address, 'https://old.example/');
  assert.equal((await save).address, 'https://new.example/');
  assert.equal((await f.api.load(ctx)).address, 'https://new.example/');
});
test('load after a queued save waits for flush and rapid saves keep order and snapshot caller drafts', async () => {
  const f = fixture(); f.flushGate = deferred();
  const draft = f.setting(true, 'https://first.example');
  const first = f.api.save(ctx, draft); draft.address = 'https://mutated.example';
  const second = f.api.save(ctx, f.setting(false, 'https://second.example'));
  const load = f.api.load(ctx); await tick();
  assert.equal(f.calls.filter(row => row[0] === 'put').length, 2);
  let loaded = false; load.then(() => { loaded = true; }); await tick(); assert.equal(loaded, false);
  f.flushGate.resolve(); f.flushGate = undefined;
  assert.equal((await first).address, 'https://first.example/');
  assert.deepEqual(plain(await second), { enabled: false, address: 'https://second.example/' });
  assert.deepEqual(plain(await load), { enabled: false, address: 'https://second.example/' });
});
test('read failures return disabled without being cached and a later read retries', async () => {
  const f = fixture(new Map([[ctx.filesDir, new Map([['githubMirrorEnabled', true], ['githubMirrorAddress', 'https://ready.example/']])]]));
  f.failOpen = true;
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: false, address: '' });
  f.failOpen = false; f.failRead = true;
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: false, address: '' });
  f.failRead = false;
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: true, address: 'https://ready.example/' });
});
test('corrupt persisted input also falls back without poisoning later corrected reads', async () => {
  const f = fixture(new Map([[ctx.filesDir, new Map([['githubMirrorEnabled', true], ['githubMirrorAddress', 'http://bad.example']])]]));
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: false, address: '' });
  f.buffers.get(ctx.filesDir).set('githubMirrorAddress', 'https://fixed.example');
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: true, address: 'https://fixed.example/' });
});
test('failed persistence keeps the previous effective route, restores pending fields, and allows the next save', async () => {
  const f = fixture();
  await f.api.save(ctx, f.setting(true, 'https://old.example'));
  f.failFlush = true;
  await assert.rejects(f.api.save(ctx, f.setting(false, 'https://new.example')), /disk full/);
  assert.deepEqual(plain(await f.api.load(ctx)), { enabled: true, address: 'https://old.example/' });
  assert.equal(f.buffers.get(ctx.filesDir).get('githubMirrorEnabled'), true);
  assert.equal(f.buffers.get(ctx.filesDir).get('githubMirrorAddress'), 'https://old.example/');
  f.failFlush = false;
  assert.deepEqual(plain(await f.api.save(ctx, f.setting(false, 'https://final.example'))), { enabled: false, address: 'https://final.example/' });
});
