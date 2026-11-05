const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadEts } = require('./load_ets.cjs');

const label = '轻启·安装器';
const uriOf = p => 'file://docs' + p.split('/').map(encodeURIComponent).join('/');

function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-public-directory-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const f = { base, saves: 0, creates: [], access: [], stats: [], deny: () => false };
  f.context = { filesDir: base + '/private/files', cacheDir: base + '/private/cache' };
  f.root = base + '/Download'; f.app = f.root + '/com.tonghongxiang.hapstore';
  for (const p of [f.app, f.context.filesDir, f.context.cacheDir]) fs.mkdirSync(p, { recursive: true });
  f.uris = [uriOf(f.app)];
  const denied = () => Object.assign(new Error('permission denied'), { code: 13900012 });
  const io = {
    AccessModeType: { READ_WRITE: 6 },
    lstat: async p => {
      f.stats.push(p);
      if (f.deny(p, 'stat')) throw denied();
      return fs.promises.lstat(p);
    },
    access: async (p, mode) => {
      f.access.push([p, mode]);
      if (f.deny(p, mode)) throw denied();
      try { await fs.promises.access(p, mode ?? fs.constants.F_OK); return true; }
      catch (e) { if (e.code === 'ENOENT') return false; throw e; }
    },
    mkdir: async p => {
      f.creates.push(p);
      if (f.deny(p, 'mkdir')) throw denied();
      await fs.promises.mkdir(p); // The helper must not create guessed parents recursively.
    }
  };
  f.load = () => loadEts('jobs/PublicDownloadDirectory', {
    '@kit.CoreFileKit': {
      fileIo: io,
      fileUri: { FileUri: class {
        constructor(uri) {
          const parts = /^(file:\/\/[^/?#]*)(\/[^?#]*)$/.exec(uri);
          if (!parts) throw Error('bad URI');
          this.path = decodeURIComponent(parts[2]); this.authority = parts[1];
        }
        isRemoteUri() { return !['file://docs', 'file://'].includes(this.authority); }
      } },
      picker: {
        DocumentPickerMode: { DOWNLOAD: 'DOWNLOAD' },
        DocumentViewPicker: class {
          constructor(ctx) { assert.equal(ctx, f.context); }
          async save(options) {
            f.saves++;
            assert.deepEqual(JSON.parse(JSON.stringify(options)), { pickerMode: 'DOWNLOAD' });
            if (f.saveGate) await f.saveGate;
            return f.uris.slice();
          }
          select() { assert.fail('public download must not open a folder-selection UI'); }
        }
      }
    }
  }).PublicDownloadDirectory;
  f.helper = f.load();
  return f;
}

function candidates(f) { return [f.app + '/download', f.root + '/' + label, f.app + '/' + label]; }
function assertNoParentAccess(f) {
  for (const p of [...f.stats, ...f.access.map(row => row[0]), ...f.creates]) {
    assert.ok(p === f.app || p.startsWith(f.app + '/'), 'must not read/write parent or siblings: ' + p);
  }
}

test('DOWNLOAD uses only the returned application directory and creates the inner download folder', async t => {
  const f = fixture(t), location = await f.helper.ensure(f.context);
  assert.equal(location.path, f.app + '/download');
  assert.equal(location.uri, uriOf(location.path));
  assert.equal(location.displayPath, '下载/com.tonghongxiang.hapstore/download');
  assert.deepEqual(Array.from(location.knownPaths), candidates(f));
  fs.writeFileSync(location.path + '/original.hap', 'original package');
  assert.equal(fs.readFileSync(location.path + '/original.hap', 'utf8'), 'original package');
  assert.deepEqual(f.creates, [location.path]); assert.equal(f.saves, 1);
  assertNoParentAccess(f); assert.deepEqual(fs.readdirSync(f.context.filesDir), []);
});
for (const appLabel of [label, label + ' (1)']) test('real app-label DOWNLOAD grant remains unchanged: ' + appLabel, async t => {
  const f = fixture(t); f.app = f.root + '/' + appLabel; fs.mkdirSync(f.app); f.uris = [uriOf(f.app)];
  f.deny = p => p === f.root;
  const location = await f.helper.ensure(f.context);
  assert.equal(location.path, f.app + '/download');
  assert.equal(location.displayPath, '下载/' + appLabel + '/download');
  assert.equal(location.uri, uriOf(location.path));
  assert.deepEqual(Array.from(location.knownPaths), candidates(f));
  assert.equal(fs.existsSync(f.app + '/' + label), false, 'the Chinese label is not appended a second time');
  assertNoParentAccess(f);
});

test('a bare Download root is rejected before reading or creating any folder', async t => {
  const f = fixture(t); f.uris = [uriOf(f.root)];
  await assert.rejects(f.helper.ensure(f.context), /系统未返回应用下载目录/);
  assert.equal(f.stats.length, 0); assert.equal(f.access.length, 0); assert.equal(f.creates.length, 0);
});

test('legacy Chinese directories remain only trusted migration candidates and are not recreated', async t => {
  const f = fixture(t);
  for (const p of candidates(f).slice(1)) { fs.mkdirSync(p); fs.writeFileSync(p + '/old.hap', 'prior public package'); }
  f.context.metadataPath = f.context.filesDir + '/keys';
  const first = await f.helper.ensure(f.context); first.knownPaths.push(f.context.metadataPath);
  f.deny = p => p === f.root;
  const next = await f.helper.ensure(f.context);
  assert.equal(next.path, f.app + '/download');
  assert.deepEqual(Array.from(next.knownPaths), candidates(f));
  for (const old of next.knownPaths.slice(1)) assert.equal(fs.readFileSync(old + '/old.hap', 'utf8'), 'prior public package');
  assert.equal(next.knownPaths.some(p => p.startsWith(f.context.filesDir)), false);
  assert.deepEqual(f.creates, [next.path]); assertNoParentAccess(f);
});

test('all parent operations may be denied without affecting an authorized application download folder', async t => {
  const f = fixture(t); f.deny = p => p === f.root;
  const location = await f.helper.ensure(f.context);
  assert.equal(location.path, f.app + '/download');
  assert.equal(fs.existsSync(f.root + '/' + label), false);
  assert.deepEqual(f.creates, [f.app + '/download']); assertNoParentAccess(f);
});

test('missing application permissions fail without falling back to a writable parent or private storage', async t => {
  const f = fixture(t), original = f.context.filesDir + '/old.hap'; fs.writeFileSync(original, 'keep');
  f.deny = (p, mode) => mode === 6 && p === f.app;
  await assert.rejects(f.helper.ensure(f.context), /公共下载目录暂不可用，请稍后重试/);
  assert.equal(fs.readFileSync(original, 'utf8'), 'keep'); assert.equal(f.creates.length, 0);
  assertNoParentAccess(f); f.deny = () => false;
  assert.equal((await f.helper.ensure(f.context)).path, f.app + '/download');
  assert.equal(f.saves, 2, 'a denied attempt does not cache a failed grant');
});

test('concurrent calls obtain one grant and return independent locations; restart reacquires DOWNLOAD', async t => {
  const f = fixture(t); let release; f.saveGate = new Promise(done => { release = done; });
  const first = f.helper.ensure(f.context), second = f.helper.ensure(f.context); release();
  const [a, b] = await Promise.all([first, second]);
  assert.equal(f.saves, 1); assert.equal(f.creates.length, 1);
  a.path = 'poison'; a.uri = 'poison'; a.displayPath = 'poison'; a.knownPaths.push('poison');
  assert.equal(b.path, f.app + '/download');
  assert.deepEqual(Array.from(b.knownPaths), candidates(f));
  assert.equal((await f.helper.ensure(f.context)).displayPath, '下载/com.tonghongxiang.hapstore/download');
  assert.equal(f.saves, 1); assert.equal((await f.load().ensure(f.context)).path, b.path);
  assert.equal(f.saves, 2); assertNoParentAccess(f);
});

test('a removed cached download folder is recreated through a renewed DOWNLOAD grant', async t => {
  const f = fixture(t), location = await f.helper.ensure(f.context);
  fs.rmdirSync(location.path);
  assert.equal((await f.helper.ensure(f.context)).path, location.path);
  assert.equal(f.saves, 2); assert.equal(f.creates.length, 2); assertNoParentAccess(f);
});

test('Unicode and space paths round-trip through FileUri without double URI encoding', async t => {
  const f = fixture(t); f.app = f.root + '/应用 空间'; fs.mkdirSync(f.app); f.uris = [uriOf(f.app)];
  const location = await f.helper.ensure(f.context);
  assert.equal(location.path, f.app + '/download'); assert.equal(location.displayPath, '下载/应用 空间/download');
  assert.equal(location.uri, uriOf(location.path)); assert.equal(location.uri.includes('%25'), false); assertNoParentAccess(f);
});

test('invalid, remote, private and traversal grants fail before any file operations', async t => {
  const f = fixture(t);
  const invalid = [
    'https://example.com/Download/com.app', 'file://remote' + f.app,
    uriOf(f.context.filesDir + '/Download/com.app'), uriOf(f.context.cacheDir + '/Download/com.app'),
    uriOf(f.app) + '?query=1', uriOf(f.app) + '#fragment',
    uriOf(f.root) + '/%2e%2e', uriOf(f.root) + '/%5cother',
    uriOf(f.root) + '/%00other', uriOf(f.app + '/extra'), uriOf(f.base + '/Documents/com.app')
  ];
  for (const uri of invalid) { f.uris = [uri]; await assert.rejects(f.helper.ensure(f.context)); }
  for (const uris of [[], [uriOf(f.app), uriOf(f.root)]]) {
    f.uris = uris; await assert.rejects(f.helper.ensure(f.context), /无法取得公共下载目录/);
  }
  assert.equal(f.stats.length, 0); assert.equal(f.access.length, 0); assert.equal(f.creates.length, 0);
});

test('a replaced target is rejected without redirecting writes or choosing a sibling folder', async t => {
  const f = fixture(t), first = await f.helper.ensure(f.context);
  fs.rmdirSync(first.path); fs.symlinkSync(f.context.filesDir, first.path);
  await assert.rejects(f.helper.ensure(f.context), /公共下载目录暂不可用，请稍后重试/);
  assert.equal(f.saves, 2); assert.deepEqual(fs.readdirSync(f.context.filesDir), []);
  assert.equal(fs.existsSync(f.root + '/' + label), false); assertNoParentAccess(f);
});

test('replacing the cached granted application directory with a symlink is rejected', async t => {
  const f = fixture(t), first = await f.helper.ensure(f.context);
  fs.rmdirSync(first.path); fs.rmdirSync(f.app); fs.mkdirSync(f.context.filesDir + '/download');
  fs.symlinkSync(f.context.filesDir, f.app);
  await assert.rejects(f.helper.ensure(f.context), /公共下载目录暂不可用，请稍后重试/);
  assert.equal(f.saves, 2); assert.deepEqual(fs.readdirSync(f.context.filesDir), ['download']); assertNoParentAccess(f);
});
