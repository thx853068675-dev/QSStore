const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { randomUUID } = require('node:crypto');
const { loadEts } = require('./load_ets.cjs');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/data/DownloadProxyPreferences.ets'), 'utf8');
const disk = new Map();
const secrets = new Map();
let failFlush = false;
const Tag = { ALIAS: 1, SECRET: 2, SYNC_TYPE: 3, RETURN_TYPE: 4 };
const alias = attributes => new TextDecoder().decode(attributes.get(Tag.ALIAS));
const credentialModule = loadEts('data/DownloadProxyCredentials', {
  '@kit.ArkTS': { util: { TextEncoder: class extends TextEncoder { encodeInto(text) { return this.encode(text); } },
    TextDecoder: { create: (encoding, options) => ({ decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }) },
    generateRandomUUID: randomUUID } },
  '@kit.AssetStoreKit': { asset: {
    Tag, SyncType: { NEVER: 0 }, ReturnType: { ALL: 0 },
    add: async attributes => { assert.equal(attributes.get(Tag.SYNC_TYPE), 0); secrets.set(alias(attributes), attributes.get(Tag.SECRET)); },
    query: async attributes => secrets.has(alias(attributes)) ? [new Map([[Tag.SECRET, secrets.get(alias(attributes))]])] : [],
    remove: async attributes => secrets.delete(alias(attributes))
  } }
}, { Uint8Array });
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
  exports: exportsObject,
  require: name => name === '@kit.ArkData' ? { preferences: { getPreferences: async () => ({
    get: async (key, fallback) => disk.get(key) ?? fallback,
    put: async (key, value) => disk.set(key, value), flush: async () => {
      if (failFlush) { failFlush = false; throw new Error('disk write failed'); }
    }
  }) } } : name === './DownloadProxyCredentials' ? credentialModule : {}
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
test('legacy proxy is preserved as an option and concurrent additions can be switched independently', async () => {
  disk.clear();
  assert.equal((await service.load({})).enabled, false);
  const first = 'http://127.0.0.1:7890', second = 'socks5://192.168.0.7:1080', third = 'http://proxy.test:8080';
  disk.set('downloadProxyAddress', first);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first]);
  assert.equal((await service.load({})).enabled, false);
  disk.set('downloadProxyEnabled', true);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first]);
  assert.equal((await service.load({})).address, first);
  await Promise.all([service.saveProfile({}, second), service.saveProfile({}, third)]);
  assert.equal((await service.load({})).address, first, 'adding a profile keeps the working proxy');
  await service.activate({}, second);
  assert.equal((await service.load({})).address, second);
  await service.activate({}, '');
  assert.equal((await service.load({})).enabled, false);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first, second, third]);
  await service.activate({}, third);
  await service.saveProfile({}, first, third);
  assert.equal((await service.load({})).address, first);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first, second]);
  await service.remove({}, first);
  assert.equal((await service.load({})).enabled, false);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [second]);
});
test('a failed proxy switch rolls back without losing saved options', async () => {
  disk.clear();
  const first = 'http://127.0.0.1:7890', second = 'http://127.0.0.1:8080';
  await service.saveProfile({}, first);
  await service.saveProfile({}, second);
  await service.activate({}, first);
  failFlush = true;
  await assert.rejects(service.activate({}, second), /disk write failed/);
  assert.equal((await service.load({})).address, first);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first, second]);
});
test('proxy credentials stay in secure storage through edits, restarts and a failed preference commit', async () => {
  disk.clear(); secrets.clear();
  const first = 'http://proxy.test:8080', second = 'socks5://proxy.test:1080';
  await service.saveProfile({}, first, '', 'user@example', ' p:@秘密 ');
  await service.saveProfile({}, second, '', 'socks-user', 'token');
  await service.activate({}, first);
  const active = await service.load({});
  assert.equal(active.username, 'user@example');
  assert.equal(active.password, ' p:@秘密 ');
  assert.equal(active.address, first);
  assert.equal(secrets.size, 2);
  for (const value of disk.values()) assert.doesNotMatch(String(value), /user@example|秘密|socks-user|token/);
  failFlush = true;
  await assert.rejects(service.saveProfile({}, first, first, 'new-user', 'new-token'), /disk write failed/);
  assert.equal((await service.load({})).password, ' p:@秘密 ');
  assert.equal(secrets.size, 2, 'the failed replacement retires the uncommitted secret');
  await service.saveProfile({}, first, first, 'new-user', 'new-token');
  assert.equal((await service.load({})).password, 'new-token');
  assert.equal(secrets.size, 2, 'the previous secret is removed after saving the replacement');
  await service.remove({}, first);
  assert.equal((await service.load({})).enabled, false);
  assert.equal(secrets.size, 1);
  await service.activate({}, second);
  assert.equal((await service.load({})).username, 'socks-user');
  await service.saveProfile({}, second, second, '', '');
  assert.equal((await service.load({})).username, '');
  assert.equal(secrets.size, 0);
});
test('a missing secure entry fails closed, and credentials obey protocol limits', async () => {
  disk.clear(); secrets.clear();
  const address = 'socks5://proxy.test:1080';
  assert.throws(() => service.saveProfile({}, address, '', 'user', ''), /用户名和密码/);
  assert.throws(() => service.saveProfile({}, address, '', '汉'.repeat(86), 'pass'), /过长/);
  await service.saveProfile({}, address, '', 'u', 'p');
  await service.activate({}, address);
  secrets.clear();
  await assert.rejects(service.load({}), /无法读取代理凭据/);
});
test('settings switches proxies immediately and ignores latency from the previous selection', async () => {
  disk.clear();
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Settings.ets'), 'utf8');
  const start = source.indexOf('  private closeDownloadProxy()');
  const end = source.indexOf('  private editMirrorAddress(', start);
  assert.ok(start >= 0 && end > start);
  const probes = [];
  const box = { DownloadProxyPreferences: service, getContext: () => ({}), deviceInfo: { sdkApiVersion: 26 },
    I18n: { t: message => message }, errorText: error => error.message,
    DownloadProxyProbe: { latency: (...args) => new Promise(resolve => probes.push({ resolve, args })) } };
  vm.runInNewContext(ts.transpileModule('class Settings {'+source.slice(start,end)+'};globalThis.Settings=Settings;',
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = Object.assign(new box.Settings(), {
    proxyProfiles: new exportsObject.DownloadProxyProfiles(), proxyProbeGeneration: 0
  });
  await page.openDownloadProxy();
  await page.editDownloadProxy();
  await page.saveDownloadProxy();
  await page.editDownloadProxy();
  page.proxyProtocol = 'socks5';
  page.proxyPort = '1080';
  page.proxyUsername = 'proxy-user';
  page.proxyPassword = 'proxy-pass';
  await page.saveDownloadProxy();
  const [first, second] = page.proxyProfiles.addresses;
  assert.equal((await service.load({})).enabled, false);
  await page.chooseDownloadProxy(first);
  await new Promise(setImmediate);
  await page.chooseDownloadProxy(second);
  await new Promise(setImmediate);
  assert.equal((await service.load({})).address, second);
  assert.deepEqual(probes[1].args, ['socks5', '127.0.0.1', 1080, 'proxy-user', 'proxy-pass']);
  probes[1].resolve(24);
  probes[0].resolve(200);
  await new Promise(setImmediate);
  assert.equal(page.proxyLatency, 24);
  assert.equal(page.proxyTesting, false);
  await page.editDownloadProxy(second);
  assert.equal(page.proxyPassword, 'proxy-pass');
  page.proxyPassword = 'updated';
  await page.saveDownloadProxy();
  await new Promise(setImmediate);
  assert.equal(probes[2].args[4], 'updated', 'editing credentials on the same active address retests it');
  probes[2].resolve(16);
  await page.chooseDownloadProxy('');
  assert.equal((await service.load({})).enabled, false);
  assert.deepEqual([...(await service.loadProfiles({})).addresses], [first, second]);
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
  assert.ok(await output.DownloadProxyProbe.latency('http', '127.0.0.1', 7890, 'test-user', 'test-pass') >= 1);
  assert.equal(url, 'https://github.com/');
  assert.equal(options.usingProxy.host, '127.0.0.1');
  assert.equal(options.usingProxy.port, 7890);
  assert.equal(options.usingProxy.username, 'test-user');
  assert.equal(options.usingProxy.password, 'test-pass');
  assert.equal(options.header, undefined);
  assert.equal(destroyed, true);
});
