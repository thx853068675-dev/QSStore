const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/ReleaseChannelPreference.ets'), 'utf8');
function load(disk, options = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, { exports, console: { warn() {} }, require: () => ({ preferences: {
    async getPreferences(_context, storeName) {
      assert.equal(storeName, 'release-channels');
      if (options.failOpen) throw Error('storage unavailable');
      return {
        async get(key, fallback) { return disk.has(key) ? disk.get(key) : fallback; },
        async put(key, value) { if (options.failWrite) throw Error('read only'); disk.set(key, value); },
        async flush() { options.flushes = (options.flushes || 0) + 1; }
      };
    }
  } }) });
  return exports.ReleaseChannelPreference;
}
test('per-app choices survive a process restart and switching back persists stable', async () => {
  const disk = new Map(), options = {}, first = load(disk, options);
  assert.equal(await first.load({}, 42), false);
  await first.save({}, 42, true); assert.equal(options.flushes, 1);
  const restarted = load(disk);
  assert.equal(await restarted.load({}, 42), true);
  assert.equal(await restarted.load({}, 43), false, 'other apps keep their own default');
  await restarted.save({}, 43, true); await restarted.save({}, 42, false);
  const again = load(disk);
  assert.equal(await again.load({}, 42), false); assert.equal(await again.load({}, 43), true);
});
test('malformed values and inaccessible local storage safely default to stable', async () => {
  const disk = new Map([['app-42', 'true']]);
  assert.equal(await load(disk).load({}, 42), false);
  assert.equal(await load(disk, { failOpen: true }).load({}, 42), false);
  for (const id of [0, -1, 1.5, NaN]) {
    assert.equal(await load(disk).load({}, id), false);
    await load(disk).save({}, id, true);
  }
  assert.equal(disk.size, 1);
});
test('a preference write failure does not reject the successful channel change', async () => {
  const disk = new Map([['app-42', false]]);
  await load(disk, { failWrite: true }).save({}, 42, true);
  assert.equal(await load(disk).load({}, 42), false);
});
