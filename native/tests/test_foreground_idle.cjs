const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture() {
  let now = 0, serial = 0; const timers = new Map(), exports = {};
  const advance = ms => {
    const end = now + ms;
    while (true) {
      const next = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a,b) => a[1].at-b[1].at)[0];
      if (!next) break;
      now = next[1].at; timers.delete(next[0]); next[1].fn();
    }
    now = end;
  };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/ForegroundIdle.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, Date: { now: () => now },
    setTimeout: (fn, delay) => { timers.set(++serial, { fn, at: now + delay }); return serial; },
    clearTimeout: id => timers.delete(id) });
  return { idle: exports.ForegroundIdle, advance, timers };
}
test('return animation and immediate scrolling defer coalesced automatic work, then release one continuation per turn', () => {
  const f = fixture(), seen = []; f.idle.onForeground();
  f.idle.defer('scan', () => seen.push('old')); f.idle.defer('scan', () => seen.push('latest'));
  f.idle.defer('projection', () => seen.push('rows'));
  f.advance(790); f.idle.interaction(); f.advance(170); assert.deepEqual(seen, []);
  f.advance(10); assert.deepEqual(seen, ['latest']);
  f.advance(16); assert.deepEqual(seen, ['latest', 'rows']);
});
test('background suspends display scans without polling; foreground resumes them, while canceled page work stays canceled', async () => {
  const f = fixture(), seen = []; f.idle.onBackground();
  const scan = f.idle.wait().then(() => seen.push('scan'));
  f.idle.defer('page', () => seen.push('stale')); f.idle.cancel('page');
  f.advance(10000); assert.equal(f.timers.size, 0); assert.deepEqual(seen, []);
  f.idle.onForeground(); f.advance(799); assert.deepEqual(seen, []);
  f.advance(1); await scan; assert.deepEqual(seen, ['scan']);
});
