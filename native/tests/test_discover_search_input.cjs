const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function fixture() {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private onSearchInput(');
  assert.ok(start >= 0, 'load the actual production input handler');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4);
  const constant = source.match(/private static readonly SEARCH_DEBOUNCE_MS:\s*number\s*=\s*\d+;/);
  assert.ok(constant, 'reuse the production debounce interval');
  const pending = new Map(), queries = [];
  let nextId = 0;
  const box = {
    setTimeout(callback, delay) { const id = ++nextId; pending.set(id, { callback, delay }); return id; },
    clearTimeout(id) { pending.delete(id); }
  };
  vm.runInNewContext(ts.transpileModule(`class Index { ${constant[0]} ${method} }; globalThis.Page = Index;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = Object.assign(new box.Page(), { searchTimer: -1, searchText: '',
    applySearch() { queries.push(this.searchText); } });
  return { ui, pending, queries, flush() {
    const callbacks = Array.from(pending.values()); pending.clear();
    for (const { callback } of callbacks) callback();
  } };
}

test('native Search cancels older debounces during Chinese composition and queries only the final committed text', () => {
  const f = fixture();
  f.ui.onSearchInput('Aira');
  assert.equal(f.pending.size, 1);
  f.ui.onSearchInput('qing', { value: 'qing', offset: 0 });
  assert.equal(f.pending.size, 0, 'starting IME composition cancels the previous committed query');
  assert.equal(f.ui.searchTimer, -1);
  assert.equal(f.ui.searchText, 'Aira', 'pinyin preview must not replace the committed search text');
  f.ui.onSearchInput('qingqi', { value: 'qingqi', offset: 0 });
  f.flush();
  assert.deepEqual(f.queries, []);
  assert.equal(f.ui.searchText, 'Aira');

  f.ui.onSearchInput('轻启', { value: '', offset: 0 });
  assert.equal(f.pending.size, 1);
  assert.equal(f.ui.searchText, '轻启');
  f.flush();
  assert.deepEqual(f.queries, ['轻启']);
  assert.equal(f.ui.searchTimer, -1);

  for (const value of ['派', '派音', '派音播放器']) f.ui.onSearchInput(value);
  assert.equal(f.pending.size, 1, 'rapid committed input retains only its final debounce');
  f.flush();
  assert.deepEqual(f.queries, ['轻启', '派音播放器']);
  assert.equal(f.ui.searchText, '派音播放器');
  assert.equal(f.ui.searchTimer, -1);
});
