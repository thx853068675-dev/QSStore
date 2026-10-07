const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets/jobs');
function transpile(source) {
  return ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
}
function fixture(count, failAt = -1) {
  const models = {}, exported = {}, columns = [], calls = new Map();
  vm.runInNewContext(transpile(fs.readFileSync(path.join(root, 'InstallJob.ets'), 'utf8')), { exports: models });
  const f = { closed: false, yields: 0, index: -1 };
  const rows = Array.from({ length: count }, (_, i) => ({ id: 'job-' + i, app_id: i + 1,
    bundle_name: 'com.test.n' + i, stage: 'installed', version_code: i + 1,
    mirror_urls: '["https://example.invalid/a.hap"]',
    stage_history: '[{"stage":"installed","at":100}]' }));
  const result = {
    getColumnIndex(name) { calls.set(name, (calls.get(name) ?? 0) + 1); if (!columns.includes(name)) columns.push(name); return columns.indexOf(name); },
    goToNextRow() { f.index++; if (f.index === failAt) throw Error('result read failed'); return f.index < rows.length; },
    getString(index) { return String(rows[f.index][columns[index]] ?? ''); },
    getLong(index) { return Number(rows[f.index][columns[index]] ?? 0); },
    close() { f.closed = true; }
  };
  let now = 0;
  vm.runInNewContext(transpile(fs.readFileSync(path.join(root, 'JobStore.ets'), 'utf8')), {
    exports: exported, require: name => name === './InstallJob' ? models : {},
    Date: { now: () => ++now }, setTimeout: fn => { f.yields++; return setImmediate(fn); }
  });
  f.store = new exported.JobStore({ querySql: async () => result });
  f.calls = calls; return f;
}

test('large asynchronous query conversion yields for other event-loop work and resolves every column once', async () => {
  const f = fixture(100);
  const work = f.store.query('SELECT * FROM install_jobs', []);
  await new Promise(setImmediate);
  assert(f.index < 100, 'conversion must not monopolize one callback');
  assert(f.yields > 0);
  const rows = await work;
  assert.equal(rows.length, 100); assert.equal(rows[99].id, 'job-99');
  assert.equal(rows[99].versionCode, 100); assert.equal(rows[99].stageHistory[0].at, 100);
  assert(f.calls.has('profile_path')); assert([...f.calls.values()].every(count => count === 1));
  assert(f.closed);
});

test('a single row remains immediate and result sets close on conversion failure after a yield', async () => {
  const one = fixture(1); assert.equal((await one.store.query('SELECT *', []))[0].id, 'job-0');
  assert.equal(one.yields, 0); assert(one.closed);
  const failing = fixture(20, 5);
  await assert.rejects(failing.store.query('SELECT *', []), /result read failed/);
  assert(failing.yields > 0); assert(failing.closed);
});
