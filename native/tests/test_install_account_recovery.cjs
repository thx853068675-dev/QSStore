const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function load() {
  const exports = {}, storage = new Map();
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/InstallAccountRecovery.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
    exports, AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    require: () => ({ I18n: { t: value => value } })
  });
  return { bus: exports.InstallAccountRecovery, storage };
}
test('only confirmed session errors lead to a sign-in prompt', () => {
  const { bus } = load();
  assert.equal(bus.requiresLogin('Error: 华为账号返回的信息不完整'), true);
  assert.equal(bus.requiresLogin('Error: 登录已过期，请重新登录'), true);
  assert.equal(bus.requiresLogin('AGC 不支持自动签名申请这些权限'), false);
  assert.equal(bus.requiresLogin('AGC 权限不足，请检查开发者账号授权'), false);
  assert.equal(bus.requiresLogin('华为账号服务暂不可用（HTTP 503）'), false);
});
test('prompt transfers to the visible page and keeps original account scope', () => {
  const { bus, storage } = load(), events = [];
  const first = bus.subscribe(job => events.push(['first', job]));
  const second = bus.subscribe(job => events.push(['second', job]));
  bus.activate(first); bus.request('job-a', '["u","t"]');
  bus.activate(second);
  assert.equal(bus.scope('job-a'), '["u","t"]');
  assert.equal(storage.get('accountReauthRequired'), true);
  assert.deepEqual(events.slice(-2), [['first', ''], ['second', 'job-a']]);
  bus.clear('job-a'); assert.equal(bus.isRequested('job-a'), false);
});
