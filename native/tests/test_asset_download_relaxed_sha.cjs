const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function loadAssetDownload(mocks) {
  const cancellation = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/JobCancellation.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports: cancellation });
  const file = path.join(__dirname, '../entry/src/main/ets/jobs/AssetDownload.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: name => mocks[name] ||
    (name === './JobCancellation' ? cancellation : {}),
    setTimeout, clearTimeout });
  return exports.AssetDownload;
}

test('catalog identity still rejects a different application or version', () => {
  const file = path.join(__dirname, '../entry/src/main/ets/jobs/PackageInspector.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: () => ({}) });
  const actual = { bundleName: 'com.example.app', versionCode: 42 };
  exports.checkCatalogIdentity('com.example.app', 42, actual);
  assert.throws(() => exports.checkCatalogIdentity('com.example.other', 42, actual), /包名/);
  assert.throws(() => exports.checkCatalogIdentity('com.example.app', 43, actual), /版本/);
});

test('a completed HTTPS HAP installs despite a stale catalog SHA-256', async () => {
  const partPath = '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.hap.part';
  const files = new Set();
  const states = { initialized: 0, completed: 1 };
  let started = false;
  let removed = false;
  const request = { agent: {
    Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 }, State: {
      INITIALIZED: states.initialized, COMPLETED: states.completed
    },
    create: async () => ({ tid: 'transfer-1', start: async () => {
      started = true;
      files.add(partPath);
    } }),
    show: async () => ({ progress: { state: started ? states.completed : states.initialized,
      processed: 100, sizes: [100] } }),
    remove: async () => { removed = true; }
  } };
  const fileIo = {
    accessSync: name => files.has(name),
    renameSync: (oldName, newName) => { files.delete(oldName); files.add(newName); },
    unlinkSync: name => files.delete(name),
    mkdirSync: () => {}
  };
  const AssetDownload = loadAssetDownload({
    '@kit.BasicServicesKit': { request, BusinessError: class {} },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async () => 'b'.repeat(64) } },
    './InstallTaskState': { InstallTaskState: { downloadProgress: () => {} } }
  });
  const job = { id: '7:app.hap:' + 'a'.repeat(64), appId: 7,
    sourceUrl: 'https://example.org/app.hap', mirrorUrls: [],
    expectedSha256: 'a'.repeat(64),
    cachePath: '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.hap',
    signedPath: '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.signed.hap',
    transferTaskId: '' };
  const store = { save: async () => {} };
  const downloader = new AssetDownload({ filesDir: '/sandbox' }, store);
  await downloader.downloadAndVerify(job);
  assert.equal(job.expectedSha256, 'b'.repeat(64));
  assert.equal(await downloader.verifiedFileExists(job), true);
  assert.equal(files.has(job.cachePath), true);
  assert.equal(removed, true);
});

test('a release without SHA-256 downloads into a persistent cache path', async () => {
  const files = new Set();
  let saveas = '';
  let started = false;
  const request = { agent: {
    Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 }, State: {
      INITIALIZED: 0, COMPLETED: 1
    },
    create: async (_context, config) => {
      saveas = config.saveas;
      return { tid: 'transfer-2', start: async () => {
        started = true;
        files.add(saveas);
      } };
    },
    show: async () => ({ progress: { state: started ? 1 : 0,
      processed: 100, sizes: [100] } }),
    remove: async () => {}
  } };
  const fileIo = { accessSync: name => files.has(name), mkdirSync: () => {},
    unlinkSync: name => files.delete(name),
    renameSync: (oldName, newName) => { files.delete(oldName); files.add(newName); } };
  const AssetDownload = loadAssetDownload({
    '@kit.BasicServicesKit': { request, BusinessError: class {} },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async () => 'c'.repeat(64) } },
    './InstallTaskState': { InstallTaskState: { downloadProgress: () => {} } }
  });
  const job = { id: '7:app.hap:https://example.org/app.hap', appId: 7,
    sourceUrl: 'https://example.org/app.hap', mirrorUrls: [],
    expectedSha256: '', cachePath: '', signedPath: '', transferTaskId: '' };
  const saves = [];
  const downloader = new AssetDownload({ filesDir: '/sandbox' }, {
    save: async value => saves.push({ cachePath: value.cachePath, digest: value.expectedSha256 })
  });
  await downloader.downloadAndVerify(job);
  assert.match(job.cachePath, /\/7-download-[^/]+\.hap$/);
  assert.equal(job.expectedSha256, 'c'.repeat(64));
  assert.equal(files.has(job.cachePath), true);
  assert.ok(saves.some(row => row.cachePath === job.cachePath && row.digest === ''));
  assert.ok(saves.some(row => row.cachePath === job.cachePath && row.digest === 'c'.repeat(64)));
});
