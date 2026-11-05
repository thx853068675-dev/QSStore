const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/DownloadProxyPreferences.ets'), 'utf8');
const disk = new Map();
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
  exports: exportsObject,
  require: name => name === '@kit.ArkData' ? { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {}
  }) } } : {}
});
const service = exportsObject.DownloadProxyPreferences;
test('HTTP proxy validates scheme, host and port', () => {
  assert.equal(service.normalize(' http://127.0.0.1:07890/ '), 'http://127.0.0.1:7890');
  assert.equal(service.normalize('127.0.0.1:7890'), 'http://127.0.0.1:7890');
  assert.equal(service.compose('http', '127.0.0.1', '7890'), 'http://127.0.0.1:7890');
  assert.equal(service.compose('socks5', '127.0.0.1', '7890'), 'socks5://127.0.0.1:7890');
  for (const value of ['socks5://127.0.0.1:7890', 'http://host:0', 'http://host:65536', 'http://u:p@host:80', 'http://host:80/path'])
    assert.throws(() => service.normalize(value));
});
test('download proxy is disabled by default and persists changes', async () => {
  assert.equal((await service.load({})).enabled, false);
  await service.save({}, true, 'http://127.0.0.1:7890');
  assert.equal((await service.load({})).address, 'http://127.0.0.1:7890');
  await service.save({}, false, 'http://127.0.0.1:7890');
  assert.equal((await service.load({})).enabled, false);
  await service.save({}, true, 'socks5://127.0.0.1:7890');
  assert.equal((await service.load({})).address, 'socks5://127.0.0.1:7890');
  await service.save({}, false, 'socks5://127.0.0.1:7890');
  assert.equal((await service.load({})).address, 'socks5://127.0.0.1:7890');
});
test('latency probe actually sends HTTPS via the selected HTTP proxy', async () => {
  const probeSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/DownloadProxyProbe.ets'), 'utf8');
  let url, options, destroyed = false;
  const output = {};
  vm.runInNewContext(ts.transpileModule(probeSource, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
    exports: output,
    require: name => name === '@kit.NetworkKit' ? { http: {
      RequestMethod: { HEAD: 'HEAD' }, HttpDataType: { STRING: 'string' },
      createHttp: () => ({ request: async (u, o) => { url = u; options = o; return { responseCode: 200 }; }, destroy: () => { destroyed = true; } })
    } } : name === '@kit.BasicServicesKit' ? { deviceInfo: { sdkApiVersion: 26 } } : {}
  });
  assert.ok(await output.DownloadProxyProbe.latency('http', '127.0.0.1', 7890) >= 1);
  assert.equal(url, 'https://github.com/');
  assert.equal(options.usingProxy.host, '127.0.0.1');
  assert.equal(options.usingProxy.port, 7890);
  assert.equal(destroyed, true);
});
