const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { DeviceSupportDisplay } = loadEts('data/DeviceSupportDisplay', { './ReleaseInfo': loadEts('data/ReleaseInfo') });
const archive = loadEts('jobs/PackageArchive', { './PackageInspector': loadEts('jobs/PackageInspector') });
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const f = { current: 'phone', dialogs: [], active: 0, maximum: 0 };
  const deviceInfo = {};
  Object.defineProperty(deviceInfo, 'deviceType', { get() {
    if (f.failDevice) throw Error('system information unavailable'); return f.current;
  } });
  const { InstallDeviceCompatibility } = loadEts('jobs/InstallDeviceCompatibility', {
    './PackageArchive': archive,
    '../theme/Palette': loadEts('theme/Palette'),
    '@kit.BasicServicesKit': { deviceInfo }, '../data/DeviceSupportDisplay': { DeviceSupportDisplay },
    '@kit.ArkUI': { promptAction: { showDialog: options => {
      f.maximum = Math.max(f.maximum, ++f.active);
      let resolve, reject;
      const pending = new Promise((yes, no) => { resolve = yes; reject = no; });
      f.dialogs.push({ options, resolve, reject });
      return pending.finally(() => f.active--);
    } } }
  });
  f.confirm = (asset, title = '测试应用') => InstallDeviceCompatibility.confirm(asset, title);
  f.api = InstallDeviceCompatibility;
  return f;
}
const asset = (types = ['tablet']) => ({ bundleName: 'com.example.app', url: 'https://example.com/app.hap',
  sha256: 'a'.repeat(64), versionCode: 2, name: 'app.hap', deviceTypes: types });

test('matching targets return silently and never alter the asset or its declarations', async () => {
  const f = fixture(), row = Object.freeze(asset(Object.freeze([' Phone ', 'TABLET', 'phone'])));
  assert.equal(await f.confirm(row), true); assert.equal(f.dialogs.length, 0);
  assert.deepEqual(row.deviceTypes, [' Phone ', 'TABLET', 'phone']);
});

test('unknown declarations, unspecified current type and unavailable device information cannot block installation', async () => {
  const f = fixture();
  const absent = asset(); absent.deviceTypes = undefined;
  for (const row of [asset([]), absent, asset([null, ''])]) {
    assert.equal(await f.confirm(row), true);
  }
  for (const current of ['', 'default', 'unknown-model']) {
    f.current = current; assert.equal(await f.confirm(asset()), true);
  }
  f.failDevice = true; assert.equal(await f.confirm(asset()), true); assert.equal(f.dialogs.length, 0);
});

test('a mismatch explains actual current and declared Chinese device labels with only cancel and continue', async () => {
  const f = fixture(), pending = f.confirm(asset(['tablet', '2in1'])); await tick();
  const options = f.dialogs[0].options;
  assert.equal(options.title, '此应用可能不适用当前设备');
  assert.match(options.message, /「测试应用」声明的支持设备：平板、电脑/);
  assert.match(options.message, /当前设备：手机/);
  assert.deepEqual(Array.from(options.buttons, row => row.text), ['取消', '继续安装']);
  f.dialogs[0].resolve({ index: 1 }); assert.equal(await pending, true);
});

test('only the explicit second button permits installation; cancel, dismissal and malformed answers decline', async () => {
  for (const answer of [{ index: 0 }, { index: 2 }, undefined]) {
    const f = fixture(), pending = f.confirm(asset()); await tick();
    f.dialogs[0].resolve(answer); assert.equal(await pending, false);
  }
  const f = fixture(), pending = f.confirm(asset()); await tick();
  f.dialogs[0].reject(Error('dismissed')); assert.equal(await pending, false);
});

test('duplicate clicks share the exact pending promise and one dialog across display titles', async () => {
  const f = fixture(), row = asset();
  const first = f.confirm(row, '名称一'), duplicate = f.confirm({ ...row }, '名称二');
  assert.equal(first, duplicate); await tick(); assert.equal(f.dialogs.length, 1);
  assert.match(f.dialogs[0].options.message, /名称一/);
  f.dialogs[0].resolve({ index: 0 }); assert.equal(await first, false); assert.equal(await duplicate, false);
});

test('different bundles, URLs, digests, builds, devices and declared target sets are distinct and globally FIFO', async () => {
  const f = fixture(), row = asset(), requests = [f.confirm(row)];
  for (const change of [{ bundleName: 'com.example.other' }, { url: 'https://example.com/other.hap' },
    { sha256: 'b'.repeat(64) }, { versionCode: 3 }, { deviceTypes: ['2in1'] }]) {
    requests.push(f.confirm({ ...row, ...change }));
  }
  f.current = 'tv'; requests.push(f.confirm(row)); await tick(); assert.equal(f.dialogs.length, 1);
  for (let i = 0; i < requests.length; i++) {
    assert.equal(f.dialogs.length, i + 1); f.dialogs[i].resolve({ index: 1 }); await requests[i]; await tick();
  }
  assert.match(f.dialogs.at(-1).options.message, /当前设备：电视/); assert.equal(f.maximum, 1);
});

test('completed approval or refusal is not cached for a later installation attempt', async () => {
  const f = fixture(), row = asset();
  for (const index of [1, 0, 1]) {
    const pending = f.confirm(row); await tick(); f.dialogs.at(-1).resolve({ index });
    assert.equal(await pending, index === 1);
  }
  assert.equal(f.dialogs.length, 3);
});

test('the queued dialog owns a snapshot even if a page changes the selected package meanwhile', async () => {
  const f = fixture(), gate = f.confirm(asset(), '前一个'); await tick();
  const row = asset(['tablet', '2in1']), pending = f.confirm(row, '最初应用');
  row.deviceTypes.splice(0, 2, 'phone'); row.bundleName = 'com.changed.app'; row.name = 'changed.hap';
  f.current = 'tablet';
  f.dialogs[0].resolve({ index: 0 }); await gate; await tick();
  assert.match(f.dialogs[1].options.message, /最初应用.*平板、电脑/);
  assert.match(f.dialogs[1].options.message, /当前设备：手机/);
  f.dialogs[1].resolve({ index: 1 }); assert.equal(await pending, true);
});

test('a failed dialog cannot poison the serial lane or leave a duplicate request permanently pending', async () => {
  const f = fixture(), one = f.confirm(asset()), two = f.confirm({ ...asset(), versionCode: 3 }); await tick();
  f.dialogs[0].reject(Error('dialog unavailable')); assert.equal(await one, false); await tick();
  assert.equal(f.dialogs.length, 2); f.dialogs[1].resolve({ index: 1 }); assert.equal(await two, true);
  const retry = f.confirm(asset()); await tick(); assert.equal(f.dialogs.length, 3);
  f.dialogs[2].resolve({ index: 0 }); assert.equal(await retry, false);
});

test('a compatible or unknown request never waits behind an unrelated mismatch dialog', async () => {
  const f = fixture(), waiting = f.confirm(asset()); await tick();
  assert.equal(await f.confirm(asset(['phone'])), true);
  f.current = 'default'; assert.equal(await f.confirm(asset()), true); assert.equal(f.dialogs.length, 1);
  f.dialogs[0].resolve({ index: 0 }); await waiting;
});

test('equivalent normalized target sets and digest case coalesce without changing source arrays', async () => {
  const f = fixture(), one = asset(['tablet', '2in1']);
  const two = { ...one, sha256: one.sha256.toUpperCase(), deviceTypes: ['2IN1', ' Tablet ', 'tablet'] };
  const first = f.confirm(one), same = f.confirm(two); assert.equal(first, same); await tick();
  assert.deepEqual(two.deviceTypes, ['2IN1', ' Tablet ', 'tablet']); assert.equal(f.dialogs.length, 1);
  f.dialogs[0].resolve({ index: 1 }); assert.equal(await same, true);
});

test('only an explicit mismatch acceptance produces a receipt for the exact asset snapshot', async () => {
  const f = fixture();
  for (const types of [[], ['phone'], undefined]) {
    const row = asset(types); if (types === undefined) row.deviceTypes = undefined;
    assert.equal(await f.confirm(row), true); assert.equal(f.api.confirmedFingerprint(row), '');
  }
  const row = asset([' TABLET ', '2IN1', 'tablet']), request = f.confirm(row); await tick();
  assert.equal(f.api.confirmedFingerprint(row), '');
  f.dialogs[0].resolve({ index: 1 }); await request;
  const receipt = f.api.confirmedFingerprint(row); assert.ok(receipt);
  assert.equal(f.api.confirmedFingerprint({ ...row, deviceTypes: ['2in1', 'tablet'] }), receipt);
  for (const change of [{ url: row.url + '?changed=1' }, { sha256: 'b'.repeat(64) },
    { deviceTypes: ['tablet'] }, { bundleName: 'com.changed.app' }, { versionCode: 3 }]) {
    assert.equal(f.api.confirmedFingerprint({ ...row, ...change }), '');
  }
  f.current = 'tv'; assert.equal(f.api.confirmedFingerprint(row), '');
});

test('a persisted acceptance survives process restart only when actual digest URL device and targets agree', async () => {
  const f = fixture(), row = asset(), request = f.confirm(row); await tick();
  f.dialogs[0].resolve({ index: 1 }); await request;
  const receipt = f.api.confirmedFingerprint(row), reopened = fixture();
  const job = { id: 'job', catalogSourceUrl: row.url, sourceUrl: 'https://mirror.example/app.hap',
    expectedSha256: row.sha256, packageSourceSha256: row.sha256,
    deviceCompatibilityFingerprint: receipt, assetName: row.name };
  assert.equal(await reopened.api.confirmPackage(job, ['tablet'], '真实应用'), true);
  assert.equal(reopened.dialogs.length, 0);
  for (const change of [{ catalogSourceUrl: row.url + '?other=1' }, { expectedSha256: 'b'.repeat(64) },
    { types: ['2in1'] }, { current: 'tv' }]) {
    const attempt = { ...job, ...change }; reopened.current = change.current || 'phone';
    const pending = reopened.api.confirmPackage(attempt, change.types || ['tablet'], '真实应用'); await tick();
    reopened.dialogs.at(-1).resolve({ index: 0 }); assert.equal(await pending, false);
    assert.equal(attempt.deviceCompatibilityFingerprint, '');
  }
  assert.equal(reopened.dialogs.length, 4);
});

test('empty catalog device declarations and missing digests never preapprove a real manifest mismatch', async () => {
  const f = fixture(), empty = asset([]);
  assert.equal(await f.confirm(empty), true); assert.equal(f.api.confirmedFingerprint(empty), '');
  const pending = f.api.confirmPackage({ id: 'empty-catalog', sourceUrl: empty.url,
    expectedSha256: empty.sha256, packageSourceSha256: empty.sha256,
    deviceCompatibilityFingerprint: f.api.confirmedFingerprint(empty) }, ['tablet'], '真实应用');
  await tick(); assert.equal(f.dialogs.length, 1); f.dialogs[0].resolve({ index: 0 }); assert.equal(await pending, false);
  const invalid = { ...asset(), sha256: '' }, request = f.confirm(invalid); await tick();
  f.dialogs[1].resolve({ index: 1 }); await request; assert.equal(f.api.confirmedFingerprint(invalid), '');
});

async function approvedZip(f, selected = 'dir/A.hap') {
  const row = { ...asset(), url: 'https://example.com/packages.zip#qingqi-package=' + encodeURIComponent(selected) };
  const prompt = f.confirm(row); await tick(); f.dialogs.at(-1).resolve({ index: 1 }); await prompt;
  return { id: 'zip-job', catalogSourceUrl: row.url,
    sourceUrl: 'https://mirror.example/packages.zip#qingqi-package=' + encodeURIComponent(selected),
    expectedSha256: row.sha256, packageSourceSha256: 'b'.repeat(64), assetName: row.name,
    deviceCompatibilityFingerprint: f.api.confirmedFingerprint(row) };
}

test('matching verified ZIP selection converts metadata consent into an inner receipt and survives restart', async () => {
  const f = fixture(), job = await approvedZip(f);
  job.sourceUrl = 'https://another-mirror.example/packages.zip#qingqi-package=dir/A.hap';
  assert.equal(await f.api.confirmPackage(job, ['tablet'], '真实内包'), true);
  assert.equal(f.dialogs.length, 1);
  const receipt = JSON.parse(job.deviceCompatibilityFingerprint);
  assert.equal(receipt[0], 2); assert.equal(receipt[1], job.catalogSourceUrl);
  assert.equal(receipt[2], job.expectedSha256); assert.equal(receipt[3], 'dir/A.hap');
  assert.equal(receipt[4], job.packageSourceSha256);
  const fresh = fixture(); assert.equal(await fresh.api.confirmPackage({ ...job }, ['tablet'], '真实内包'), true);
  assert.equal(fresh.dialogs.length, 0);
});

test('approval for ZIP member A cannot authorize mirror member B with the same container and target types', async () => {
  const f = fixture(), job = await approvedZip(f);
  job.sourceUrl = 'https://mirror.example/packages.zip#qingqi-package=dir%2FB.hap';
  const check = f.api.confirmPackage(job, ['tablet'], 'B 内包'); await tick();
  assert.equal(f.dialogs.length, 2); f.dialogs[1].resolve({ index: 1 }); assert.equal(await check, true);
  assert.equal(JSON.parse(job.deviceCompatibilityFingerprint)[3], 'dir/B.hap');
  const fresh = fixture(); assert.equal(await fresh.api.confirmPackage(job, ['tablet'], 'B 内包'), true);
  assert.equal(fresh.dialogs.length, 0);
  job.sourceUrl = 'https://mirror.example/packages.zip#qingqi-package=dir/A.hap';
  const changed = fresh.api.confirmPackage(job, ['tablet'], 'A 内包'); await tick();
  assert.equal(fresh.dialogs.length, 1); fresh.dialogs[0].resolve({ index: 0 }); assert.equal(await changed, false);
});

test('a changed ZIP inner digest invalidates a real receipt despite unchanged container selector and devices', async () => {
  const f = fixture(), job = await approvedZip(f);
  await f.api.confirmPackage(job, ['tablet'], '内包');
  const fresh = fixture(); job.packageSourceSha256 = 'c'.repeat(64);
  const changed = fresh.api.confirmPackage(job, ['tablet'], '变化的内包'); await tick();
  assert.equal(fresh.dialogs.length, 1); fresh.dialogs[0].resolve({ index: 0 }); assert.equal(await changed, false);
  assert.equal(job.deviceCompatibilityFingerprint, '');
});

test('direct HAP metadata consent cannot authorize a different actual package digest', async () => {
  const f = fixture(), row = asset(), prompt = f.confirm(row); await tick();
  f.dialogs[0].resolve({ index: 1 }); await prompt;
  const job = { id: 'direct', catalogSourceUrl: row.url, sourceUrl: row.url, expectedSha256: row.sha256,
    packageSourceSha256: 'b'.repeat(64), deviceCompatibilityFingerprint: f.api.confirmedFingerprint(row) };
  const changed = f.api.confirmPackage(job, ['tablet'], '变化的HAP'); await tick();
  assert.equal(f.dialogs.length, 2); f.dialogs[1].resolve({ index: 0 }); assert.equal(await changed, false);
});

test('a queued package prompt cannot accept a selector changed while the dialog was open', async () => {
  const f = fixture(), job = await approvedZip(f); job.deviceCompatibilityFingerprint = '';
  const pending = f.api.confirmPackage(job, ['tablet'], 'A 内包'); await tick();
  job.sourceUrl = 'https://mirror.example/packages.zip#qingqi-package=dir/B.hap';
  f.dialogs[1].resolve({ index: 1 }); assert.equal(await pending, false);
  assert.equal(job.deviceCompatibilityFingerprint, '');
});
