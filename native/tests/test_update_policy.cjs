const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/UpdatePolicy.ets'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
const a = 'com.example.reader', b = 'com.example.player', c = 'com.example.editor';
const key = bundle => 'bundle.' + bundle;

function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-update-policy-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { base, calls: [], publications: [], buffers: new Map(), failOpen: false, failAll: false,
    failGet: false, failFlush: false, failPutOnce: false, overrideAll: false };
  f.context = { filesDir: base + '/private/a' };
  f.filename = ctx => base + '/' + Buffer.from(ctx.filesDir).toString('base64url') + '.json';
  f.disk = ctx => fs.existsSync(f.filename(ctx)) ? JSON.parse(fs.readFileSync(f.filename(ctx), 'utf8')) : {};
  f.seed = (ctx, values) => fs.writeFileSync(f.filename(ctx), JSON.stringify(values));
  f.load = () => {
    const exports = {}, storage = new Map();
    vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
    } }).outputText, { exports, AppStorage: {
      get: name => storage.get(name),
      setOrCreate: (name, value) => {
        assert.equal(name, 'updatePolicyRevision'); storage.set(name, value);
        f.publications.push(value); f.calls.push(['publish', value]);
      }
    }, require: name => name === '@kit.ArkData' ? { preferences: {
      getPreferences: async (ctx, name) => {
        assert.equal(name, 'qingqi-update-policy'); f.calls.push(['open', ctx.filesDir]);
        if (f.failOpen) throw Error('preferences unavailable');
        if (!f.buffers.has(ctx.filesDir)) f.buffers.set(ctx.filesDir, new Map(Object.entries(f.disk(ctx))));
        const buffer = f.buffers.get(ctx.filesDir);
        return {
          getAll: async () => {
            f.calls.push(['getAll', ctx.filesDir]);
            if (f.failAll) throw Error('cannot read policy');
            const snapshot = f.overrideAll ? f.rawAll : Object.fromEntries(buffer);
            if (f.readGate) await f.readGate.promise;
            return snapshot;
          },
          get: async (name, fallback) => {
            f.calls.push(['get', ctx.filesDir, name]);
            if (f.failGet) throw Error('cannot read previous value');
            return buffer.has(name) ? buffer.get(name) : fallback;
          },
          put: async (name, value) => {
            f.calls.push(['put', ctx.filesDir, name, value]); buffer.set(name, value);
            if (f.failPutOnce) { f.failPutOnce = false; throw Error('write failed'); }
          },
          flush: async () => {
            f.calls.push(['flushStart', ctx.filesDir]);
            if (f.flushGate) await f.flushGate.promise;
            if (f.failFlush) throw Error('disk full');
            const filename = f.filename(ctx);
            await fs.promises.writeFile(filename + '.part', JSON.stringify(Object.fromEntries(buffer)));
            await fs.promises.rename(filename + '.part', filename);
            f.calls.push(['flushed', ctx.filesDir]);
          }
        };
      }
    } } : {} });
    return exports.UpdatePolicy;
  };
  f.api = f.load();
  f.restart = () => { f.buffers = new Map(); f.api = f.load(); };
  return f;
}

test('default policy enables updates, restores lazily and does not rewrite preferences', async t => {
  const f = fixture(t);
  assert.equal(f.api.disabled(a), false); assert.equal(f.calls.length, 0);
  await f.api.restore(f.context); await f.api.restore(f.context);
  assert.equal(f.api.disabled(a), false);
  assert.equal(f.calls.filter(row => row[0] === 'getAll').length, 1);
  assert.deepEqual(f.publications, [1]); assert.deepEqual(f.disk(f.context), {});
  assert.equal(f.calls.some(row => row[0] === 'put'), false);
});

test('bundle opt-out and resume survive restart and publish only after persistence', async t => {
  const f = fixture(t); await f.api.restore(f.context);
  await f.api.setDisabled(f.context, a, true);
  assert.equal(f.api.disabled(a), true); assert.deepEqual(f.disk(f.context), { [key(a)]: true });
  assert.deepEqual(f.publications, [1, 2]);
  assert.equal(f.calls.findIndex(row => row[0] === 'flushed') < f.calls.findIndex(row => row[0] === 'publish' && row[1] === 2), true);
  f.restart(); await f.api.restore(f.context); assert.equal(f.api.disabled(a), true);
  await f.api.setDisabled(f.context, a, false); f.restart(); await f.api.restore(f.context);
  assert.equal(f.api.disabled(a), false); assert.deepEqual(f.disk(f.context), { [key(a)]: false });
});

test('different bundles from the same repository are independent and exact case is preserved', async t => {
  const f = fixture(t), anotherVariant = 'com.example.readerTablet', anotherCase = 'com.example.Reader';
  await f.api.setDisabled(f.context, a, true);
  assert.equal(f.api.disabled(anotherVariant), false); assert.equal(f.api.disabled(anotherCase), false);
  await f.api.setDisabled(f.context, anotherVariant, true); await f.api.setDisabled(f.context, a, false);
  assert.equal(f.api.disabled(a), false); assert.equal(f.api.disabled(anotherVariant), true);
  assert.deepEqual(f.disk(f.context), { [key(a)]: false, [key(anotherVariant)]: true });
});

test('a slow restore completes before a queued write and cannot overwrite its newer rule', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); f.readGate = deferred();
  const restore = f.api.restore(f.context); await tick();
  const save = f.api.setDisabled(f.context, b, true);
  await tick(); assert.equal(f.calls.some(row => row[0] === 'put'), false);
  assert.equal(f.api.disabled(a), false); assert.deepEqual(f.publications, []);
  f.readGate.resolve(); f.readGate = undefined; await Promise.all([restore, save]);
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), true);
  assert.deepEqual(f.disk(f.context), { [key(a)]: true, [key(b)]: true });
});

test('cold writes and subsequent restores wait for durable flush before exposing the rule', async t => {
  const f = fixture(t); f.flushGate = deferred();
  const save = f.api.setDisabled(f.context, a, true), restore = f.api.restore(f.context);
  await tick(); assert.equal(f.api.disabled(a), false); assert.deepEqual(f.publications, []);
  assert.deepEqual(f.disk(f.context), {});
  f.flushGate.resolve(); f.flushGate = undefined; await Promise.all([save, restore]);
  assert.equal(f.api.disabled(a), true); assert.deepEqual(f.publications, [1]);
});

test('rapid stop/resume/stop choices keep invocation order and the final rule after restart', async t => {
  const f = fixture(t); await f.api.restore(f.context); f.flushGate = deferred();
  const stop = f.api.setDisabled(f.context, a, true), resume = f.api.setDisabled(f.context, a, false),
    stopAgain = f.api.setDisabled(f.context, a, true), restore = f.api.restore(f.context);
  await tick(); assert.deepEqual(f.calls.filter(row => row[0] === 'put').map(row => row[3]), [true]);
  assert.equal(f.api.disabled(a), false); assert.deepEqual(f.publications, [1]);
  f.flushGate.resolve(); f.flushGate = undefined; await Promise.all([stop, resume, stopAgain, restore]);
  assert.deepEqual(f.calls.filter(row => row[0] === 'put').map(row => row[3]), [true, false, true]);
  assert.equal(f.api.disabled(a), true); assert.deepEqual(f.publications, [1, 2, 3, 4]);
  f.restart(); await f.api.restore(f.context); assert.equal(f.api.disabled(a), true);
});

test('a failed initial read rejects writes, is retryable and cannot replace other saved rules with an empty set', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); f.failAll = true;
  await assert.rejects(f.api.restore(f.context), /cannot read policy/);
  await assert.rejects(f.api.setDisabled(f.context, b, true), /cannot read policy/);
  assert.deepEqual(f.publications, []); assert.equal(f.calls.some(row => row[0] === 'put'), false);
  assert.deepEqual(f.disk(f.context), { [key(a)]: true });
  f.failAll = false; await f.api.setDisabled(f.context, b, true);
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), true);
  assert.deepEqual(f.disk(f.context), { [key(a)]: true, [key(b)]: true });
});

test('unavailable preference storage does not mark restore successful or poison later operations', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); f.failOpen = true;
  await assert.rejects(f.api.restore(f.context), /preferences unavailable/); assert.deepEqual(f.publications, []);
  f.failOpen = false; await f.api.restore(f.context); assert.equal(f.api.disabled(a), true);
});

test('malformed whole-store reads throw, remain retryable and never cause writes', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); f.overrideAll = true;
  for (const raw of [null, undefined, [], 'broken', true, 1]) {
    f.rawAll = raw; await assert.rejects(f.api.restore(f.context), /停更设置读取失败/);
  }
  assert.deepEqual(f.publications, []); assert.equal(f.calls.some(row => row[0] === 'put'), false);
  f.overrideAll = false; await f.api.restore(f.context); assert.equal(f.api.disabled(a), true);
});

test('bad entries cannot disable bundles, and saving another rule preserves unrelated persisted data', async t => {
  const f = fixture(t), persisted = {
    [key(a)]: true, [key(b)]: 'true', [key(c)]: 1, 'bundle.com.example.object': { disabled: true },
    'bundle../escape': true, 'bundle.com.example. bad': true, 'repo.owner/project': true, unrelated: 'keep'
  };
  f.seed(f.context, persisted); await f.api.restore(f.context);
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), false); assert.equal(f.api.disabled(c), false);
  assert.equal(f.api.disabled('com.example.object'), false); assert.equal(f.api.disabled('../escape'), false);
  await f.api.setDisabled(f.context, c, true);
  assert.deepEqual(f.disk(f.context), { ...persisted, [key(c)]: true });
});

test('flush failure leaves the visible policy unchanged and restores pending preferences before another save', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); await f.api.restore(f.context); f.failFlush = true;
  await assert.rejects(f.api.setDisabled(f.context, b, true), /disk full/);
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), false); assert.deepEqual(f.publications, [1]);
  assert.equal(f.buffers.get(f.context.filesDir).get(key(b)), false);
  assert.deepEqual(f.disk(f.context), { [key(a)]: true });
  f.failFlush = false; await f.api.setDisabled(f.context, c, true); f.restart(); await f.api.restore(f.context);
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), false); assert.equal(f.api.disabled(c), true);
});

test('a failed cold write publishes nothing until an explicit successful restore', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: true }); f.failFlush = true;
  await assert.rejects(f.api.setDisabled(f.context, a, false), /disk full/);
  assert.deepEqual(f.publications, []); assert.equal(f.api.disabled(a), false);
  f.failFlush = false; await f.api.restore(f.context); assert.equal(f.api.disabled(a), true);
  assert.deepEqual(f.publications, [1]);
});

test('put failure restores the exact previous payload and the next queued operation can proceed', async t => {
  const f = fixture(t); f.seed(f.context, { [key(a)]: 'invalid-but-preserve', [key(b)]: true });
  await f.api.restore(f.context); f.failPutOnce = true;
  const failed = assert.rejects(f.api.setDisabled(f.context, a, true), /write failed/);
  const next = f.api.setDisabled(f.context, c, true); await Promise.all([failed, next]);
  assert.equal(f.api.disabled(a), false); assert.equal(f.api.disabled(b), true); assert.equal(f.api.disabled(c), true);
  assert.equal(f.disk(f.context)[key(a)], 'invalid-but-preserve'); assert.deepEqual(f.publications, [1, 2]);
});

test('failure reading the previous value performs no write or policy notification and retries normally', async t => {
  const f = fixture(t); await f.api.restore(f.context); f.failGet = true;
  await assert.rejects(f.api.setDisabled(f.context, a, true), /cannot read previous value/);
  assert.equal(f.calls.some(row => row[0] === 'put'), false); assert.deepEqual(f.publications, [1]);
  f.failGet = false; await f.api.setDisabled(f.context, a, true); assert.equal(f.api.disabled(a), true);
});

test('filesDir scopes isolate rules, cached restores and overlapping cold reads', async t => {
  const f = fixture(t), other = { filesDir: f.base + '/private/b' };
  f.seed(f.context, { [key(a)]: true }); f.seed(other, { [key(b)]: true }); f.readGate = deferred();
  const first = f.api.restore(f.context); await tick(); const second = f.api.restore(other);
  await tick(); assert.equal(f.calls.filter(row => row[0] === 'getAll').length, 1);
  f.readGate.resolve(); f.readGate = undefined; await Promise.all([first, second]);
  assert.equal(f.api.disabled(a), false); assert.equal(f.api.disabled(b), true);
  await f.api.restore(f.context); assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), false);
  await f.api.setDisabled(f.context, c, true); await f.api.restore(other);
  assert.equal(f.api.disabled(c), false); assert.equal(f.api.disabled(b), true);
  assert.deepEqual(f.disk(other), { [key(b)]: true });
  f.restart(); await f.api.restore(f.context); assert.equal(f.api.disabled(c), true);
  await f.api.restore(other); assert.equal(f.api.disabled(c), false);
});

test('failure restoring another scope retains the previous active rules and does not cache an empty scope', async t => {
  const f = fixture(t), other = { filesDir: f.base + '/private/b' };
  f.seed(f.context, { [key(a)]: true }); f.seed(other, { [key(b)]: true }); await f.api.restore(f.context);
  f.failAll = true; await assert.rejects(f.api.restore(other));
  assert.equal(f.api.disabled(a), true); assert.equal(f.api.disabled(b), false); assert.deepEqual(f.publications, [1]);
  f.failAll = false; await f.api.restore(other); assert.equal(f.api.disabled(a), false); assert.equal(f.api.disabled(b), true);
});

test('invalid bundle identities never touch storage and no-op choices cause no duplicate publications', async t => {
  const f = fixture(t);
  for (const bundle of ['', 'repo/owner', '../outside', ' com.example.app', 'com..app', 'com.example.bad-name', 'a'.repeat(129) + '.app']) {
    assert.equal(f.api.disabled(bundle), false);
    await assert.rejects(f.api.setDisabled(f.context, bundle, true), /应用包名无效/);
  }
  assert.equal(f.calls.length, 0); await f.api.restore(f.context);
  await f.api.setDisabled(f.context, a, false); assert.deepEqual(f.publications, [1]);
  await f.api.setDisabled(f.context, a, true); const count = f.calls.filter(row => row[0] === 'put').length;
  await f.api.setDisabled(f.context, a, true); await f.api.restore(f.context);
  assert.equal(f.calls.filter(row => row[0] === 'put').length, count); assert.deepEqual(f.publications, [1, 2]);
});
