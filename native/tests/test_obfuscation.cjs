const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { collectContracts, loadParser, prepare } = require('../tools/prepare_obfuscation.cjs');

test('release contracts preserve legacy JSON without exposing core class/method names', () => {
  const ts = loadParser();
  const names = collectContracts(ts, `
    class LocalLease { id: string = ''; accountId: string = ''; private expiresAt: number = 0; }
    export class SigningCore { static signInternal(): void {} private verifySecret(): void {} }
    interface NativeEntry { name: string; path: string; size: number; }
    const body = { certificateId: '1', category: 'tools' };
    const identity = oldRecord['keyPath'];
    Object.defineProperty(body, 'legacyName', { value: 'old' });
  `, 'contracts.ets');
  for (const name of ['id', 'accountId', 'expiresAt', 'name', 'path', 'size', 'certificateId',
    'category', 'keyPath', 'legacyName']) assert.ok(names.has(name), name);
  for (const name of ['LocalLease', 'SigningCore', 'signInternal', 'verifySecret']) assert.ok(!names.has(name), name);
});

test('ArkUI string callbacks retain the same names after release obfuscation', () => {
  const names = collectContracts(loadParser(), `
    @Component struct MyPage {
      @State @Watch('syncRows') private rows: string[] = [];
      private syncRows(): void {}
      build() { Row() { Text('test') } }
    }
  `, 'watch.ets');
  assert.ok(names.has('syncRows'));
});

test('current release keeps route and native ABI names, not entire signing source files', () => {
  const result = prepare();
  assert.ok(result.files > 100);
  const root = path.resolve(__dirname, '..');
  const contracts = fs.readFileSync(path.join(root, 'entry/obfuscation-contracts.txt'), 'utf8');
  for (const name of ['Index', 'InstalledDetail', 'LocalInstall', 'EntryAbility', 'signHap',
    'keyMatchesCertificate', 'profilePath', 'signingCertId', 'accessToken', 'syncManagementRows']) {
    assert.ok(contracts.split('\n').includes(name), name);
  }
  assert.ok(!contracts.split('\n').includes('SigningIdentity'));
  const rules = fs.readFileSync(path.join(root, 'entry/obfuscation-rules.txt'), 'utf8');
  const options = rules.split('\n').filter(line => line.startsWith('-'));
  for (const option of ['-enable-property-obfuscation', '-enable-export-obfuscation',
    '-enable-toplevel-obfuscation', '-enable-filename-obfuscation']) assert.ok(options.includes(option));
  assert.ok(!options.includes('-enable-string-property-obfuscation'));
  assert.ok(!options.includes('-remove-log'));
});

test('real ArkGuard preserves legacy JSON while renaming implementation classes and private methods', async () => {
  const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
  const { ArkObfuscator, clearGlobalCaches } = require(path.join(sdkRoot,
    'default/openharmony/ets/build-tools/ets-loader/node_modules/arkguard'));
  const ts = loadParser();
  const source = `
    class ObfuscationSigningCoreFixture {
      certId: string = '';
      accountId: string = '';
      private expiresAt: number = 0;
      private deriveInternalSignatureFixture(value: number): number { return value * 7; }
      runFixture(): void {
        const legacy = JSON.parse('{"certId":"old-cert","accountId":"old-account","expiresAt":42}');
        this.certId = legacy.certId;
        this.accountId = legacy.accountId;
        this.expiresAt = legacy.expiresAt;
        globalThis['fixtureResult'] = {
          digest: this.deriveInternalSignatureFixture(this.expiresAt),
          snapshot: JSON.stringify(this)
        };
      }
    }
    new ObfuscationSigningCoreFixture().runFixture();
  `;
  const contracts = fs.readFileSync(path.resolve(__dirname, '../entry/obfuscation-contracts.txt'), 'utf8');
  const currentNames = contracts.split('-keep-property-name\n')[1].split('-keep-file-name')[0]
    .split('\n').map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  const names = [...new Set([...currentNames, ...collectContracts(ts, source, 'fixture.ts')])];
  const obfuscator = new ArkObfuscator();
  try {
    assert.equal(obfuscator.init({
      mNameObfuscation: {
        mEnable: true, mNameGeneratorType: 1, mRenameProperties: true,
        mTopLevel: true, mKeepStringProperty: true,
        mReservedProperties: names, mReservedToplevelNames: ['JSON', 'globalThis']
      },
      mExportObfuscation: true, mEnableNameCache: true
    }), true);
    // In-memory paths identify the source; no fixture or mapping files are written.
    const result = await obfuscator.obfuscate(source, {
      buildFilePath: path.join(__dirname, 'obfuscation-fixture.ts'),
      relativeFilePath: 'obfuscation-fixture.ts'
    });
    assert.ok(!result.content.includes('ObfuscationSigningCoreFixture'), 'class name must change');
    assert.ok(!result.content.includes('deriveInternalSignatureFixture'), 'private method must change');
    const output = ts.transpileModule(result.content, {
      compilerOptions: { target: ts.ScriptTarget.ES2018, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const context = {};
    vm.runInNewContext(output, context, { timeout: 1000 });
    assert.equal(context.fixtureResult.digest, 294);
    assert.deepEqual(JSON.parse(context.fixtureResult.snapshot), {
      certId: 'old-cert', accountId: 'old-account', expiresAt: 42
    });
  } finally {
    clearGlobalCaches();
  }
});
