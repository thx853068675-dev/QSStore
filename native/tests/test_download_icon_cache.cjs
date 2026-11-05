const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), fsp = fs.promises, path = require('node:path'), os = require('node:os'), crypto = require('node:crypto');
const { loadEts } = require('./load_ets.cjs');
function buffer(value) { const bytes = Buffer.from(value); return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength); }
function signal() { let resolve; const promise = new Promise(done => resolve = done); return { promise, resolve }; }
const identity = (bundle = 'com.example.app', kind = 'entry', icon = 'main') =>
  ({ bundleName: bundle, moduleType: kind, mainAbility: kind === 'entry' ? 'MainAbility' : '', icon });
async function fixture(t, extension = 'hap', bundle = 'com.example.app') {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'qingqi-download-icons-'));
  t.after(() => fsp.rm(root, { recursive: true, force: true }));
  const context = { filesDir: root + '/private', cacheDir: root + '/cache' };
  await fsp.mkdir(root + '/public', { recursive: true }); await fsp.mkdir(context.cacheDir);
  const file = root + '/public/application.' + extension;
  await fsp.writeFile(file, JSON.stringify(identity(bundle)));
  const id = crypto.createHash('sha256').update(await fsp.readFile(file)).digest('hex');
  const row = { id, sha256: id, path: file, name: 'application.' + extension, bundleName: bundle, bytes: (await fsp.stat(file)).size };
  const f = { context, row, pin: 0, reserves: 0, releases: 0, verifies: 0, iconReads: [], inspectReads: [], extracted: [], entries: [],
    iconEntered: signal(), writeEntered: signal() };
  const core = { fileIo: { OpenMode: { CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC, WRITE_ONLY: fs.constants.O_WRONLY, NOFOLLOW: fs.constants.O_NOFOLLOW },
    accessSync: fs.existsSync, mkdirSync: dir => fs.mkdirSync(dir, { recursive: true }),
    lstat: async name => { const s = await fsp.lstat(name); return { size: s.size, mtime: s.mtimeMs,
      isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() }; },
    readText: name => fsp.readFile(name, 'utf8'),
    listFile: dir => fsp.readdir(dir), copyFile: (a, b) => fsp.copyFile(a, b),
    open: async (name, flags) => { if (f.openError) throw Error('disk full'); const handle = await fsp.open(name, flags); return { fd: handle, handle }; },
    write: async (handle, bytes) => { f.writeEntered.resolve(); if (f.writeWait) await f.writeWait; const result = await handle.write(Buffer.from(bytes)); return result.bytesWritten; },
    close: file => file.handle.close(), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync } };
  const mocks = {
    '@kit.CoreFileKit': core,
    '@kit.ArkTS': { util: { Base64Helper: class {
      decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    }, TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } },
    './ForegroundIdle': { ForegroundIdle: { wait: async () => { if (f.idleWait) await f.idleWait; } } },
    './StorageBudget': { StorageBudget: { require: async () => { if (f.budgetError) throw Error('no storage'); } } },
    './DownloadLibrary': { DownloadLibrary: {
      reserve: () => { f.reserves++; f.pin++; let released = false; return () => { if (!released) { released = true; f.pin--; f.releases++; } }; },
      verify: async () => {
        assert.ok(f.pin > 0); f.verifies++; if (f.verifyWait) await f.verifyWait;
        const current = f.row;
        if (crypto.createHash('sha256').update(await fsp.readFile(current.path)).digest('hex') !== current.id) throw Error('file changed');
        return { ...current };
      }
    } },
    './PackageArchive': { PackageArchive: {
      extension: name => name.endsWith('.app') ? '.app' : '.hap',
      inspect: async name => { f.inspectReads.push(name); return JSON.parse(await fsp.readFile(name, 'utf8')); },
      icon: async name => { assert.ok(f.pin > 0); f.iconReads.push(name); f.iconEntered.resolve();
        if (f.iconError) throw Error('bad icon'); if (f.iconWait) await f.iconWait;
        const packageIdentity = JSON.parse(await fsp.readFile(name, 'utf8'));
        return f.largeIcon ? new ArrayBuffer(512 * 1024 + 1) : packageIdentity.icon ? buffer(packageIdentity.icon) : undefined;
      }, release: name => { if (f.releasePaths) f.releasePaths.push(name); }
    } },
    'libhap_core.so': { listPackageEntries: () => f.entries.map(entry => ({ name: entry.name, size: JSON.stringify(entry.identity).length })),
      extractPackageEntry: async (_source, entry, output) => { assert.ok(f.pin > 0); f.extracted.push({ entry, output });
        if (f.extractWait) await f.extractWait; if (f.extractError) throw Error('bad archive');
        await fsp.writeFile(output, JSON.stringify(f.entries.find(value => value.name === entry).identity));
      } }
  };
  f.fresh = () => loadEts('jobs/DownloadIconCache', mocks).DownloadIconCache;
  f.cache = f.fresh(); return f;
}
const text = bytes => bytes && Buffer.from(bytes).toString();
test('HAP icons come from verified package resources and reuse memory and persistent cache without another package read', async t => {
  const f = await fixture(t);
  assert.equal(text(await f.cache.load(f.context, f.row)), 'main');
  assert.equal(f.verifies, 1); assert.equal(f.iconReads[0], f.row.path); assert.equal(f.pin, 0);
  assert.equal(text(await f.cache.load(f.context, f.row)), 'main'); assert.equal(f.verifies, 1);
  const fresh = f.fresh(); assert.equal(text(await fresh.load(f.context, f.row)), 'main');
  assert.equal(f.verifies, 1); assert.equal(f.iconReads.length, 1);
  assert.ok(await fresh.size(f.context) > 0);
  assert.equal(f.reserves, f.releases);
});
test('APP parsing uses a private temporary copy and cleans it without modifying the retained original', async t => {
  const f = await fixture(t, 'app'), original = await fsp.readFile(f.row.path);
  assert.equal(text(await f.cache.load(f.context, f.row)), 'main');
  assert.ok(f.inspectReads[0].startsWith(f.context.cacheDir + '/download-icons/'));
  assert.ok(f.iconReads[0].endsWith('.app')); assert.notEqual(f.iconReads[0], f.row.path);
  assert.deepEqual(await fsp.readFile(f.row.path), original);
  assert.deepEqual((await fsp.readdir(f.context.cacheDir + '/download-icons')).map(name => path.extname(name)), ['.json']);
  assert.equal(f.pin, 0);
});
test('ZIP main-module selection is independent of entry order and respects the receipt bundle', async t => {
  const f = await fixture(t, 'zip');
  f.entries = [{ name: 'feature.hap', identity: identity('com.example.app', 'feature', 'feature') },
    { name: 'other.hap', identity: identity('com.example.other', 'entry', 'other') },
    { name: 'entry.hap', identity: identity('com.example.app', 'entry', 'correct') }];
  assert.equal(text(await f.cache.load(f.context, f.row)), 'correct');
  assert.equal(f.iconReads.length, 1); assert.equal(f.extracted.length, 3); assert.equal(f.pin, 0);
  assert.ok(f.extracted.every(value => value.output.startsWith(f.context.cacheDir)));
  assert.equal((await fsp.readdir(f.context.cacheDir + '/download-icons')).some(name => name.includes('.work-')), false);
});
test('same-SHA ZIP receipts selecting different applications have independent memory, disk and coalesced-flight keys', async t => {
  const f = await fixture(t, 'zip');
  f.entries = [{ name: 'a.hap', identity: identity('com.example.app', 'entry', 'a') },
    { name: 'b.hap', identity: identity('com.example.other', 'entry', 'b') }];
  assert.equal(text(await f.cache.load(f.context, f.row)), 'a');
  const previous = { ...f.row }; f.row = { ...f.row, bundleName: 'com.example.other' };
  assert.notEqual(f.cache.key(previous), f.cache.key(f.row));
  assert.equal(text(await f.cache.load(f.context, f.row)), 'b');
  assert.equal((await fsp.readdir(f.context.cacheDir + '/download-icons')).filter(name => name.endsWith('.json')).length, 2);
  assert.equal(text(await f.fresh().load(f.context, f.row)), 'b'); assert.equal(f.iconReads.length, 2);
});
test('ambiguous ZIP applications or multiple launchable packages fall back instead of taking the first icon', async t => {
  for (const sameBundle of [false, true]) {
    const f = await fixture(t, 'zip'); f.row.bundleName = '';
    f.entries = [{ name: 'first.hap', identity: identity('com.example.app', 'entry', 'first') },
      { name: 'second.hap', identity: identity(sameBundle ? 'com.example.app' : 'com.example.other', 'entry', 'second') }];
    assert.equal(await f.cache.load(f.context, f.row), undefined); assert.equal(f.iconReads.length, 0); assert.equal(f.pin, 0);
    assert.equal((await fsp.readdir(f.context.cacheDir + '/download-icons')).length, 0);
  }
});
test('concurrent reads of one original coalesce extraction and keep all reader pins until it finishes', async t => {
  const f = await fixture(t); let finish; f.iconWait = new Promise(done => finish = done);
  const first = f.cache.load(f.context, f.row), second = f.cache.load(f.context, f.row);
  await f.iconEntered.promise; assert.equal(f.iconReads.length, 1); assert.equal(f.pin, 2);
  finish(); const values = await Promise.all([first, second]); assert.equal(text(values[0]), 'main');
  assert.equal(values[0], values[1]); assert.equal(f.pin, 0); assert.equal(f.verifies, 1);
});
test('file mutation, deletion and forged selection never return a stale cached icon', async t => {
  const f = await fixture(t); await f.cache.load(f.context, f.row);
  await fsp.writeFile(f.row.path, JSON.stringify(identity('com.example.other', 'entry', 'changed')));
  assert.equal(await f.cache.load(f.context, f.row), undefined);
  await fsp.unlink(f.row.path); assert.equal(await f.cache.load(f.context, f.row), undefined);
  const forged = await fixture(t); forged.row.bundleName = 'com.example.other';
  assert.equal(await forged.cache.load(forged.context, forged.row), undefined); assert.equal(forged.iconReads.length, 0);
});
test('oversized or unreadable icons leave fallback usable, clean work files and always release reservations', async t => {
  for (const failure of ['largeIcon', 'iconError', 'budgetError']) {
    const f = await fixture(t, 'app'); f[failure] = true;
    assert.equal(await f.cache.load(f.context, f.row), undefined); assert.equal(f.pin, 0);
    assert.equal((await fsp.readdir(f.context.cacheDir + '/download-icons')).length, 0);
  }
});
test('cache clear invalidates late persistence without cancelling a package reader or retaining temporary data', async t => {
  const f = await fixture(t); let finish; f.writeWait = new Promise(done => finish = done);
  const pending = f.cache.load(f.context, f.row);
  await f.writeEntered.promise; assert.ok(f.pin > 0);
  await f.cache.clear(f.context); finish(); assert.equal(text(await pending), 'main');
  assert.equal(await f.cache.size(f.context), 0); assert.equal(f.pin, 0);
  f.writeWait = undefined; await f.cache.load(f.context, f.row); assert.equal(f.iconReads.length, 2);
});
test('clearing while APP parsing protects active temporary bytes but prevents their icon from being repersisted', async t => {
  const f = await fixture(t, 'app'); let finish; f.iconWait = new Promise(done => finish = done);
  const pending = f.cache.load(f.context, f.row); await f.iconEntered.promise;
  const temporary = f.iconReads[0]; assert.ok(fs.existsSync(temporary)); await f.cache.clear(f.context);
  assert.ok(fs.existsSync(temporary)); finish(); assert.equal(text(await pending), 'main');
  assert.equal(await f.cache.size(f.context), 0); assert.equal(fs.existsSync(temporary), false);
});
test('persistence failure and corrupted icon records regenerate safely without affecting downloaded packages', async t => {
  const f = await fixture(t); f.openError = true;
  assert.equal(text(await f.cache.load(f.context, f.row)), 'main'); assert.equal(f.pin, 0);
  f.openError = false; await f.cache.clear(f.context); await f.cache.load(f.context, f.row);
  const dir = f.context.cacheDir + '/download-icons', record = (await fsp.readdir(dir)).find(name => name.endsWith('.json'));
  await fsp.writeFile(dir + '/' + record, 'invalid json');
  assert.equal(text(await f.fresh().load(f.context, f.row)), 'main');
  assert.ok(fs.existsSync(f.row.path)); assert.equal(f.pin, 0);
});
test('icon extraction contains no catalog requests, avatars, installed registry mutations or signatures', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/DownloadIconCache.ets'), 'utf8');
  assert.doesNotMatch(source, /StoreClient|InstalledIconCache|InstalledAppRegistry|LocalImport|SigningIdentity|https?:\/\//);
});
test('symlink cache roots and pending-write paths cannot expose or overwrite unrelated files', async t => {
  const f = await fixture(t);
  const victim = f.context.cacheDir + '/unrelated'; await fsp.mkdir(victim);
  await fsp.writeFile(victim + '/keep.json', 'keep');
  await fsp.symlink(victim, f.context.cacheDir + '/download-icons');
  assert.equal(await f.cache.load(f.context, f.row), undefined); assert.equal(f.verifies, 0);
  await f.cache.clear(f.context); assert.equal(await fsp.readFile(victim + '/keep.json', 'utf8'), 'keep');
  assert.equal(await f.cache.size(f.context), 0);
  await fsp.unlink(f.context.cacheDir + '/download-icons'); await fsp.mkdir(f.context.cacheDir + '/download-icons');
  const temporary = f.context.cacheDir + '/download-icons/' + f.row.id + '--' + f.row.bundleName + '.json.part';
  await fsp.symlink(victim + '/keep.json', temporary);
  assert.equal(text(await f.cache.load(f.context, f.row)), 'main');
  assert.equal(await fsp.readFile(victim + '/keep.json', 'utf8'), 'keep'); assert.equal(f.pin, 0);
});
