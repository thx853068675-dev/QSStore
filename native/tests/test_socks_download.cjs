const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const proxy = (address, username = '', password = '') => ({ address, username, password, enabled: true });
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
  const network = { connection: { Socks5DnsStrategy: { PROXY_MODE: 1 } },
    http: { createHttp: () => client, RequestMethod: { GET: 'GET' } } };
  const proxyNetwork = loadEts('data/DownloadProxyProbe', {
    '@kit.NetworkKit': network, '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: sdk } }
  });
  const { ProxyDownload } = loadEts('jobs/ProxyDownload', {
    '@kit.NetworkKit': network, '../data/DownloadProxyProbe': proxyNetwork,
    '@kit.CoreFileKit': { fileIo: { OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4 },
      openSync: () => ({ fd: 5 }), writeSync: (_fd, bytes) => { chunks.push(...new Uint8Array(bytes)); return bytes.byteLength; },
      fsyncSync: () => {}, closeSync: () => { closed = true; }, accessSync: () => true, unlinkSync: () => { deleted = true; } } },
    './JobCancellation': { JobCancellation: { isCancelled: () => false, assertActive: () => {} } }
  }, { setInterval, clearInterval });
  return { service: ProxyDownload, result: () => ({ options, chunks, deleted, closed }) };
}
test('SOCKS download streams the response through the requested proxy', async () => {
  const f = fixture(); let received = 0;
  await f.service.run('https://example.org/file', '/tmp/pkg.part', proxy('socks5://127.0.0.1:7890', 'u', 'p'), 'id', n => { received = n; });
  const r = f.result(); assert.equal(r.options.usingSocks5Proxy.host, '127.0.0.1');
  assert.equal(r.options.usingSocks5Proxy.port, 7890); assert.equal(r.options.usingSocks5Proxy.dnsStrategy, 1); assert.deepEqual(r.chunks, [1, 2, 3]);
  assert.equal(r.options.usingSocks5Proxy.username, 'u');
  assert.equal(r.options.usingSocks5Proxy.password, 'p');
  assert.equal(received, 3); assert.equal(r.deleted, false); assert.equal(r.closed, true);
});
test('failed SOCKS download removes incomplete file', async () => {
  const f = fixture(502);
  await assert.rejects(f.service.run('https://example.org/file', '/tmp/pkg.part', proxy('socks5://127.0.0.1:7890'), 'id'));
  assert.equal(f.result().deleted, true); assert.equal(f.result().closed, true);
});
test('older systems reject SOCKS before opening or downloading a file', async () => {
  const f = fixture(200, 24);
  await assert.rejects(f.service.run('https://example.org/file', '/tmp/pkg.part', proxy('socks5://127.0.0.1:7890'), 'id'), /当前系统/);
  assert.equal(f.result().options, undefined);
});
test('HTTP credentials reach the proxy options on API 24 and rejected authentication removes the partial', async () => {
  const f = fixture(407, 24);
  await assert.rejects(f.service.run('https://example.org/file', '/tmp/pkg.part',
    proxy('http://proxy.example:8080', 'member', 'p@ss'), 'id'), error =>
    /代理认证失败/.test(error.message) && !error.message.includes('p@ss'));
  const { options, deleted, closed } = f.result();
  assert.equal(options.usingProxy.username, 'member');
  assert.equal(options.usingProxy.password, 'p@ss');
  assert.equal(options.header, undefined, 'origin requests must not receive proxy credentials as ordinary headers');
  assert.equal(deleted, true);
  assert.equal(closed, true);
});

test('downloads route authenticated HTTP through NetStack and keep ordinary HTTP on the background agent', async () => {
  let selected = proxy('http://proxy.example:8080', 'member', 'p@ss');
  const calls = [];
  const { AssetDownload } = loadEts('jobs/AssetDownload', {
    '../data/DownloadProxyPreferences': { DownloadProxyPreferences: { load: async () => selected } },
    './ProxyDownload': { ProxyDownload: { run: async (_url, _path, settings) => calls.push(['stream', settings]) } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, renameSync: () => {} }, hash: { hash: async () => 'HASH' } },
    '@kit.BasicServicesKit': { request: { agent: { Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 },
      create: async (_context, config) => { calls.push(['agent', config.proxy]); throw Error('agent-called'); } } } },
    './JobCancellation': { JobCancellation: { assertActive: () => {} } }
  });
  const downloader = new AssetDownload({}, { save: async () => {} });
  const job = { id: 'job', transferTaskId: '', cachePath: '/tmp/pkg', sourceUrl: 'https://example.org/file' };
  await downloader.downloadCurrentSource(job);
  assert.deepEqual(calls, [['stream', selected]]);
  assert.equal(job.expectedSha256, 'hash');
  selected = proxy('http://proxy.example:8080');
  await assert.rejects(downloader.downloadCurrentSource(job), /agent-called/);
  assert.deepEqual(calls.at(-1), ['agent', selected.address]);
});
