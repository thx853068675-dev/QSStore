const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture({ unsupported = false, recent = 0 } = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/DiscoverTopAction.ets'), 'utf8');
  const f = { on: 0, off: 0, changes: [] };
  const motion = { HoldingHandStatus: { LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2 },
    OperatingHandStatus: { LEFT_HAND_OPERATED: 1, RIGHT_HAND_OPERATED: 2 },
    on(type, callback) { assert.equal(type, 'holdingHandChanged'); f.on++; if (unsupported) throw Error('801'); f.callback = callback; },
    off(type, callback) { assert.equal(type, 'holdingHandChanged'); assert.equal(callback, f.callback); f.off++; },
    getRecentOperatingHandStatus() { return recent; } };
  const start = source.indexOf('export class HoldingSide'); const end = source.indexOf('\n@Component', start);
  const box = { exports: {}, motion };
  vm.runInNewContext(ts.transpileModule(source.slice(start, end), { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, box);
  f.side = new box.exports.HoldingSide(left => f.changes.push(left)); return f;
}
test('system hand status changes sides, retains the side for two hands or a desk, and suppresses duplicates', () => {
  const f = fixture({ recent: 1 }); f.side.start(); f.side.start();
  assert.equal(f.on, 1); assert.equal(f.side.left, true); assert.deepEqual(f.changes, [true]);
  for (const status of [1, 0, 3, 16]) f.callback(status);
  assert.deepEqual(f.changes, [true]);
  f.callback(2); assert.equal(f.side.left, false); f.callback(1); assert.equal(f.side.left, true);
  assert.deepEqual(f.changes, [true, false, true]);
});
test('hiding unsubscribes the exact callback once and ignores late events; reappearing can resume', () => {
  const f = fixture(); f.side.start(); f.side.stop(); f.side.stop();
  assert.equal(f.off, 1); f.callback(1); assert.equal(f.side.left, false);
  f.side.start(); assert.equal(f.on, 2); f.callback(1); assert.equal(f.side.left, true);
});
test('an unsupported or denied hand service leaves the action usable without failing lifecycle cleanup', () => {
  const f = fixture({ unsupported: true }); assert.doesNotThrow(() => f.side.start());
  assert.equal(f.side.left, false); assert.doesNotThrow(() => f.side.stop()); assert.equal(f.off, 0);
});
