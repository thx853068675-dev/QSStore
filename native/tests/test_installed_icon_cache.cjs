const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
function module(file, mocks) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, console });
  return exports;
}
function fixture() {
  const disk = new Map();
  const mocks = { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value),
    getAll: async () => Object.fromEntries(disk), delete: async key => disk.delete(key), flush: async () => {}
  }) } }, '@kit.ArkTS': { util: { Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    decodeSync(data) { return Uint8Array.from(Buffer.from(data, 'base64')); }
  } } } };
  return { disk, mocks, cache: module('data/InstalledIconCache', mocks).InstalledIconCache };
}
test('imported HAP icons survive process restart and package cleanup, but are not reused for another build', async () => {
  const f = fixture(); const bytes = Uint8Array.from([137, 80, 78, 71]).buffer;
  await f.cache.save({}, 'com.example.reader', 42, bytes);
  const restarted = module('data/InstalledIconCache', f.mocks).InstalledIconCache;
  assert.deepEqual([...new Uint8Array(await restarted.load({}, 'com.example.reader', 42))], [137, 80, 78, 71]);
  assert.equal(await restarted.load({}, 'com.example.reader', 43), undefined);
  f.disk.set('icon-com.example.reader', 'bad-json');
  assert.equal(await restarted.load({}, 'com.example.reader', 42), undefined);
});
test('icon cache evicts older records to stay below its budget, preserving the most recent app', async () => {
  const f = fixture(); const bytes = new Uint8Array(450 * 1024).buffer;
  for (let i = 0; i < 16; i++) await f.cache.save({}, 'com.example.reader' + i, 1, bytes);
  assert([...f.disk.values()].reduce((size, row) => size + row.length, 0) <= 8 * 1024 * 1024);
  assert(f.disk.size < 16);
  assert.equal((await f.cache.load({}, 'com.example.reader15', 1)).byteLength, bytes.byteLength);
  const size = f.disk.size;
  await f.cache.save({}, '../bad', 1, bytes); await f.cache.save({}, 'com.example.empty', 1, new ArrayBuffer(0));
  assert.equal(f.disk.size, size);
});
test('layered device resource icons use the official compositor; unavailable resource falls back to the bundle API', async () => {
  const resource = { id: 123, type: 20000, bundleName: 'com.example.reader', moduleName: 'entry', params: [] };
  let calls = 0;
  const local = module('jobs/LocalBundles', {
    './InstalledAppRegistry': { InstalledAppRegistry: { iconResource: () => resource } },
    '@ohos.bundle': { default: { getAbilityIcon: async () => { calls++; return 'legacy-pixels'; } } }
  }).LocalBundles;
  const context = { resourceManager: { getDrawableDescriptor: value => {
    assert.equal(value, resource); return { getPixelMap: () => 'composed-pixels' };
  } } };
  assert.equal(await local.installedIcon(context, resource.bundleName, 'EntryAbility'), 'composed-pixels');
  assert.equal(calls, 0);
  context.resourceManager.getDrawableDescriptor = () => undefined;
  assert.equal(await local.installedIcon(context, resource.bundleName, 'EntryAbility'), 'legacy-pixels');
  assert.equal(calls, 1);
});
