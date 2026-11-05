const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { configuration, prepare } = require('../tools/prepare_store_config.cjs');

function workspace(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-store-config-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

test('a public checkout has no production endpoint and cannot retain a previously injected value', t => {
  const root = workspace(t), output = path.join(root, 'entry/src/main/ets/data/StoreBuildConfig.ets');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, 'stale production configuration');
  assert.equal(prepare(root, {}), false);
  const source = fs.readFileSync(output, 'utf8');
  assert.match(source, /configured: boolean = false/);
  assert.match(source, /store\.example\.invalid/);
  assert.doesNotMatch(source, /stale production/);
});

test('local endpoint, CA and public-key pin reach the generated build without changing TLS identity', t => {
  const root = workspace(t), cert = '-----BEGIN CERTIFICATE-----\npublic-test-certificate\n-----END CERTIFICATE-----\n';
  fs.writeFileSync(path.join(root, 'ca.crt'), cert);
  const config = { baseUrl: 'https://store.example.invalid/', publicKeySha256: 'a'.repeat(43) + '=', caFile: 'ca.crt' };
  fs.writeFileSync(path.join(root, 'store.local.json'), JSON.stringify(config));
  assert.equal(prepare(root, {}), true);
  const result = configuration(path.join(root, 'store.local.json'));
  assert.equal(result.baseUrl, 'https://store.example.invalid');
  assert.equal(result.publicKeySha256, config.publicKeySha256);
  assert.equal(result.caData, cert);
});

test('insecure origins, embedded credentials and private signing material fail the build', t => {
  const root = workspace(t), file = path.join(root, 'store.local.json');
  fs.writeFileSync(path.join(root, 'ca.crt'), '-----BEGIN CERTIFICATE-----\npublic\n-----END CERTIFICATE-----');
  const config = { baseUrl: 'https://store.example.invalid', publicKeySha256: 'a'.repeat(43) + '=', caFile: 'ca.crt' };
  for (const baseUrl of ['http://store.example.invalid', 'https://user:password@store.example.invalid', 'https://store.example.invalid/?token=test']) {
    fs.writeFileSync(file, JSON.stringify({ ...config, baseUrl }));
    assert.throws(() => configuration(file), /HTTPS origin/);
  }
  fs.writeFileSync(file, JSON.stringify(config));
  fs.appendFileSync(path.join(root, 'ca.crt'), '\n-----BEGIN PRIVATE KEY-----');
  assert.throws(() => configuration(file), /only public certificates/);
  assert.throws(() => prepare(root, { QINGQI_STORE_CONFIG: path.join(root, 'missing.json') }), /does not exist/);
});
