const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

function fixture(probe) {
  const baseUrl = 'https://store.example.invalid';
  const pin = 'a'.repeat(43) + '=';
  const overseasUrl = 'https://overseas.example.invalid:8443';
  const overseasPin = 'b'.repeat(43) + '=';
  const events = new Map(), calls = [], errors = [], probes = [];
  let allowed = true, resets = 0, invalidations = 0;
  const { StoreRoute: route } = loadEts('data/StoreRoute', {
    '@kit.NetworkKit': {
      connection: { createNetConnection: () => ({
        on: (event, listener) => events.set(event, listener), register: callback => callback()
      }) },
      http: { RequestMethod: { GET: 'GET' }, createHttp: () => ({
        async request(url, options) {
          assert.ok(probe, 'Unexpected route probe');
          probes.push({ url, options });
          return probe(new URL(url).origin, baseUrl, overseasUrl);
        },
        destroy() {}
      }) }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {} } },
    './StoreBuildConfig': { StoreBuildConfig: { baseUrl, caData: 'main-ca', publicKeySha256: pin,
      overseasBaseUrl: probe ? overseasUrl : '', overseasCaData: 'overseas-ca', overseasPublicKeySha256: overseasPin } },
    './StoreConnectivity': { StoreConnectivity: {
      reset() { resets++; }, async explain(error) { errors.push(error); return error; }
    } },
    './PrivacyConsent': { PrivacyConsent: { assertBusinessAllowed() { if (!allowed) throw Error('consent'); } } }
  }, { setTimeout, clearTimeout });
  route.onNetworkChange(() => invalidations++);
  return {
    baseUrl, pin, overseasUrl, overseasPin, events, calls, probes, errors, route, revoke() { allowed = false; },
    get resets() { return resets; }, get invalidations() { return invalidations; },
    send(path = '/api/v1/apps', options = { method: 'GET' }, response = { responseCode: 200 }) {
      return route.request({ async request(url, actual) {
        calls.push({ url, options: actual });
        if (response instanceof Error) throw response;
        return response;
      } }, path, options);
    }
  };
}

test('store reads and authenticated writes use the same pinned origin with redirects disabled', async () => {
  const f = fixture();
  await f.send('/api/v1/apps?page=1');
  await f.send('/api/v1/me/apps', { method: 'POST', header: { Authorization: 'Bearer test' }, extraData: '{}' });
  assert.equal(f.calls.length, 2);
  for (const call of f.calls) {
    assert.equal(new URL(call.url).origin, f.baseUrl);
    assert.equal(call.options.caData, 'main-ca');
    assert.equal(call.options.certificatePinning.publicKeyHash, f.pin);
    assert.equal(call.options.maxRedirects, 0);
  }
  assert.equal(f.calls[1].options.header.Authorization, 'Bearer test');
  assert.equal(f.calls[1].options.extraData, '{}');
});

function scope(network_scope) {
  return { responseCode: 200, result: JSON.stringify({ ok: true, data: { network_scope } }) };
}

test('domestic reads share one anonymous probe at the primary and never contact the overseas gateway', async () => {
  const f = fixture(() => scope('ordinary'));
  await Promise.all([f.send(), f.send('/api/v1/collections'), f.send('/api/v1/apps/3')]);
  assert.deepEqual(f.probes.map(p => p.url), [f.baseUrl + '/api/v1/distribution']);
  assert.equal(f.calls.length, 3);
  assert.ok(f.calls.every(call => call.url.startsWith(f.baseUrl)));
});

test('a verified overseas outlet uses its own TLS configuration without sharing business headers with probes', async () => {
  const f = fixture(() => scope('overseas'));
  await f.send('/api/v1/me/apps', { method: 'POST', header: { Authorization: 'Bearer test' }, extraData: '{}' });
  assert.deepEqual(f.probes.map(p => p.url), [f.baseUrl, f.overseasUrl].map(url => url + '/api/v1/distribution'));
  assert.ok(f.probes.every(p => p.options.header === undefined && p.options.extraData === undefined &&
    p.options.maxRedirects === 0));
  assert.equal(f.probes[0].options.connectTimeout, 3500);
  assert.equal(f.probes[1].options.connectTimeout, 6000);
  assert.equal(f.probes[1].options.readTimeout, 6000);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].url, f.overseasUrl + '/api/v1/me/apps');
  assert.equal(f.calls[0].options.caData, 'overseas-ca');
  assert.equal(f.calls[0].options.certificatePinning.publicKeyHash, f.overseasPin);
  assert.equal(f.calls[0].options.header.Authorization, 'Bearer test');
});

test('an overseas response can finish routing while the primary connection is still pending', async () => {
  let completePrimary;
  let primaryFinished = false;
  const f = fixture((origin, primary) => {
    if (origin === primary) return new Promise(resolve => {
      completePrimary = (networkScope) => { primaryFinished = true; resolve(scope(networkScope)); };
    });
    return scope('overseas');
  });
  try {
    await f.send();
    assert.equal(primaryFinished, false);
    assert.deepEqual(f.calls.map(call => call.url), [f.overseasUrl + '/api/v1/apps']);
  } finally {
    completePrimary('ordinary');
  }
});

test('an unreachable primary can confirm an overseas exit before sending a write exactly once', async () => {
  const f = fixture((origin, primary) => {
    if (origin === primary) throw Error('primary unreachable');
    return scope('overseas');
  });
  await assert.rejects(f.send('/api/v1/me/apps', { method: 'POST' }, Error('uncertain write')), /uncertain write/);
  assert.deepEqual(f.calls.map(call => call.url), [f.overseasUrl + '/api/v1/me/apps']);
});

test('a failed or ordinary overseas probe leaves business on the primary', async () => {
  for (const response of [scope('ordinary'), { responseCode: 302 }, Error('unverified certificate')]) {
    const f = fixture((origin, primary) => {
      if (origin === primary) return scope('overseas');
      if (response instanceof Error) throw response;
      return response;
    });
    await f.send();
    assert.deepEqual(f.calls.map(call => call.url), [f.baseUrl + '/api/v1/apps']);
  }
});

test('a changed directory scope invalidates public data even when the selected origin stays the same', async () => {
  let current = 'ordinary';
  const f = fixture((origin, primary) => origin === primary ? scope(current) : { responseCode: 502 });
  await f.send();
  const previous = f.invalidations;
  current = 'overseas';
  f.route.revalidate();
  await f.send();
  assert.equal(f.calls[0].url, f.calls[1].url);
  assert.equal(f.invalidations, previous + 1);
});

test('a superseded overseas result cannot decide the route after a refresh', async () => {
  let completeOldProbe;
  let startOldProbe;
  const oldProbeStarted = new Promise(resolve => { startOldProbe = resolve; });
  let newNetwork = false;
  const f = fixture((origin, primary) => {
    if (origin === primary) return scope(newNetwork ? 'ordinary' : 'overseas');
    startOldProbe();
    return new Promise(resolve => { completeOldProbe = resolve; });
  });
  const pending = f.send();
  await oldProbeStarted;
  newNetwork = true;
  f.route.revalidate();
  await f.send('/api/v1/collections');
  completeOldProbe(scope('overseas'));
  await pending;
  assert.equal(f.calls.length, 2);
  assert.ok(f.calls.every(call => call.url.startsWith(f.baseUrl)));
});

test('redirect, service error or failed transport never opens another store connection', async () => {
  for (const response of [{ responseCode: 302, header: { location: 'https://old.example.invalid' } },
    { responseCode: 503 }, Object.assign(Error('transport'), { code: 2300028 })]) {
    const f = fixture();
    const request = f.send(undefined, undefined, response);
    if (response instanceof Error) {
      await assert.rejects(request, /transport/);
      assert.equal(f.errors.length, 1);
    } else assert.equal(await request, response);
    assert.equal(f.calls.length, 1);
    assert.equal(new URL(f.calls[0].url).origin, f.baseUrl);
  }
});

test('network changes invalidate store caches and later requests use the same origin', async () => {
  const f = fixture();
  await f.send();
  f.events.get('netAvailable')({ netId: 1 });
  f.events.get('netCapabilitiesChange')({ netHandle: { netId: 1 }, netCap: { bearerTypes: [1] } });
  f.events.get('netCapabilitiesChange')({ netHandle: { netId: 1 }, netCap: { bearerTypes: [5] } });
  assert.equal(f.invalidations, 1);
  f.route.revalidate();
  assert.equal(f.resets, 2);
  await f.send();
  assert.equal(f.calls[0].url, f.calls[1].url);
});

test('invalid origin paths and ungranted consent are rejected before HTTP', async () => {
  const f = fixture();
  for (const path of ['https://old.example.invalid/api/v1/apps', '//old.example.invalid', '@old.example.invalid/api/v1/apps']) {
    await assert.rejects(f.send(path), /Invalid store API path/);
  }
  f.revoke();
  await assert.rejects(f.send(), /consent/);
  assert.equal(f.calls.length, 0);
});
