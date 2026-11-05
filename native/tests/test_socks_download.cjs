const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/jobs/SocksDownload.ets'), 'utf8');
function fixture(status = 200, sdk = 26) {
  const handlers = {}, chunks = []; let options, deleted = false, closed = false;
  const client = { on: (name, handler) => { handlers[name] = handler; }, destroy: () => {},
    requestInStream: async (_url, value) => {
      options = value;
      handlers.dataReceive(Uint8Array.from([1, 2, 3]).buffer);
      handlers.dataReceiveProgress({ receiveSize: 3, totalSize: 3 });
      handlers.dataEnd();
      return status;
    } };
  const exported = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
    exports: exported, setInterval, clearInterval,
    require: name => name === '@kit.NetworkKit' ? { connection: { Socks5DnsStrategy: { PROXY_MODE: 1 } }, http: { createHttp: () => client, RequestMethod: { GET: 'GET' } } } :
      name === '@kit.BasicServicesKit' ? { deviceInfo: { sdkApiVersion: sdk } } :
      name === '@kit.CoreFileKit' ? { fileIo: { OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4 },
        openSync: () => ({ fd: 5 }), writeSync: (_fd, bytes) => { chunks.push(...new Uint8Array(bytes)); return bytes.byteLength; },
        fsyncSync: () => {}, closeSync: () => { closed = true; }, accessSync: () => true, unlinkSync: () => { deleted = true; } } } :
      name.includes('PrivacyConsent') ? { PrivacyConsent: { isBusinessAllowed: () => true, assertBusinessAllowed: () => {} } } :
      name.includes('JobCancellation') ? { JobCancellation: { isCancelled: () => false, assertActive: () => {} } } : {}
  });
  return { service: exported.SocksDownload, result: () => ({ options, chunks, deleted, closed }) };
}
test('SOCKS download streams the response through the requested proxy', async () => {
  const f = fixture(); let received = 0;
  await f.service.run('https://example.org/file', '/tmp/pkg.part', 'socks5://127.0.0.1:7890', 'id', n => { received = n; });
  const r = f.result(); assert.equal(r.options.usingSocks5Proxy.host, '127.0.0.1');
  assert.equal(r.options.usingSocks5Proxy.port, 7890); assert.equal(r.options.usingSocks5Proxy.dnsStrategy, 1); assert.deepEqual(r.chunks, [1, 2, 3]);
  assert.equal(received, 3); assert.equal(r.deleted, false); assert.equal(r.closed, true);
});
test('failed SOCKS download removes incomplete file', async () => {
  const f = fixture(502);
  await assert.rejects(f.service.run('https://example.org/file', '/tmp/pkg.part', 'socks5://127.0.0.1:7890', 'id'));
  assert.equal(f.result().deleted, true); assert.equal(f.result().closed, true);
});
test('older systems reject SOCKS before opening or downloading a file', async () => {
  const f = fixture(200, 24);
  await assert.rejects(f.service.run('https://example.org/file', '/tmp/pkg.part', 'socks5://127.0.0.1:7890', 'id'), /系统版本/);
  assert.equal(f.result().options, undefined);
});
