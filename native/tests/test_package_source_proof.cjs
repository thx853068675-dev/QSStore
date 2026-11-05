const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

const { InstallJob } = loadEts('jobs/InstallJob');
const { PackageIdentity, PackageInspectError, checkCatalogIdentity } = loadEts('jobs/PackageInspector');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function fixture(extension = '.hap', selectedExtension = '') {
  const f = { hashes: [], parsed: [], extracted: [], writes: [], cancelled: false, allowed: true,
    hashValue: 'b'.repeat(64), hashGate: undefined, parseError: undefined };
  const identity = Object.assign(new PackageIdentity(), { bundleName: 'com.example.app',
    versionCode: 42, versionName: '1.2.3', moduleName: 'entry', mainAbility: 'EntryAbility' });
  const parse = async path => {
    f.parsed.push(path);
    if (f.parseError) throw f.parseError;
    return { ...identity, ...f.identity };
  };
  const privacy = { assertBusinessAllowed() { if (!f.allowed) throw Error('隐私同意已撤回'); } };
  const { NativeJobRuntime } = loadEts('jobs/NativeJobRuntime', {
    '@kit.CoreFileKit': { hash: { hash: async path => {
      f.hashes.push(path);
      if (f.hashGate) await f.hashGate.promise;
      return f.hashValue;
    } } },
    './PackageInspector': { PackageInspectError, checkCatalogIdentity, inspectPackage: parse },
    './PackageArchive': { PackageArchive: {
      installablePath: async path => path,
      inspect: parse,
      selectedEntry: url => decodeURIComponent(url.split('#qingqi-package=')[1] || ''),
      extension: path => path.endsWith('.app') ? '.app' : '.hap',
      extractSelected: async (container, entry, output) => {
        f.extracted.push({ container, entry, output }); return output;
      }
    } },
    './JobCancellation': { JobCancellation: { assertActive() { if (f.cancelled) throw Error('安装任务已取消'); } } },
    './JobRunner': { PackageIdentity, JobFailure: class extends Error {
      constructor(kind, message) { super(message); this.failureKind = kind; }
    } },
    './InstallJob': { ...loadEts('jobs/InstallJob') },
    '../data/PrivacyConsent': { PrivacyConsent: privacy }
  });
  f.job = Object.assign(new InstallJob(), { id: 'package-source', cachePath: '/private/source' + extension,
    expectedSha256: 'a'.repeat(64), catalogBundleName: identity.bundleName, catalogVersionCode: 42,
    sourceUrl: selectedExtension ? 'https://github.com/o/r/releases/download/v1/package.zip#qingqi-package=selected' + selectedExtension : 'local' });
  f.runtime = new NativeJobRuntime({}, { save: async job => f.writes.push(job) }, undefined, {});
  return f;
}

test('direct HAP and whole APP reuse the verified original digest without another hash or journal write', async () => {
  for (const extension of ['.hap', '.app']) {
    const f = fixture(extension);
    f.job.expectedSha256 = 'A'.repeat(64);
    const result = await f.runtime.inspectPackage(f.job);
    assert.equal(result.bundleName, 'com.example.app');
    assert.equal(f.job.packageSourceSha256, 'a'.repeat(64));
    assert.deepEqual(f.parsed, [f.job.cachePath]);
    assert.equal(f.hashes.length, 0); assert.equal(f.writes.length, 0);
  }
});

test('a ZIP receipt records the extracted HAP or whole APP digest, not the ZIP or an APP module digest', async () => {
  for (const entry of ['.hap', '.app']) {
    const f = fixture('.zip', entry);
    await f.runtime.inspectPackage(f.job);
    assert.equal(f.job.expectedSha256, 'a'.repeat(64), 'retain container digest for download recovery');
    assert.equal(f.job.packageSourceSha256, 'b'.repeat(64));
    assert.deepEqual(f.hashes, [f.job.cachePath + '.package' + entry]);
    assert.deepEqual(f.parsed, f.hashes);
    await f.runtime.inspectPackage(f.job);
    assert.equal(f.hashes.length, 1, 'renewal/profile reinspection reuses this runner’s verified package digest');
    assert.equal(f.extracted.length, 1); assert.equal(f.writes.length, 0);
  }
});

test('a changed container digest invalidates the in-memory selected-package proof', async () => {
  const f = fixture('.zip', '.app');
  await f.runtime.inspectPackage(f.job);
  f.job.expectedSha256 = 'c'.repeat(64); f.hashValue = 'd'.repeat(64);
  await f.runtime.inspectPackage(f.job);
  assert.equal(f.hashes.length, 2); assert.equal(f.job.packageSourceSha256, 'd'.repeat(64));
  assert.equal(f.extracted.length, 2);
});

test('same-container selector changes reextract and hash the actual new package at the same output path', async () => {
  const f = fixture('.zip', '.hap');
  await f.runtime.inspectPackage(f.job);
  f.job.sourceUrl = 'https://mirror.example/package.zip#qingqi-package=other.hap';
  f.hashValue = 'c'.repeat(64);
  await f.runtime.inspectPackage(f.job);
  assert.equal(f.job.expectedSha256, 'a'.repeat(64));
  assert.equal(f.job.packageSourceSha256, 'c'.repeat(64));
  assert.deepEqual(f.extracted.map(row => row.entry), ['selected.hap', 'other.hap']);
  assert.equal(f.hashes.length, 2);
  assert.equal(f.extracted[0].output, f.extracted[1].output);
});

test('missing direct-package digests are computed once instead of trusting an old journal field', async () => {
  const f = fixture('.app'); f.job.expectedSha256 = ''; f.job.packageSourceSha256 = 'c'.repeat(64);
  await f.runtime.inspectPackage(f.job); await f.runtime.inspectPackage(f.job);
  assert.deepEqual(f.hashes, [f.job.cachePath]);
  assert.equal(f.job.packageSourceSha256, 'b'.repeat(64));
});

test('parse failures, wrong bundle/version and cancelled inspection never create package-source evidence', async () => {
  for (const failure of ['parse', 'bundle', 'version', 'cancel']) {
    const f = fixture('.zip', '.hap');
    if (failure === 'parse') f.parseError = new PackageInspectError('坏包');
    if (failure === 'bundle') f.identity = { bundleName: 'com.example.other' };
    if (failure === 'version') f.identity = { versionCode: 43 };
    if (failure === 'cancel') f.cancelled = true;
    await assert.rejects(f.runtime.inspectPackage(f.job));
    assert.equal(f.job.packageSourceSha256, ''); assert.equal(f.hashes.length, 0);
  }
});

test('cancellation or privacy withdrawal while hashing rejects the late result without publishing its proof', async () => {
  for (const withdraw of [false, true]) {
    const f = fixture('.zip', '.app'); f.hashGate = deferred();
    const inspecting = f.runtime.inspectPackage(f.job); await tick();
    if (withdraw) f.allowed = false; else f.cancelled = true;
    f.hashGate.resolve(); await assert.rejects(inspecting);
    assert.equal(f.job.packageSourceSha256, ''); assert.equal(f.writes.length, 0);
  }
});

test('a malformed digest cannot become a trusted editing baseline', async () => {
  const f = fixture('.zip', '.hap'); f.hashValue = 'invalid';
  await assert.rejects(f.runtime.inspectPackage(f.job), /摘要无效/);
  assert.equal(f.job.packageSourceSha256, '');
});
