const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { loadEts } = require('./load_ets.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }

function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-download-prefs-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { base, buffers: new Map(), calls: [], failOpen: false, failRead: false,
    failFlush: false, failPutOnce: false, readGate: undefined, flushGate: undefined };
  f.context = { filesDir: base + '/private/a' };
  f.filename = ctx => base + '/' + Buffer.from(ctx.filesDir).toString('base64url') + '.json';
  f.readDisk = ctx => fs.existsSync(f.filename(ctx)) ? JSON.parse(fs.readFileSync(f.filename(ctx), 'utf8')) : {};
  f.seed = (ctx, value, since) => fs.writeFileSync(f.filename(ctx), JSON.stringify({ autoCleanAfterInstall: value, autoCleanEnabledSince: since }));
  f.load = () => loadEts('jobs/DownloadPreferences', {
    '@kit.ArkData': { preferences: { getPreferences: async (ctx, name) => {
      assert.equal(name, 'qingqi-download-settings');
      f.calls.push(['open', ctx.filesDir, name]);
      if (f.failOpen) throw Error('preferences unavailable');
      if (!f.buffers.has(ctx.filesDir)) f.buffers.set(ctx.filesDir, new Map(Object.entries(f.readDisk(ctx))));
      const buffer = f.buffers.get(ctx.filesDir);
      return {
        get: async (key, fallback) => {
          assert.ok(['autoCleanAfterInstall', 'autoCleanEnabledSince'].includes(key)); f.calls.push(['get', ctx.filesDir, key]);
          if (f.failRead) throw Error('cannot read');
          const value = buffer.has(key) ? buffer.get(key) : fallback;
          if (f.readGate) await f.readGate.promise;
          return value;
        },
        put: async (key, value) => {
          assert.ok(['autoCleanAfterInstall', 'autoCleanEnabledSince'].includes(key)); f.calls.push(['put', ctx.filesDir, key, value]);
          buffer.set(key, value);
          if (f.failPutOnce) { f.failPutOnce = false; throw Error('write failed'); }
        },
        flush: async () => {
          f.calls.push(['flush', ctx.filesDir]);
          if (f.flushGate) await f.flushGate.promise;
          if (f.failFlush) throw Error('disk full');
          const filename = f.filename(ctx);
          await fs.promises.writeFile(filename + '.part', JSON.stringify(Object.fromEntries(buffer)));
          await fs.promises.rename(filename + '.part', filename);
        }
      };
    } } }
  }).DownloadPreferences;
  f.api = f.load();
  f.restart = () => { f.buffers = new Map(); f.api = f.load(); };
  return f;
}

test('download cleanup is disabled by default, lazily read and never implicitly written', async t => {
  const f = fixture(t); assert.equal(f.calls.length, 0);
  assert.equal(await f.api.load(f.context), false);
  assert.equal(await f.api.load(f.context), false);
  assert.equal(await f.api.enabledSince(f.context), 0);
  assert.deepEqual(f.readDisk(f.context), {});
  assert.equal(f.calls.filter(call => call[0] === 'open').length, 1);
  assert.equal(f.calls.some(call => call[0] === 'put'), false);
});

test('enable and disable persist to disk and survive a fresh preference module', async t => {
  const f = fixture(t);
  assert.equal(await f.api.save(f.context, true), undefined, 'save preserves the Promise<void> API');
  const since = await f.api.enabledSince(f.context); assert.ok(since > 0);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: true, autoCleanEnabledSince: since });
  f.restart(); assert.equal(await f.api.load(f.context), true);
  assert.equal(await f.api.enabledSince(f.context), since);
  await f.api.save(f.context, false); f.restart();
  assert.equal(await f.api.load(f.context), false);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: false, autoCleanEnabledSince: 0 });
});

test('a load waits for queued saves and rapid toggles keep the last user intent', async t => {
  const f = fixture(t); f.flushGate = deferred();
  const enable = f.api.save(f.context, true);
  const disable = f.api.save(f.context, false);
  const enableAgain = f.api.save(f.context, true);
  const latest = f.api.load(f.context);
  let readFinished = false; latest.then(() => { readFinished = true; });
  await tick(); assert.equal(readFinished, false);
  assert.deepEqual(f.calls.filter(call => call[0] === 'put' && call[2] === 'autoCleanAfterInstall').map(call => call[3]), [true]);
  f.flushGate.resolve(); f.flushGate = undefined;
  await Promise.all([enable, disable, enableAgain]);
  assert.equal(await latest, true);
  const latestSince = await f.api.enabledSince(f.context); assert.ok(latestSince > 0);
  assert.deepEqual(f.calls.filter(call => call[0] === 'put' && call[2] === 'autoCleanAfterInstall').map(call => call[3]), [true, false, true]);
  f.restart(); assert.equal(await f.api.load(f.context), true);
  assert.equal(await f.api.enabledSince(f.context), latestSince);
});

test('a slow initial read cannot overwrite a subsequent saved choice', async t => {
  const f = fixture(t); f.seed(f.context, true); f.readGate = deferred();
  const initial = f.api.load(f.context); await tick();
  const disable = f.api.save(f.context, false);
  await tick(); assert.equal(f.calls.some(call => call[0] === 'put'), false);
  f.readGate.resolve(); f.readGate = undefined;
  assert.equal(await initial, true); await disable;
  assert.equal(await f.api.load(f.context), false);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: false, autoCleanEnabledSince: 0 });
});

test('different local preference scopes have independent choices and queues', async t => {
  const f = fixture(t), other = { filesDir: f.base + '/private/b' };
  await f.api.save(f.context, true);
  assert.equal(await f.api.load(other), false);
  await f.api.save(other, false); f.restart();
  assert.equal(await f.api.load(f.context), true); assert.equal(await f.api.load(other), false);
});

test('open or read failure keeps originals by returning disabled and retries when storage recovers', async t => {
  const f = fixture(t); f.seed(f.context, true);
  f.failOpen = true; assert.equal(await f.api.load(f.context), false);
  f.failOpen = false; f.failRead = true; assert.equal(await f.api.load(f.context), false);
  f.failRead = false; assert.equal(await f.api.load(f.context), true);
});

test('corrupt truthy preferences cannot enable package deletion', async t => {
  const f = fixture(t);
  for (const value of ['true', 1, 'enabled', [], {}]) {
    f.seed(f.context, value); f.restart(); assert.equal(await f.api.load(f.context), false);
  }
});

test('a failed flush restores pending memory, preserves the prior choice and does not poison the next save', async t => {
  const f = fixture(t); await f.api.save(f.context, false);
  f.failFlush = true;
  await assert.rejects(f.api.save(f.context, true), /disk full/);
  assert.equal(await f.api.load(f.context), false);
  assert.equal(f.buffers.get(f.context.filesDir).get('autoCleanAfterInstall'), false);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: false, autoCleanEnabledSince: 0 });
  f.failFlush = false;
  await f.api.save(f.context, true); f.restart(); assert.equal(await f.api.load(f.context), true);
});

test('a put failure rolls back its draft and a queued subsequent switch still saves', async t => {
  const f = fixture(t); await f.api.save(f.context, true); f.failPutOnce = true;
  const failed = assert.rejects(f.api.save(f.context, false), /write failed/);
  const next = f.api.save(f.context, false);
  await Promise.all([failed, next]); f.restart();
  assert.equal(await f.api.load(f.context), false);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: false, autoCleanEnabledSince: 0 });
});

test('repeated enabling preserves the first boundary; disabling and re-enabling starts a new boundary', async t => {
  const f = fixture(t), earlier = Date.now() - 60000;
  f.seed(f.context, true, earlier);
  assert.equal(await f.api.enabledSince(f.context), earlier);
  await f.api.save(f.context, true);
  assert.equal(await f.api.enabledSince(f.context), earlier);
  await f.api.save(f.context, false); assert.equal(await f.api.enabledSince(f.context), 0);
  const requestedAt = Date.now(); await f.api.save(f.context, true);
  const renewed = await f.api.enabledSince(f.context);
  assert.ok(renewed >= requestedAt && renewed <= Date.now());
  assert.ok(renewed > earlier); f.restart(); assert.equal(await f.api.enabledSince(f.context), renewed);
});

test('a missing or invalid activation time never grants historical package cleanup', async t => {
  const f = fixture(t);
  for (const since of [undefined, 0, -1, '1', null, [], {}]) {
    f.seed(f.context, true, since); f.restart();
    assert.equal(await f.api.load(f.context), true);
    assert.equal(await f.api.enabledSince(f.context), 0);
    await f.api.save(f.context, true);
    assert.equal(await f.api.enabledSince(f.context), 0, 're-saving legacy true must not fabricate a historic opt-in boundary');
  }
});

test('enabledSince queued behind a disable returns zero instead of a stale previous activation', async t => {
  const f = fixture(t); await f.api.save(f.context, true);
  assert.ok(await f.api.enabledSince(f.context) > 0);
  f.flushGate = deferred(); const disable = f.api.save(f.context, false);
  const since = f.api.enabledSince(f.context); let finished = false; since.then(() => { finished = true; });
  await tick(); assert.equal(finished, false);
  f.flushGate.resolve(); f.flushGate = undefined;
  await disable; assert.equal(await since, 0);
});

test('failed disable restores both the active flag and its original persisted boundary', async t => {
  const f = fixture(t); await f.api.save(f.context, true);
  const since = await f.api.enabledSince(f.context);
  f.failFlush = true; await assert.rejects(f.api.save(f.context, false), /disk full/);
  assert.equal(await f.api.load(f.context), true);
  assert.equal(await f.api.enabledSince(f.context), since);
  assert.equal(f.buffers.get(f.context.filesDir).get('autoCleanEnabledSince'), since);
  assert.deepEqual(f.readDisk(f.context), { autoCleanAfterInstall: true, autoCleanEnabledSince: since });
  f.failFlush = false; f.restart(); assert.equal(await f.api.enabledSince(f.context), since);
});

test('unreadable preferences expose no activation boundary until a successful fresh read', async t => {
  const f = fixture(t), since = Date.now() - 60000; f.seed(f.context, true, since);
  f.failRead = true; assert.equal(await f.api.enabledSince(f.context), 0);
  f.failRead = false; assert.equal(await f.api.enabledSince(f.context), since);
});
