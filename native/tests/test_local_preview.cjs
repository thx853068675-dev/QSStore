const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const vm = require('node:vm');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {} });
  return exports;
}
const jobs = load('jobs/InstallJob');
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hap-preview-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const context = { cacheDir: path.join(dir, 'cache'), filesDir: path.join(dir, 'files') };
  const identity = { bundleName: 'com.example.preview', versionCode: 12, versionName: '1.2.0',
    moduleName: 'entry', mainAbility: 'EntryAbility' };
  const source = path.join(dir, 'source.hap'); fs.writeFileSync(source, JSON.stringify(identity));
  let selection = [source], enqueues = 0;
  const fileIo = {
    OpenMode: { READ_ONLY: 0 },
    accessSync: fs.existsSync, mkdirSync: p => fs.mkdirSync(p, { recursive: true }),
    openSync: p => ({ fd: fs.openSync(p, 'r') }), closeSync: p => fs.closeSync(p.fd),
    statSync: fs.statSync, renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
    copyFile: async (from, to) => typeof from === 'number' ?
      fs.writeFileSync(to, fs.readFileSync(from)) : fs.promises.copyFile(from, to)
  };
  const { LocalImport } = load('jobs/LocalImport', {
    './InstallJob': jobs, './PackageInspector': { inspectPackage: p => JSON.parse(fs.readFileSync(p)) },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async p =>
      crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex') },
    picker: { DocumentViewPicker: class { async select() { return selection; } } } }
  });
  const store = { async enqueueLocal(cachePath, signedPath, sha256, bundleName, versionCode,
    versionName, moduleName, mainAbility) {
    enqueues++;
    return { id: 'local:' + sha256, cachePath, signedPath, expectedSha256: sha256,
      bundleName, versionCode, versionName, moduleName, mainAbility, stage: 'package_inspected' };
  } };
  return { context, identity, source, LocalImport, store, setSelection: v => selection = v,
    enqueues: () => enqueues };
}
test('selecting a HAP copies its metadata for preview without creating an install task', async t => {
  const f = fixture(t), original = fs.readFileSync(f.source);
  const preview = await f.LocalImport.pickPreview(f.context);
  assert.equal(f.enqueues(), 0); assert.equal(preview.versionName, '1.2.0');
  assert.equal(preview.bundleName, f.identity.bundleName);
  assert.ok(preview.cachePath.startsWith(f.context.cacheDir + '/local-hap-previews/'));
  assert.deepEqual(fs.readFileSync(f.source), original);
});
test('explicit installation promotes the preview and enqueues exactly one task', async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  const job = await f.LocalImport.commitPreview(f.context, f.store, preview);
  assert.equal(f.enqueues(), 1); assert.equal(job.versionName, '1.2.0');
  assert.ok(job.cachePath.startsWith(f.context.filesDir + '/install-jobs/'));
  assert.equal(fs.existsSync(preview.cachePath), false);
  assert.deepEqual(fs.readFileSync(job.cachePath), fs.readFileSync(f.source));
});
test('a changed preview is rejected before creating a task and remains selectable for retry', async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  fs.appendFileSync(preview.cachePath, 'changed');
  await assert.rejects(f.LocalImport.commitPreview(f.context, f.store, preview), /预览文件已变化/);
  assert.equal(f.enqueues(), 0); assert.equal(fs.existsSync(preview.cachePath), true);
});
test('cancelled selection and malformed metadata never leave staged preview files', async t => {
  const f = fixture(t); f.setSelection([]);
  await assert.rejects(f.LocalImport.pickPreview(f.context), /未选择 HAP/);
  f.setSelection([f.source]); fs.writeFileSync(f.source, 'not a package');
  await assert.rejects(f.LocalImport.pickPreview(f.context));
  assert.deepEqual(fs.readdirSync(f.context.cacheDir + '/local-hap-previews'), []);
  assert.equal(fs.readFileSync(f.source, 'utf8'), 'not a package');
});
test('discarding a preview cannot delete files in the committed installation directory', async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  f.LocalImport.discardPreview(f.context, { cachePath: f.source });
  assert.equal(fs.existsSync(f.source), true);
  f.LocalImport.discardPreview(f.context, preview);
  assert.equal(fs.existsSync(preview.cachePath), false);
});
function page(names, globals) {
  const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return new box.Page();
}
test('the local page selection action only displays a preview and never starts installation', async () => {
  const preview = { id: 'local:hash', cachePath: '/preview.hap', versionName: '1.2.0' };
  const ui = page(['pickLocalHap'], { getContext: () => ({}),
    LocalImport: { pickPreview: async () => preview }, fileIo: { statSync: () => ({ size: 1048576 }) } });
  Object.assign(ui, { localPreviewReady: false, loadLocalIcon: async () => {},
    refreshLocalTimeline: () => {}, continueInstall: () => assert.fail('selection must not install'),
    loadJobs: () => assert.fail('selection must not enqueue') });
  await ui.pickLocalHap();
  assert.equal(ui.localPreviewReady, true); assert.equal(ui.localInfoJob, preview);
  assert.equal(ui.localFileSize, '1.0 MB'); assert.equal(ui.localBusy, false);
});
test('the Install action queues the selected local HAP even when another job is active', async () => {
  const job = { id: 'local:hash', stage: 'package_inspected' }; let saved, drains = 0;
  const ui = page(['installLocalPreview'], { getContext: () => ({}), InstallStage: jobs.InstallStage,
    errorText: String, JobStore: { open: async () => ({ save: async row => saved = row.stage }) },
    LocalImport: { commitPreview: async () => job } });
  Object.assign(ui, { localBusy: false, localPreviewReady: true, localJobId: job.id,
    localInfoJob: job, activeJobId: 'another-job', jobRunning: () => false,
    loadJobs: async () => {}, refreshLocalTimeline: () => {}, drainInstallQueue: () => drains++ });
  await ui.installLocalPreview();
  assert.equal(saved, 'queued'); assert.equal(drains, 1); assert.equal(ui.localPreviewReady, false);
});
test('an old installed record must be queued for live verification rather than treated as this installation being complete', async () => {
  const job = { id: 'local:older', stage: 'installed' }; let saved;
  const ui = page(['installLocalPreview'], { getContext: () => ({}), InstallStage: jobs.InstallStage,
    errorText: String, JobStore: { open: async () => ({ save: async row => saved = row.stage }) },
    LocalImport: { commitPreview: async () => job } });
  Object.assign(ui, { localBusy: false, localPreviewReady: true, localJobId: job.id,
    localInfoJob: job, jobRunning: () => false, loadJobs: async () => {},
    refreshLocalTimeline: () => {}, drainInstallQueue: () => {} });
  await ui.installLocalPreview();
  assert.equal(saved, 'queued');
});
