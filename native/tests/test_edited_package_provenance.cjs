const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/EditedPackageProvenance.ets'), 'utf8');
const sha = c => c.repeat(64), context = { filesDir: '/app/files' };
const identity = { bundleName: 'com.example.editor', versionCode: 20, versionName: '1.0' };
function fixture(disk = new Map()) {
  const f = { disk, memory: new Map(), failFlush: false, failRead: false, gate: undefined };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { exports, require: name => name === '@kit.ArkData' ? {
    preferences: { getPreferences: async (ctx, name) => {
      assert.equal(name, 'qingqi-package-edits');
      if (!f.memory.has(ctx.filesDir)) f.memory.set(ctx.filesDir, new Map(disk.get(ctx.filesDir)));
      const values = f.memory.get(ctx.filesDir);
      return {
        get: async (key, fallback) => { if (f.failRead) throw Error('read failed'); return values.get(key) ?? fallback; },
        put: async (key, value) => { values.set(key, value); }, delete: async key => { values.delete(key); },
        flush: async () => { if (f.gate) await f.gate; if (f.failFlush) throw Error('disk full'); disk.set(ctx.filesDir, new Map(values)); }
      };
    } }
  } : {} });
  f.api = exports.EditedPackageProvenance;
  return f;
}
const plain = value => ({ sha256: value.sha256, assetName: value.assetName });

test('only exact output digest and complete original identity recover a locally recorded edit', async () => {
  const f = fixture(); await f.api.record(context, sha('a'), sha('b'), identity, 'Original-v1.hap');
  assert.deepEqual(plain(await f.api.source(context, sha('b').toUpperCase(), identity)), { sha256: sha('a'), assetName: 'Original-v1.hap' });
  for (const [digest, item] of [[sha('c'), identity], [sha('b'), { ...identity, bundleName: 'com.example.other' }],
    [sha('b'), { ...identity, versionCode: 21 }], [sha('b'), { ...identity, versionName: '1.0-Other' }]]) {
    assert.deepEqual(plain(await f.api.source(context, digest, item)), { sha256: '', assetName: '' });
  }
});
test('exported edits survive process restart and package deletion without trusting another device', async () => {
  const f = fixture(); await f.api.record(context, sha('a'), sha('b'), identity, 'Original.app');
  const reboot = fixture(f.disk);
  assert.deepEqual(plain(await reboot.api.source(context, sha('b'), identity)), { sha256: sha('a'), assetName: 'Original.app' });
  assert.deepEqual(plain(await fixture().api.source(context, sha('b'), identity)), { sha256: '', assetName: '' });
  const record = [...f.disk.get(context.filesDir).values()][0];
  assert.equal(record.includes('cachePath'), false); assert.equal(record.includes('privateKey'), false);
});
test('editing an exported edit preserves the first source digest and original asset variant', async () => {
  const f = fixture(); await f.api.record(context, sha('a'), sha('b'), identity, 'Original.app');
  await f.api.record(context, sha('b'), sha('c'), identity, 'Renamed-export.app');
  assert.deepEqual(plain(await f.api.source(context, sha('c'), identity)), { sha256: sha('a'), assetName: 'Original.app' });
});
test('a new bundle or changed raw version cannot inherit an earlier edit lineage', async () => {
  const f = fixture(); await f.api.record(context, sha('a'), sha('b'), identity, 'Original.hap');
  const renamed = { ...identity, bundleName: 'com.example.new' };
  await f.api.record(context, sha('b'), sha('c'), renamed, 'New.hap');
  assert.deepEqual(plain(await f.api.source(context, sha('c'), renamed)), { sha256: sha('b'), assetName: 'New.hap' });
});
test('malformed local records and invalid source/output digests never become proof', async () => {
  const f = fixture();
  for (const value of ['not json', '[]', 'null', JSON.stringify({source:sha('a'),bundle:identity.bundleName,code:20,version:'1.0',asset:''}),
    JSON.stringify({source:'not a digest',bundle:identity.bundleName,code:20,version:'1.0',asset:'x.hap'})]) {
    f.disk.set(context.filesDir, new Map([[sha('b'), value]])); f.memory.clear();
    assert.deepEqual(plain(await f.api.source(context, sha('b'), identity)), { sha256: '', assetName: '' });
  }
  await assert.rejects(f.api.record(context, 'bad', sha('b'), identity, 'x.hap'));
  await assert.rejects(f.api.record(context, sha('a'), 'bad', identity, 'x.hap'));
});
test('failed persistence rolls back the pending proof and permits a later retry', async () => {
  const f = fixture(); f.failFlush = true;
  await assert.rejects(f.api.record(context, sha('a'), sha('b'), identity, 'Original.hap'), /disk full/);
  f.failFlush = false;
  assert.deepEqual(plain(await f.api.source(context, sha('b'), identity)), { sha256: '', assetName: '' });
  await f.api.record(context, sha('a'), sha('b'), identity, 'Original.hap');
  assert.equal((await fixture(f.disk).api.source(context, sha('b'), identity)).sha256, sha('a'));
});
test('a read queued during persistence waits for the durable proof; independent apps remain isolated', async () => {
  const f = fixture(); let resolve; f.gate = new Promise(done => { resolve = done; });
  const write = f.api.record(context, sha('a'), sha('b'), identity, 'Original.hap');
  let resolved = false;
  const read = f.api.source(context, sha('b'), identity).then(value => { resolved = true; return value; });
  await new Promise(done => setImmediate(done)); assert.equal(resolved, false);
  resolve(); await write; assert.equal((await read).sha256, sha('a'));
  assert.equal((await f.api.source({filesDir:'/other/files'}, sha('b'), identity)).sha256, '');
});
test('temporary ledger read failure falls back safely instead of fabricating a latest release', async () => {
  const f = fixture(); await f.api.record(context, sha('a'), sha('b'), identity, 'Original.hap');
  f.failRead = true; assert.equal((await f.api.source(context, sha('b'), identity)).sha256, '');
  f.failRead = false; assert.equal((await f.api.source(context, sha('b'), identity)).sha256, sha('a'));
});
