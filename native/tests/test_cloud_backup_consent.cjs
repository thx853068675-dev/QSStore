const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
function consentFixture(managed = true) {
  const f = { managed, businessAllowed: true, reads: 0, puts: [], stores: new Map() };
  f.context = { filesDir: '/fixture' }; f.account = { userId: 'fixture-account' };
  f.privacy = { isManaged: () => f.managed, isBusinessAllowed: () => f.businessAllowed,
    assertBusinessAllowed: () => { if (!f.businessAllowed) throw Error('privacy denied'); } };
  f.preferences = { getPreferences: async (context, name) => {
    const scope = context.filesDir + ':' + name;
    if (!f.stores.has(scope)) f.stores.set(scope, new Map());
    const disk = f.stores.get(scope);
    return { get: async (key, fallback) => { f.reads++; if (f.readGate) return f.readGate.promise;
      return disk.has(key) ? disk.get(key) : fallback; },
      put: async (key, value) => { f.puts.push({ key, value }); disk.set(key, value); },
      flush: async () => { if (f.flushFailure) throw Error('disk failed');
        if (f.flushGate) { const gate = f.flushGate; f.flushGate = undefined; await gate.promise; } }
    };
  } };
  f.load = () => loadEts('data/CloudBackupConsent', {
    '@kit.ArkData': { preferences: f.preferences }, './PrivacyConsent': { PrivacyConsent: f.privacy }
  }).CloudBackupConsent;
  f.consent = f.load(); return f;
}

test('invite backup starts denied and is scoped to the account and local sandbox', async () => {
  const f = consentFixture(), c = f.consent;
  assert.equal(await c.allowed(f.context, f.account), false);
  await c.setEnabled(f.context, f.account, true);
  assert.equal(await c.allowed(f.context, f.account), true);
  assert.equal(await c.allowed(f.context, { userId: 'other-account' }), false);
  assert.equal(await c.allowed({ filesDir: '/other-fixture' }, f.account), false);
  assert.equal(await c.allowed(f.context, { userId: '' }), false);
  assert.equal(await f.load().allowed(f.context, f.account), true, 'an explicit choice survives service reload');
});

test('public false-flag builds retain existing cloud behavior without creating consent preferences', async () => {
  const f = consentFixture(false), c = f.consent;
  assert.equal(await c.allowed(f.context, f.account), true);
  await c.setEnabled(f.context, f.account, false);
  assert.equal(await c.allowed(f.context, f.account), true); assert.equal(f.reads, 0); assert.equal(f.puts.length, 0);
  f.businessAllowed = false;
  assert.equal(await c.allowed(f.context, f.account), false);
  assert.equal(c.isAllowedNow(f.context, f.account), false);
});

test('a late initial preference read cannot restore a choice disabled while it was pending', async () => {
  const f = consentFixture(), c = f.consent;
  f.readGate = deferred(); const pending = c.selected(f.context, f.account);
  await new Promise(setImmediate); await c.setEnabled(f.context, f.account, false);
  f.readGate.resolve(true);
  assert.equal(await pending, false); assert.equal(c.isAllowedNow(f.context, f.account), false);
});

test('enable and disable writes serialize, with revocation effective before disk finishes', async () => {
  const f = consentFixture(), c = f.consent;
  f.flushGate = deferred(); const gate = f.flushGate;
  const enabling = c.setEnabled(f.context, f.account, true); await new Promise(setImmediate);
  assert.equal(c.isAllowedNow(f.context, f.account), false, 'unflushed enable is not consent');
  const disabling = c.setEnabled(f.context, f.account, false);
  gate.resolve(); await Promise.all([enabling, disabling]);
  assert.equal(await c.allowed(f.context, f.account), false);
  assert.equal(await f.load().allowed(f.context, f.account), false);
  assert.deepEqual(f.puts.map(row => row.value), [true, false]);
});

test('withdrawn privacy or failed durable storage cannot authorize backup', async () => {
  for (const failure of ['privacy', 'disk']) {
    const f = consentFixture(), c = f.consent;
    if (failure === 'disk') f.flushFailure = true;
    else f.businessAllowed = false;
    await assert.rejects(c.setEnabled(f.context, f.account, true));
    assert.equal(await c.allowed(f.context, f.account), false);
    assert.equal(c.isAllowedNow(f.context, f.account), false);
  }
});

function storeFixture() {
  const f = consentFixture(), FailureKind = loadEts('jobs/InstallJob').FailureKind;
  f.account.jwtToken = 'fixture-jwt'; f.account.accessToken = 'fixture-access';
  f.calls = []; f.receipts = 0; f.refreshes = 0;
  const basePreferences = f.preferences.getPreferences;
  f.preferences.getPreferences = async (context, name) => {
    const prefs = await basePreferences(context, name);
    if (name !== 'signing-backup-version') return prefs;
    return { ...prefs, put: async (...args) => { f.receipts++; return prefs.put(...args); } };
  };
  f.consent = f.load();
  const failures = loadEts('data/ServiceFailure', { '../jobs/InstallJob': { FailureKind } });
  const { StoreClient } = loadEts('data/StoreClient', {
    './PrivacyConsent': { PrivacyConsent: f.privacy }, './CloudBackupConsent': { CloudBackupConsent: f.consent },
    './ServiceFailure': failures, '../jobs/InstallJob': { FailureKind },
    '@kit.ArkData': { preferences: f.preferences },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeToString() { return ''; } } } },
    './AccountService': { AccountService: { configure() {}, refresh: async () => {
      f.refreshes++; if (f.refreshGate) await f.refreshGate.promise; return f.account;
    } } },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST' }, createHttp: () => ({
      destroy() {}, request: async (url, options) => {
        f.calls.push({ url, options });
        if (f.requestGate) return f.requestGate.promise;
        return f.response ?? { responseCode: 200, result: JSON.stringify({ ok: true,
          data: { synced: true, cert_id: '123', revision: 1 } }) };
      }
    }) } }
  });
  f.context.resourceManager = { getRawFileContentSync: () => new Uint8Array() };
  f.client = new StoreClient(f.context); return f;
}

test('declining backup sends neither private-key upload nor restore request, including direct endpoint calls', async () => {
  const f = storeFixture();
  assert.equal(await f.client.publishSigningIdentity('123', 'fixture-key', f.account), false);
  assert.equal(await f.client.signingIdentity(f.account), undefined);
  await assert.rejects(f.client.requestData('/api/v1/signing-identity', 'GET', f.account), /未启用/);
  assert.equal(f.calls.length, 0); assert.equal(f.receipts, 0);
});

test('only a matching positive server acknowledgment produces a durable backup receipt', async () => {
  for (const data of [{ synced: true, cert_id: '123', revision: 2 },
    { synced: false, cert_id: '123', revision: 2 }, { synced: true, cert_id: '999', revision: 2 }]) {
    const f = storeFixture(); await f.consent.setEnabled(f.context, f.account, true);
    f.response = { responseCode: 200, result: JSON.stringify({ ok: true, data }) };
    const publish = f.client.publishSigningIdentity('123', 'fixture-key', f.account);
    if (data.synced && data.cert_id === '123') { assert.equal(await publish, true); assert.equal(f.receipts, 1); }
    else { await assert.rejects(publish, /备份未确认/); assert.equal(f.receipts, 0); }
  }
});

test('stopping backup during an in-flight upload discards its late acknowledgment', async () => {
  const f = storeFixture(); await f.consent.setEnabled(f.context, f.account, true);
  f.requestGate = deferred(); const pending = f.client.publishSigningIdentity('123', 'fixture-key', f.account);
  await new Promise(setImmediate); assert.equal(f.calls.length, 1);
  await f.consent.setEnabled(f.context, f.account, false);
  f.requestGate.resolve({ responseCode: 200, result: JSON.stringify({ ok: true,
    data: { synced: true, cert_id: '123', revision: 1 } }) });
  assert.equal(await pending, false); assert.equal(f.receipts, 0);
});

test('privacy withdrawal during account refresh prevents retrying the private request', async () => {
  const f = storeFixture(); await f.consent.setEnabled(f.context, f.account, true);
  f.response = { responseCode: 401, result: '{}' }; f.refreshGate = deferred();
  const pending = f.client.publishSigningIdentity('123', 'fixture-key', f.account);
  await new Promise(setImmediate); assert.equal(f.refreshes, 1);
  f.businessAllowed = false; f.refreshGate.resolve();
  await assert.rejects(pending, /privacy denied/);
  assert.equal(f.calls.length, 1); assert.equal(f.receipts, 0);
});

test('a delayed private restore result is not returned after cloud backup was disabled', async () => {
  const f = storeFixture(); await f.consent.setEnabled(f.context, f.account, true);
  f.requestGate = deferred(); const pending = f.client.signingIdentity(f.account, '123');
  await new Promise(setImmediate); await f.consent.setEnabled(f.context, f.account, false);
  f.requestGate.resolve({ responseCode: 200, result: JSON.stringify({ ok: true, data: {
    identity: { cert_id: '123', revision: 1,
      private_key_pem: '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----' }
  } }) });
  assert.equal(await pending, undefined); assert.equal(f.receipts, 0);
});
