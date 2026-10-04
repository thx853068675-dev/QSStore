const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/LocalProfileStore.ets'), 'utf8');
const dir = '/sandbox/signing-profiles';
function fixture() {
  const f = { files: new Map(), jobs: [], live: [], running: [], deleted: [], failUnlink: '', directory: true,
    jobReads: 0, afterJobRead: () => {} };
  f.profile = (name, bundle = 'com.example.alpha', expiry = 1800000000) => f.files.set(dir + '/' + name,
    { text: JSON.stringify({ 'bundle-info': { 'bundle-name': bundle }, validity: { 'not-after': expiry } }), kind: 'file' });
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { exports, setTimeout, require: name => ({
    '@kit.CoreFileKit': { fileIo: {
      accessSync: p => p === dir ? f.directory : f.files.has(p),
      lstatSync: p => {
        const kind = p === dir ? 'directory' : f.files.get(p)?.kind;
        if (!kind) throw Error('ENOENT');
        return { isDirectory: () => kind === 'directory', isFile: () => kind === 'file', isSymbolicLink: () => kind === 'symlink' };
      },
      listFileSync: p => Array.from(f.files.keys()).filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)),
      unlinkSync: p => { if (p === f.failUnlink) throw Error('EACCES'); f.files.delete(p); f.deleted.push(p); }
    } },
    'libhap_core.so': { readSignedProfile: p => { const text = f.files.get(p)?.text; JSON.parse(text); return text; } },
    '../jobs/JobStore': { JobStore: { open: async () => ({ listAll: async () => { f.jobReads++; f.afterJobRead(); return f.jobs; } }) } },
    '../jobs/JobScheduler': { JobScheduler: { runningJobIds: () => f.running } },
    '../jobs/InstallTaskState': { InstallTaskState: { snapshot: () => f.live } },
    '../jobs/RecoveryPlanner': { isPending: stage => !['installed', 'terminal_error'].includes(stage) }
  }[name] || {}) });
  f.store = exports.LocalProfileStore; f.context = { filesDir: '/sandbox' };
  f.list = () => f.store.list(f.context); f.remove = key => f.store.remove(f.context, key);
  return f;
}
test('groups every retained variant by verified content, not the filename; listing is entirely local', async () => {
  const f = fixture(); f.profile('legacy.p7b'); f.profile('hashed.p7b', 'com.example.alpha', 1900000000);
  f.profile('com.example.alpha-wrong.p7b', 'com.example.beta');
  for (const name of ['partial.p7b.part', 'certificate.cer', 'private-key.pem', 'automatic-limit.json']) f.profile(name);
  f.files.set(dir + '/linked.p7b', { kind: 'symlink' }); f.files.set(dir + '/folder.p7b', { kind: 'directory' });
  const rows = await f.list(); assert.equal(rows.length, 2);
  assert.deepEqual(Array.from(rows[0].files), ['hashed.p7b', 'legacy.p7b']); assert.equal(rows[0].expiresAt, 1900000000);
  assert.equal(rows[1].bundleName, 'com.example.beta'); assert.equal(f.jobReads, 0);
});
test('an unreadable or invalid Profile stays visible and individually removable without guessing its app', async () => {
  const f = fixture(); f.files.set(dir + '/com.example.alpha-corrupt.p7b', { kind: 'file', text: 'not a CMS' });
  f.profile('valid.p7b'); f.profile('bad-name.p7b', '../invalid');
  const rows = await f.list(); assert.equal(rows.length, 3);
  assert.equal(rows.find(row => row.key === 'file:com.example.alpha-corrupt.p7b').bundleName, '');
  assert.equal(await f.remove('file:com.example.alpha-corrupt.p7b'), 1);
  assert.ok(f.files.has(dir + '/valid.p7b')); assert.ok(f.files.has(dir + '/bad-name.p7b'));
});
test('deleting an application removes all its copies and leaves unrelated Profiles and identity material intact', async () => {
  const f = fixture(); f.profile('legacy.p7b'); f.profile('renewal.p7b'); f.profile('archived.p7b');
  f.profile('beta.p7b', 'com.example.beta'); f.profile('private-key.pem'); f.files.set('/sandbox/signing/identity.json', { kind: 'file' });
  assert.equal(await f.remove('com.example.alpha'), 3); assert.equal(f.deleted.length, 3);
  assert.ok(f.files.has(dir + '/beta.p7b')); assert.ok(f.files.has(dir + '/private-key.pem'));
  assert.ok(f.files.has('/sandbox/signing/identity.json')); assert.equal(await f.remove('com.example.alpha'), 0);
});
test('pending tasks protect every variant for their app even before they have selected a Profile', async () => {
  const f = fixture(); f.profile('alpha.p7b'); f.profile('beta.p7b', 'com.example.beta');
  for (const stage of ['downloaded', 'waiting_device', 'retryable_error', 'paused']) {
    f.jobs = [{ id: 'one', stage, bundleName: 'com.example.alpha', profilePath: '' }];
    await assert.rejects(f.remove('com.example.alpha'), /未完成的安装任务/); assert.equal(f.deleted.length, 0);
  }
  assert.equal(await f.remove('com.example.beta'), 1); f.jobs = [];
  assert.equal(await f.remove('com.example.alpha'), 1);
});
test('a running or finishing terminal task still protects its input, but finished history does not', async () => {
  const f = fixture(); f.profile('alpha.p7b');
  const job = { id: 'one', stage: 'installed', bundleName: 'com.example.alpha', profilePath: dir + '/alpha.p7b' };
  f.jobs = [job]; f.running = ['one']; await assert.rejects(f.remove('com.example.alpha'), /未完成/);
  f.running = []; f.live = [{ job, running: false, finishing: true }]; await assert.rejects(f.remove('com.example.alpha'), /未完成/);
  f.live = [{ job, running: false, finishing: false }]; assert.equal(await f.remove('com.example.alpha'), 1);
});
test('live tasks acquired while the database query was in flight are checked before unlink', async () => {
  const f = fixture(); f.profile('alpha.p7b');
  f.afterJobRead = () => { f.live = [{ job: { id: 'new', stage: 'signing', bundleName: 'com.example.alpha', profilePath: '' }, running: true }]; };
  await assert.rejects(f.remove('com.example.alpha'), /未完成/); assert.equal(f.deleted.length, 0);
});
test('unknown running tasks and explicit input paths protect even unreadable material', async () => {
  const f = fixture(); f.files.set(dir + '/invalid.p7b', { kind: 'file', text: '' });
  f.running = ['unknown']; await assert.rejects(f.remove('file:invalid.p7b'), /未完成/);
  f.running = []; f.jobs = [{ id: 'one', stage: 'signing', bundleName: '', profilePath: dir + '/invalid.p7b' }];
  await assert.rejects(f.remove('file:invalid.p7b'), /未完成/); assert.equal(f.deleted.length, 0);
});
test('stale UI keys, traversal attempts and changed file identity cannot delete another app', async () => {
  const f = fixture(); f.profile('alpha.p7b'); await f.list(); f.profile('alpha.p7b', 'com.example.beta');
  assert.equal(await f.remove('com.example.alpha'), 0); assert.equal(await f.remove('../alpha.p7b'), 0);
  assert.ok(f.files.has(dir + '/alpha.p7b')); assert.equal(f.deleted.length, 0);
  f.profile('alpha.p7b'); f.afterJobRead = () => f.profile('alpha.p7b', 'com.example.beta');
  await assert.rejects(f.remove('com.example.alpha'), /发生变化/); assert.equal(f.deleted.length, 0);
});
test('partial filesystem failure reports actual deletion count and can be retried', async () => {
  const f = fixture(); f.profile('a.p7b'); f.profile('b.p7b'); f.failUnlink = dir + '/b.p7b';
  await assert.rejects(f.remove('com.example.alpha'), /已删除 1 份/);
  assert.equal((await f.list())[0].files.length, 1); f.failUnlink = '';
  assert.equal(await f.remove('com.example.alpha'), 1);
});
test('empty first launch is supported and a large archive yields without omitting entries', async () => {
  const f = fixture(); f.directory = false; assert.equal((await f.list()).length, 0);
  assert.equal(await f.remove('com.example.alpha'), 0); f.directory = true;
  for (let i = 0; i < 31; i++) f.profile(i + '.p7b');
  assert.equal((await f.list())[0].files.length, 31); assert.equal(await f.remove('com.example.alpha'), 31);
});
