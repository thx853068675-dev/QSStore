const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { validate, build, locateDefinitions, generate, isRecognizedAcl, isAutoApplicableAcl,
  AUTO_APPLY_INCLUDE, AUTO_APPLY_EXCLUDE } = require('../tools/prepare_acl_policy.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function row(name, options = {}) {
  return { name: 'ohos.permission.' + name, availableType: 'NORMAL', availableLevel: 'system_basic',
    provisionEnable: true, ...options };
}
function definitions(rows) { return { definePermissions: rows }; }
function loadPolicy(content) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(content, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports });
  return exports.SideloadAclPolicy;
}
function temporary(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-acl-policy-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}
function writeDefinitions(root, rows, defaultAlias = false) {
  const filename = path.join(root, ...(defaultAlias ? ['default'] : []),
    'openharmony', 'toolchains', 'lib', 'PermissionDefinitions.json');
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, JSON.stringify(definitions(rows), null, 2) + '\n');
  return filename;
}

test('only public restricted permissions enabled for Profile grants enter the generated policy', () => {
  const value = build(definitions([
    row('PUBLIC_BASIC'), row('PUBLIC_CORE', { availableLevel: 'system_core' }),
    row('INTERNET', { availableLevel: 'normal' }), row('NO_PROFILE', { provisionEnable: false }),
    row('SYSTEM_ONLY', { availableType: 'SYSTEM' }), row('ENTERPRISE_ONLY', { availableType: 'ENTERPRISE_NORMAL' }),
    row('MDM_ONLY', { availableType: 'MDM' }), row('FUTURE_INTERNAL', { availableType: 'SYSTEM_FUTURE' }),
    row('FILE_ACCESS_PERSIST', { availableLevel: 'normal' })
  ]));
  assert.deepEqual(value.permissions, [
    'ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.PUBLIC_BASIC', 'ohos.permission.PUBLIC_CORE'
  ]);
});

test('recognition, IDE auto-apply scope and AGC approval stay three separate answers', () => {
  const value = build(definitions([
    row('PUBLIC_BASIC'),
    row('READ_DOCUMENT'), row('WRITE_DOCUMENT'),
    row('READ_WRITE_DOWNLOAD_DIRECTORY', { availableLevel: 'normal' }),
    row('READ_WRITE_DOCUMENTS_DIRECTORY', { availableLevel: 'normal' }),
    row('FILE_ACCESS_PERSIST', { availableLevel: 'normal' })
  ]));
  // Both document permissions stay recognized so a package requesting them is
  // reported instead of silently dropped, yet neither may be auto-requested.
  assert.deepEqual(value.permissions, [
    'ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.PUBLIC_BASIC',
    'ohos.permission.READ_DOCUMENT', 'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
    'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY', 'ohos.permission.WRITE_DOCUMENT'
  ]);
  assert.deepEqual(value.autoApplicable, [
    'ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.PUBLIC_BASIC',
    'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY', 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
  ]);
  assert.deepEqual(value.manualOnly, ['ohos.permission.READ_DOCUMENT', 'ohos.permission.WRITE_DOCUMENT']);
  const policy = loadPolicy(value.content);
  const requested = ['ohos.permission.READ_DOCUMENT', 'ohos.permission.PUBLIC_BASIC',
    'ohos.permission.WRITE_DOCUMENT'];
  assert.deepEqual(Array.from(policy.effective(requested)), requested.slice().sort());
  assert.deepEqual(Array.from(policy.autoApplicableAcls(requested)), ['ohos.permission.PUBLIC_BASIC']);
  assert.deepEqual(Array.from(policy.requiringApproval(requested)),
    ['ohos.permission.READ_DOCUMENT', 'ohos.permission.WRITE_DOCUMENT']);
  assert.deepEqual(Array.from(policy.unrecognized([...requested, 'ohos.permission.INTERNET'])),
    ['ohos.permission.INTERNET']);
  // Auto-apply plus AGC approval must together cover every recognized requirement.
  assert.equal(policy.covered(requested, []), false);
  assert.equal(policy.covered(requested, ['ohos.permission.READ_DOCUMENT']), false);
  assert.equal(policy.covered(requested,
    ['ohos.permission.READ_DOCUMENT', 'ohos.permission.WRITE_DOCUMENT']), true);
  assert.equal(policy.covered(['ohos.permission.PUBLIC_BASIC'], []), true);
  assert.equal(policy.covered([], []), true);
});

test('the auto-apply scope is an exact transcription of the DevEco include and exclude rules', () => {
  assert.deepEqual(AUTO_APPLY_INCLUDE, ['ohos.permission.FILE_ACCESS_PERSIST',
    'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY', 'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY']);
  assert.deepEqual(AUTO_APPLY_EXCLUDE,
    ['ohos.permission.READ_DOCUMENT', 'ohos.permission.WRITE_DOCUMENT']);
  assert.equal(isAutoApplicableAcl(row('PUBLIC_BASIC')), true);
  assert.equal(isAutoApplicableAcl(row('PUBLIC_CORE', { availableLevel: 'system_core' })), false,
    'a system_core ACL is recognized but never auto-requestable');
  for (const excluded of AUTO_APPLY_EXCLUDE) assert.equal(isAutoApplicableAcl(row(excluded.replace('ohos.permission.', ''))), false);
  for (const included of AUTO_APPLY_INCLUDE) {
    assert.equal(isAutoApplicableAcl(row(included.replace('ohos.permission.', ''), { availableLevel: 'normal' })), true);
    assert.equal(isAutoApplicableAcl(row(included.replace('ohos.permission.', ''), { availableLevel: 'normal', provisionEnable: false })), false);
    assert.equal(isAutoApplicableAcl(row(included.replace('ohos.permission.', ''), { availableLevel: 'normal', availableType: 'SYSTEM' })), false);
  }
  assert.equal(isRecognizedAcl(row('READ_WRITE_DOWNLOAD_DIRECTORY', { availableLevel: 'normal' })), true);
  assert.equal(isRecognizedAcl(row('INTERNET', { availableLevel: 'normal' })), false);
});

test('a future SDK public restricted ACL is recognized without updating a hand-maintained list', () => {
  const value = build(definitions([row('NEW_SDK_ACL'), row('kernel.NEW_PUBLIC_EXECUTION')]), 'a'.repeat(64));
  const policy = loadPolicy(value.content);
  assert.deepEqual(Array.from(policy.effective([
    'ohos.permission.NEW_SDK_ACL', ' ohos.permission.kernel.NEW_PUBLIC_EXECUTION ',
    'ohos.permission.NEW_SDK_ACL', 'ohos.permission.INTERNET', 'ohos.permission.SYSTEM_ONLY'
  ])), ['ohos.permission.NEW_SDK_ACL', 'ohos.permission.kernel.NEW_PUBLIC_EXECUTION']);
  assert.deepEqual(Array.from(policy.effective([])), [], 'grantable catalog must never mean granting everything');
  assert.match(value.content, /SDK PermissionDefinitions\.json SHA-256: a{64}/);
});

test('legacy compatibility never overrides SDK system-only reclassification or disabled Profile grants', () => {
  for (const legacy of [row('FILE_ACCESS_PERSIST', { availableType: 'SYSTEM' }),
    row('FILE_ACCESS_PERSIST', { availableLevel: 'normal', provisionEnable: false })]) {
    assert.deepEqual(build(definitions([row('PUBLIC_BASIC'), legacy])).permissions, ['ohos.permission.PUBLIC_BASIC']);
  }
});

test('malformed SDK definitions and source hashes fail before a catalog can be generated', () => {
  for (const invalid of [null, [], {}, { definePermissions: [] }, { definePermissions: {} },
    definitions([null]), definitions([row('PUBLIC', { name: "ohos.permission.BROKEN');throw Error('x" })]),
    definitions([row('PUBLIC', { name: 'ohos.permission.PUBLIC.' })]),
    definitions([row('PUBLIC', { availableType: null })]),
    definitions([row('PUBLIC', { availableLevel: 1 })]),
    definitions([row('PUBLIC', { provisionEnable: 'true' })]),
    definitions([row('PUBLIC'), row('PUBLIC')])]) {
    assert.throws(() => validate(invalid), /SDK/);
  }
  assert.throws(() => build(definitions([row('PUBLIC')]), 'not-a-hash'), /SHA-256/);
  assert.throws(() => build(undefined), /SDK PermissionDefinitions/);
  assert.throws(() => build(definitions([row('INTERNET', { availableLevel: 'normal' })])), /no public Profile ACL/);
});

test('SDK root and default aliases resolve the selected SDK without a global fallback', t => {
  const direct = temporary(t), alias = temporary(t);
  const directFile = writeDefinitions(direct, [row('DIRECT')]);
  const aliasFile = writeDefinitions(alias, [row('DEFAULT')], true);
  assert.equal(locateDefinitions(direct), directFile);
  assert.equal(locateDefinitions(alias), aliasFile);
  assert.equal(locateDefinitions(path.join(alias, 'default')), aliasFile);
  assert.throws(() => locateDefinitions(''), /root is missing/);
  assert.throws(() => generate({ sdkRoot: null, projectRoot: direct }), /root is missing/);
  assert.throws(() => generate(null), /options are invalid/);
  const missing = path.join(direct, 'missing-sdk');
  assert.throws(() => generate({ sdkRoot: missing, projectRoot: direct }), /Cannot find compilation SDK/);
  assert.equal(fs.existsSync(path.join(direct, 'entry')), false);
});

test('generation replaces stale policy from the selected SDK and does not rewrite unchanged content', t => {
  const sdkRoot = temporary(t), projectRoot = temporary(t);
  const source = writeDefinitions(sdkRoot, [row('FIRST'), row('FILE_ACCESS_PERSIST', { availableLevel: 'normal' })]);
  const first = generate({ sdkRoot, projectRoot });
  assert.equal(first.permissions, 2); assert.equal(first.changed, true);
  assert.equal(first.sourceHash, crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'));
  const sourceStat = fs.statSync(first.target).mtimeMs;
  const unchanged = generate({ sdkRoot, projectRoot });
  assert.equal(unchanged.changed, false); assert.equal(fs.statSync(first.target).mtimeMs, sourceStat);
  writeDefinitions(sdkRoot, [row('SECOND')]);
  const replacement = generate({ sdkRoot, projectRoot });
  assert.equal(replacement.changed, true); assert.equal(replacement.permissions, 1);
  const content = fs.readFileSync(replacement.target, 'utf8');
  assert.match(content, /ohos.permission.SECOND/); assert.doesNotMatch(content, /ohos.permission.FIRST/);
  assert.notEqual(replacement.sourceHash, first.sourceHash);
});

test('invalid or missing SDK input never falls back to a previously generated catalog', t => {
  const sdkRoot = temporary(t), projectRoot = temporary(t);
  const source = writeDefinitions(sdkRoot, [row('PUBLIC')]);
  const result = generate({ sdkRoot, projectRoot });
  const original = fs.readFileSync(result.target, 'utf8');
  fs.writeFileSync(source, '{ not valid JSON');
  assert.throws(() => generate({ sdkRoot, projectRoot }), /not valid JSON/);
  fs.writeFileSync(source, JSON.stringify(definitions([row('BROKEN', { provisionEnable: 1 })])));
  assert.throws(() => generate({ sdkRoot, projectRoot }), /invalid name or authorization/);
  fs.unlinkSync(source);
  assert.throws(() => generate({ sdkRoot, projectRoot }), /Cannot find compilation SDK/);
  assert.equal(fs.readFileSync(result.target, 'utf8'), original, 'a failed build must not corrupt the last valid source');
});
