const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function fixture(initial = { enabled: false, address: '' }) {
  const f = { disk: { ...initial }, writes: [], probes: [], cancels: 0, views: [], timers: new Map(), gate: undefined, fail: false };
  let tail = Promise.resolve(), timerId = 0;
  class Setting { enabled = false; address = ''; }
  const prefs = {
    normalize(value) { if (!value) return ''; if (!/^https:\/\/[^\s/?#]+(?:\/[^\s?#]*)?$/.test(value)) throw Error('invalid'); return value.endsWith('/') ? value : value + '/'; },
    load: async () => ({ ...f.disk }),
    save: (_ctx, value) => {
      const snapshot = { ...value }; f.writes.push(snapshot);
      const work = tail.then(async () => {
        if (f.gate) await f.gate.promise;
        if (f.fail) throw Error('disk full');
        f.disk = snapshot; return { ...snapshot };
      });
      tail = work.catch(() => {}); return work;
    }
  };
  class Probe {
    cancel() { f.cancels++; }
    check(_ctx, prefix) { const pending = deferred(); f.probes.push({ prefix, ...pending }); return pending.promise; }
  }
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/data/GitHubMirrorEditor.ets'), 'utf8'), { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, {
    exports, require: name => ({ './GitHubMirrorPreferences': { GitHubMirrorSetting: Setting, GitHubMirrorPreferences: prefs },
      './GitHubMirrorProbe': { GitHubMirrorProbe: Probe } })[name] || {},
    setTimeout: (callback, delay) => { const id = ++timerId; f.timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => f.timers.delete(id)
  });
  f.editor = new exports.GitHubMirrorEditor({}, view => f.views.push({ ...view }));
  f.view = () => f.views.at(-1);
  f.flushDebounce = async () => { const timers = [...f.timers.values()]; f.timers.clear(); timers.forEach(timer => timer.callback()); await tick(); };
  return f;
}

test('default off only opens input after the switch is enabled and sends no probe for an empty address', async () => {
  const f = fixture(); await f.editor.load();
  assert.equal(f.view().enabled, false); assert.equal(f.view().ready, true); assert.equal(f.probes.length, 0);
  f.editor.toggle(true); await tick();
  assert.equal(f.view().enabled, true); assert.equal(f.view().checking, false);
  assert.deepEqual(f.disk, { enabled: true, address: '' }); assert.equal(f.probes.length, 0);
});
test('rapid edits debounce one canonical address and one check, with an honest saved status', async () => {
  const f = fixture(); await f.editor.load(); f.editor.toggle(true); await tick();
  f.editor.edit('https://first.example'); f.editor.edit(' https://final.example/proxy ');
  assert.equal(f.timers.size, 1); assert.equal([...f.timers.values()][0].delay, 600);
  assert.equal(f.probes.length, 0); await f.flushDebounce();
  assert.equal(f.disk.address, 'https://final.example/proxy/'); assert.equal(f.probes.length, 1);
  assert.equal(f.view().checking, true);
  f.probes[0].resolve({ state: 'success', message: '连接检查通过' }); await tick();
  assert.equal(f.view().checking, false); assert.equal(f.view().state, 'success');
  assert.equal(f.view().address, ' https://final.example/proxy ', 'do not reset the text caret during typing');
});
test('stale check results cannot replace a newer address or reopen a closed switch', async () => {
  const f = fixture({ enabled: true, address: 'https://old.example/' }); await f.editor.load(); await tick();
  f.editor.edit('https://new.example'); await f.flushDebounce();
  f.probes[1].resolve({ state: 'success', message: 'new success' }); await tick();
  f.probes[0].resolve({ state: 'warning', message: 'stale failure' }); await tick();
  assert.equal(f.view().message, 'new success');
  f.editor.toggle(false); await tick();
  assert.equal(f.view().enabled, false); assert.equal(f.view().checking, false);
  assert.deepEqual(f.disk, { enabled: false, address: 'https://new.example/' });
});
test('a rapid on then off queues the final off even when the first write has not finished', async () => {
  const f = fixture(); await f.editor.load(); f.gate = deferred();
  f.editor.toggle(true); f.editor.toggle(false); await tick();
  assert.equal(f.writes.length, 2);
  f.gate.resolve(); await tick(); assert.equal(f.disk.enabled, false); assert.equal(f.view().enabled, false);
  assert.equal(f.probes.length, 0);
});
test('invalid draft is not saved and cannot prevent closing the switch while retaining the valid address', async () => {
  const f = fixture({ enabled: true, address: 'https://old.example/' }); await f.editor.load(); await tick();
  f.editor.edit('http://bad.example'); await f.flushDebounce();
  assert.equal(f.view().state, 'warning'); assert.equal(f.writes.length, 0);
  f.editor.toggle(false); await tick();
  assert.deepEqual(f.disk, { enabled: false, address: 'https://old.example/' });
});
test('leaving during debounce saves valid final input but cancels network work and late UI results', async () => {
  const f = fixture({ enabled: true, address: 'https://old.example/' }); await f.editor.load(); await tick();
  f.editor.edit('https://new.example'); f.editor.dispose();
  const count = f.views.length; await tick();
  assert.equal(f.disk.address, 'https://new.example/'); assert.equal(f.timers.size, 0);
  assert.equal(f.probes.length, 1, 'do not create a probe after leaving');
  f.probes[0].resolve({ state: 'success', message: 'late' }); await tick();
  assert.equal(f.views.length, count);
});
test('persistence failure restores the durable switch, keeps the draft, and does not run a probe', async () => {
  const f = fixture(); await f.editor.load(); f.fail = true; f.editor.toggle(true); await tick();
  assert.equal(f.view().enabled, false); assert.equal(f.view().state, 'warning'); assert.equal(f.probes.length, 0);
  f.fail = false; f.editor.toggle(true); await tick(); f.editor.edit('https://valid.example');
  await f.flushDebounce(); assert.equal(f.disk.address, 'https://valid.example/'); assert.equal(f.probes.length, 1);
});
