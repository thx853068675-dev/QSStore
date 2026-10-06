const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture() {
  const pending = new Map(), history = [], routes = [];
  let id = 0, failure, routeWait; const holds = [];
  const box = { exports: {}, Curve: { EaseOut: 1, Linear: 2 },
    AppStorage: { setOrCreate: (key, value) => history.push([key, value]) },
    setTimeout: (fn, ms) => { pending.set(++id, { fn, ms }); return id; },
    clearTimeout: id => pending.delete(id),
    require: name => name.includes('ForegroundIdle') ? { ForegroundIdle: { interaction: ms => holds.push(ms) } } : ({ router: { RouterMode: { Standard: 0, Single: 1 },
      pushUrl: async (options, mode) => { routes.push({ options, mode }); if (failure) throw failure; if (routeWait) await routeWait; } } }) };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/theme/StorePageMotion.ets'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, box);
  const flush = ms => { for (const [id, timer] of [...pending]) if (timer.ms === ms) { pending.delete(id); timer.fn(); } };
  return { motion: box.exports.StorePageMotion, history, pending, routes, flush, holds, slow: promise => { routeWait = promise; },
    fail: () => { failure = Error('route unavailable'); } };
}
test('material windows hide before push, preserve route parameters and recover after a failed route', async () => {
  const f = fixture(), options = { url: 'pages/LocalInstall', params: { external: true } };
  const pushed = f.motion.pushUrl(options, 1);
  assert.equal(f.history.at(-1)[1], true); assert.equal(f.routes.length, 0);
  f.flush(32); await pushed;
  assert.equal(f.routes[0].options, options); assert.equal(f.routes[0].mode, 1);
  f.flush(f.motion.duration + 64); assert.equal(f.history.at(-1)[1], false);
  f.fail(); const rejected = f.motion.pushUrl(options);
  f.flush(32); await assert.rejects(rejected, /route unavailable/);
  f.flush(f.motion.duration + 64); assert.equal(f.history.at(-1)[1], false);
});
test('a stale transition cannot reveal floating buttons during a newer return', () => {
  const f = fixture(); f.motion.prepare();
  const stale = [...f.pending.values()][0].fn;
  f.motion.prepare(); assert.equal(f.pending.size, 1);
  stale(); assert.equal(f.history.at(-1)[1], true);
  f.flush(f.motion.duration + 64); assert.equal(f.history.at(-1)[1], false);
});

test('double taps share one navigation throughout the cover, while a different destination waits', async () => {
  const f = fixture(), a = { url: 'pages/Detail', params: { id: 1 } };
  const first = f.motion.pushUrl(a), duplicate = f.motion.pushUrl({ ...a });
  assert.equal(first, duplicate);
  f.flush(32); await first;
  assert.equal(f.routes.length, 1);
  assert.equal(f.motion.pushUrl(a), first, 'completed push stays locked until its animation ends');
  const second = f.motion.pushUrl({ url: 'pages/LocalInstall', params: { external: true } }, 1);
  assert.equal(f.routes.length, 1);
  f.flush(f.motion.duration + 64); await Promise.resolve();
  f.flush(32); await second;
  assert.equal(f.routes.length, 2); assert.equal(f.routes[1].mode, 1);
  assert.deepEqual(f.holds, [284, 284]);
});

test('a slow native router remains locked after the nominal animation deadline', async () => {
  const f = fixture(); let release;
  f.slow(new Promise(resolve => { release = resolve; }));
  const options = { url: 'pages/Detail', params: { id: 3 } }, first = f.motion.pushUrl(options);
  f.flush(32); await Promise.resolve();
  f.flush(f.motion.duration + 64);
  assert.equal(f.history.at(-1)[1], true);
  assert.equal(f.motion.pushUrl(options), first); assert.equal(f.routes.length, 1);
  release(); await first;
  assert.equal(f.history.at(-1)[1], false);
});

test('an external file push retains its explicit UI router after the asynchronous frame delay', async () => {
 const f=fixture(),scoped=[];
 const ui={getRouter:()=>({pushUrl:async(options,mode)=>scoped.push({options,mode})})};
 const options={url:'pages/LocalInstall',params:{external:true}};
 const pushed=f.motion.pushUrl(options,1,ui);
 f.flush(32);await pushed;
 assert.equal(f.routes.length,0);assert.equal(scoped.length,1);
 assert.equal(scoped[0].options,options);assert.equal(scoped[0].mode,1);
});
