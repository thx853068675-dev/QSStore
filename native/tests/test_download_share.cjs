const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
function fixture(name = '应用.hap') {
  const f = { pins: 0, verified: [], records: [], options: [], events: new Map(), off: 0, uris: [],
    types: [], location: { path: '/storage/Users/currentUser/Download/轻启·安装器/download', knownPaths: [],
      uri: 'file://docs/storage/Users/currentUser/Download/%E8%BD%BB%E5%90%AF%C2%B7%E5%AE%89%E8%A3%85%E5%99%A8/download' } };
  f.row = { id: 'a'.repeat(64), name, title: '应用', path: f.location.path + '/应用 #1-' + name };
  const { DownloadShare } = loadEts('jobs/DownloadShare', {
    './DownloadLibrary': { DownloadLibrary: { reserve: () => { f.pins++; let released = false;
      return () => { assert.equal(released, false); released = true; f.pins--; }; },
      verify: async (_ctx, id) => { f.verified.push(id); assert.equal(f.pins, 1);
        if (f.verifyWait) await f.verifyWait; if (f.verifyError) throw Error('原始下载包已变化'); return f.row; },
      getLocation: async () => { if (f.locationWait) await f.locationWait;
        if (f.locationError) throw Error('公共目录未授权'); return f.location; } } },
    '@kit.CoreFileKit': { fileUri: { getUriFromPath: value => { f.uris.push(value); return 'file://app' + value; } } },
    '@kit.ArkData': { uniformTypeDescriptor: { UniformDataType: { OPENHARMONY_HAP: 'openharmony.hap',
      ZIP_ARCHIVE: 'general.zip-archive', FILE: 'general.file', OPENHARMONY_PACKAGE: 'openharmony.package' },
      getUniformDataTypeByFilenameExtension: (extension, base) => { f.types.push([extension, base]);
        return extension === '.app' ? 'com.tonghongxiang.hapstore.app' : 'general.archive'; } } },
    '@kit.ShareKit': { systemShare: { SharedData: class { constructor(record) { f.records.push(record); } },
      SharePreviewMode: { DEFAULT: 0 }, SelectionMode: { SINGLE: 0 }, ShareController: class {
        on(event, callback) { f.events.set(event, callback); }
        off(event, callback) { assert.equal(f.events.get(event), callback); f.events.delete(event); f.off++; }
        async show(_ctx, option) { f.options.push(option); if (f.showError) throw Error('分享不可用');
          if (f.showWait) await f.showWait; }
      } } }
  });
  f.session = new DownloadShare(); f.context = { filesDir: '/sandbox/files' };
  return f;
}
for (const [name, type] of [['应用.hap', 'openharmony.hap'], ['应用.app', 'com.tonghongxiang.hapstore.app'],
  ['应用.zip', 'general.zip-archive']]) test(name + ' shares an exact public URI and matching file UTD', async () => {
  const f = fixture(name); const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  assert.equal(f.records[0].utd, type);
  assert.equal(f.records[0].uri, f.location.uri + '/' + encodeURIComponent('应用 #1-' + name));
  assert.deepEqual(f.uris, [], 'public absolute paths are never converted to sandbox URIs');
  assert.equal(f.records[0].content, undefined); assert.equal(f.records[0].extraData, undefined);
  f.events.get('dismiss')(); await open; assert.equal(f.pins, 0); assert.equal(f.off, 1);
});
test('show resolution leaves the original pinned until the user closes the sharing panel', async () => {
  const f = fixture(); let finished = false;
  const open = f.session.open(f.context, f.row.id).then(() => finished = true);
  await new Promise(setImmediate); assert.equal(finished, false); assert.equal(f.pins, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(f.options)), [{ previewMode: 0, selectionMode: 0 }]);
  assert.equal(f.options[0].appLaunchTrustInfo, undefined);
  f.events.get('dismiss')(); await open; assert.equal(finished, true); assert.equal(f.pins, 0);
});
test('changed original is rejected before sharing any data and releases its reservation', async () => {
  const f = fixture(); f.verifyError = true;
  await assert.rejects(f.session.open(f.context, f.row.id), /已变化/);
  assert.equal(f.records.length, 0); assert.equal(f.options.length, 0); assert.equal(f.pins, 0);
});
test('files outside both the real public directory and legacy originals cannot be shared', async () => {
  for (const target of ['/sandbox/files/download-receipts/a.json', '/sandbox/files/downloads/sub/app.hap',
    '/storage/Users/currentUser/Download/轻启·安装器/../identity.json']) {
    const f = fixture(); f.row.path = target;
    await assert.rejects(f.session.open(f.context, f.row.id), /位置无效/);
    assert.equal(f.records.length, 0); assert.equal(f.pins, 0);
  }
});
test('an unmigrated verified legacy original uses the platform file URI conversion', async () => {
  const f = fixture(); f.row.path = '/sandbox/files/downloads/a.hap';
  f.locationError = true;
  const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  assert.deepEqual(f.uris, [f.row.path]); assert.equal(f.records[0].uri, 'file://app' + f.row.path);
  f.events.get('dismiss')(); await open; assert.equal(f.pins, 0);
});
test('a verified older public root uses only the system-derived known path and the same docs provider authority', async () => {
  const f = fixture(); f.row.path = '/storage/Users/currentUser/Download/轻启·安装器/轻启·安装器/应用 #1-应用.hap';
  f.location.knownPaths = ['/storage/Users/currentUser/Download/轻启·安装器',
    '/storage/Users/currentUser/Download/轻启·安装器/轻启·安装器'];
  const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  assert.equal(f.records[0].uri, 'file://docs' + f.row.path.split('/').map(encodeURIComponent).join('/'));
  assert.deepEqual(f.uris, []); f.events.get('dismiss')(); await open; assert.equal(f.pins, 0);
});
test('share show failure unregisters listeners and restores the next sharing opportunity', async () => {
  const f = fixture(); f.showError = true;
  await assert.rejects(f.session.open(f.context, f.row.id), /分享不可用/);
  assert.equal(f.pins, 0); assert.equal(f.off, 1); assert.equal(f.events.size, 0);
  f.showError = false; const retry = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  f.events.get('dismiss')(); await retry; assert.equal(f.pins, 0);
});
test('cancel during verification ends UI waiting immediately but keeps the file safe until verification finishes', async () => {
  const f = fixture(); let finish; f.verifyWait = new Promise(done => finish = done);
  const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  f.session.cancel(); await open; assert.equal(f.pins, 1);
  finish(); await new Promise(setImmediate); assert.equal(f.pins, 0); assert.equal(f.records.length, 0);
});
test('cancel during an unresolved show closes the wait, unregisters and releases without a lost dismiss hang', async () => {
  const f = fixture(); let finish; f.showWait = new Promise(done => finish = done);
  const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  f.session.cancel(); await open; await new Promise(setImmediate);
  assert.equal(f.pins, 0); assert.equal(f.off, 1); assert.equal(f.events.size, 0);
  finish(); await new Promise(setImmediate); assert.equal(f.pins, 0);
});
test('overlapping sharing on the same page cannot create a second native share panel', async () => {
  const f = fixture(); const open = f.session.open(f.context, f.row.id); await new Promise(setImmediate);
  await assert.rejects(f.session.open(f.context, f.row.id), /正在准备/);
  assert.equal(f.options.length, 1); f.events.get('dismiss')(); await open;
});
