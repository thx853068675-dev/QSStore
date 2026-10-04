const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { execFileSync } = require('node:child_process');
const crypto = require('node:crypto'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-package-test-'));
const cli = path.join(dir, 'archive-reader');
before(() => execFileSync('c++', ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-I',
  path.join(root, 'entry/src/main/cpp/hap_core'), path.join(root, 'entry/src/main/cpp/hap_core/zip_reader.cpp'),
  path.join(root, 'entry/src/main/cpp/hap_core/signing_block.cpp'), path.join(root, 'tests/hap_inspect_cli.cpp'), '-lz', '-o', cli]));
after(() => fs.rmSync(dir, { recursive: true, force: true }));
function load(file, mocks) {
  const box = { exports: {}, require: name => mocks[name] || {}, ArrayBuffer, Uint8Array };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets', file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box); return box.exports;
}
const io = { accessSync: fs.existsSync, mkdirSync: p => fs.mkdirSync(p, { recursive: true }),
  OpenMode: { READ_ONLY: 0 }, openSync: p => ({ fd: fs.openSync(p, 'r') }), closeSync: f => fs.closeSync(f.fd),
  statSync: p => typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p), unlinkSync: fs.unlinkSync, renameSync: fs.renameSync,
  copyFile: async (from,to) => typeof from === 'number' ? fs.writeFileSync(to, fs.readFileSync(from)) : fs.promises.copyFile(from,to) };
const native = {
  listPackageEntries: p => execFileSync(cli, [p, 'list'], { encoding: 'utf8' }).trim().split('\n').filter(Boolean).map(line => {
    const [size,name] = line.split('\t'); return { size: Number(size), name }; }),
  extractPackageEntry: async (p,n,o) => { execFileSync(cli,[p,'extract',n,o]); },
  readModuleJson: p => execFileSync(cli,[p], {encoding:'utf8'}),
  readPackInfo: p => execFileSync(cli,[p,'pack'], {encoding:'utf8'}), readHapIcon: () => new Uint8Array()
};
const presentation = load('jobs/PackagePresentation', { 'libhap_core.so': native });
const inspector = load('jobs/PackageInspector', { 'libhap_core.so': native, './PackagePresentation':presentation });
const storage = { StorageBudget: { require: async () => {} } };
const archive = load('jobs/PackageArchive', { './StorageBudget': storage, 'libhap_core.so': native, '@kit.CoreFileKit': {fileIo:io}, './PackageInspector': inspector, './PackagePresentation':presentation });
const jobs = load('jobs/InstallJob', {});
function fixtures(name) {
  const sub = path.join(dir,name); fs.mkdirSync(sub);
  execFileSync('python3',['-c', `import io,zipfile,json,sys,os,random
p=sys.argv[1]
def hap(bundle='com.example.main',module='entry',code=12):
 b=io.BytesIO()
 with zipfile.ZipFile(b,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('module.json',json.dumps({'app':{'bundleName':bundle,'versionCode':code,'versionName':'1.2.0'},'module':{'name':module,'mainElement':'MainAbility' if module=='entry' else ''}}))
 return b.getvalue()
def pack(name,entries):
 with zipfile.ZipFile(os.path.join(p,name),'w',zipfile.ZIP_DEFLATED) as z:
  for n,data in entries:z.writestr(n,data)
open(os.path.join(p,'main.hap'),'wb').write(hap())
pack('multi.app',[('feature.hap',hap(module='feature')),('entry.hap',hap())])
large=io.BytesIO()
with zipfile.ZipFile(large,'w',zipfile.ZIP_STORED) as z:
 with zipfile.ZipFile(io.BytesIO(hap())) as inner:z.writestr('module.json',inner.read('module.json'))
 z.writestr('payload.bin',random.Random(7).randbytes(2*1024*1024))
pack('large.app',[('entry.hap',large.getvalue())])
pack('mixed.app',[('entry.hap',hap()),('other.hap',hap(bundle='com.example.other'))])
app=open(os.path.join(p,'multi.app'),'rb').read()
pack('apps.zip',[('dir/main.hap',hap()),('multi.app',app),('bad.hap',b'bad'),('notes.txt',b'ignore')])
pack('empty.zip',[('bad.hap',b'bad')])
pack('unsafe.zip',[('../escape.hap',hap())])
pack('duplicates.zip',[('main.hap',hap()),('main.hap',hap())])
`,sub],{stdio:['ignore','ignore','pipe']}); return sub;
}
function local(sub,source) {
  const context = { cacheDir:path.join(sub,'cache'),filesDir:path.join(sub,'files') };
  let selected = source, saved;
  const core = {fileIo:io,hash:{hash:async p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')},
    picker:{DocumentViewPicker: class { async select(options) {assert.match(options.fileSuffixFilters[0], /\.app,\.zip/);return [selected];}}}};
  const {LocalImport}=load('jobs/LocalImport',{'./JobStore':{JobStore:{reservePackage:()=>()=>{}}},
    './StorageBudget': storage, '@kit.CoreFileKit':core,'./PackageArchive':archive,'./InstallJob':jobs,'libhap_core.so':native});
  const store={save:async job=>saved=job,enqueueLocal:async(cachePath,signedPath,hash,bundleName,versionCode,versionName,moduleName,mainAbility)=>
    ({cachePath,signedPath,expectedSha256:hash,bundleName,versionCode,versionName,moduleName,mainAbility})};
  return {context,LocalImport,store,saved:()=>saved};
}
test('a real two-module APP previews and commits as one APP with an entry launcher',async()=>{
  const sub=fixtures('app'), f=local(sub,path.join(sub,'multi.app'));
  const [preview]=await f.LocalImport.pickPreviews(f.context);
  assert.equal(preview.moduleName,'entry');assert.equal(preview.versionName,'1.2.0');
  assert.ok(preview.cachePath.endsWith('.app'));
  const job=await f.LocalImport.commitPreview(f.context,f.store,preview);
  assert.ok(job.signedPath.endsWith('.signed.app'));assert.equal(f.saved().assetName,'multi.app');
  assert.equal(native.listPackageEntries(job.cachePath).length,2);
  assert.equal(fs.readdirSync(f.context.cacheDir+'/local-hap-previews').length,0);
});
test('ZIP previews enumerate valid HAP/APP candidates; selection does not enqueue',async()=>{
  const sub=fixtures('zip'),f=local(sub,path.join(sub,'apps.zip'));
  const previews=await f.LocalImport.pickPreviews(f.context);
  assert.deepEqual(Array.from(previews,x=>x.assetName),['dir/main.hap','multi.app']);
  assert.equal(f.saved(),undefined);assert.equal(fs.readdirSync(f.context.cacheDir+'/local-hap-previews').filter(n => !n.includes('.module-')).length,2);
  previews.forEach(p=>f.LocalImport.discardPreview(f.context,p));
  assert.equal(fs.readdirSync(f.context.cacheDir+'/local-hap-previews').length,0);
});
test('invalid APP identities and empty ZIP packages fail without residual previews',async()=>{
 const sub=fixtures('bad');for(const name of ['mixed.app','empty.zip']){
  const f=local(sub,path.join(sub,name));await assert.rejects(f.LocalImport.pickPreviews(f.context));
  assert.equal(fs.readdirSync(f.context.cacheDir+'/local-hap-previews').length,0);
 }
});
test('ZIP selectors reject path escape and a missing entry; duplicate entries are rejected',async()=>{
 const sub=fixtures('security');
 for(const value of ['../escape.hap','/absolute.hap','dir\\\\escape.hap'])
  assert.throws(()=>archive.PackageArchive.selectedEntry('https://github.com/o/r/a.zip#qingqi-package='+encodeURIComponent(value)));
 await assert.rejects(archive.PackageArchive.extractSelected(path.join(sub,'apps.zip'),'missing.hap',path.join(sub,'missing.hap')));
 assert.throws(()=>native.listPackageEntries(path.join(sub,'duplicates.zip')));
 assert.equal(fs.existsSync(path.join(sub,'missing.hap')),false);
});


test('online APP and ZIP-selected APP downloads inspect module identity before entering the signing queue', async () => {
  const sub = fixtures('online');
  const { DownloadJobs } = load('jobs/DownloadJobs', {
    '@kit.AbilityKit': {}, './PackageArchive': archive, './PackageInspector': inspector, './InstallJob': jobs,
    './AssetDownload': { AssetDownload: class { async downloadAndVerify(_job, _progress, validate) { await validate(); } } }
  });
  for (const selected of [false, true]) {
    const source = path.join(sub, selected ? 'apps.zip' : 'multi.app');
    const cache = path.join(sub, selected ? 'archive-cache.app' : 'direct-cache.app');
    fs.copyFileSync(source, cache);
    const job = { cachePath: cache, sourceUrl: 'https://github.com/o/r/release' +
      (selected ? '.zip#qingqi-package=multi.app' : '.app'), catalogBundleName: 'com.example.main', catalogVersionCode: 12 };
    const sha = crypto.createHash('sha256').update(fs.readFileSync(cache)).digest('hex');
    const saved = [], store = { save: async j => saved.push(j.stage), recordFailure: async () => {} };
    await DownloadJobs.runLocked({}, store, job);
    assert.equal(job.stage, jobs.InstallStage.PACKAGE_INSPECTED);
    assert.equal(job.bundleName, 'com.example.main'); assert.equal(job.moduleName, 'entry');
    assert.equal(job.versionCode, 12); assert.equal(job.versionName, '1.2.0');
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(cache)).digest('hex'), sha);
    archive.PackageArchive.release(selected ? cache + '.package.app' : cache);
    assert(!fs.readdirSync(sub).some(name => name.includes('.module-')));
  }
});


test('streaming extraction refills input after a full output buffer instead of rejecting a large valid APP', async () => {
  const sub = fixtures('large-stream');
  const f = local(sub, path.join(sub, 'large.app'));
  const [preview] = await f.LocalImport.pickPreviews(f.context);
  assert.equal(preview.versionCode, 12); assert.equal(preview.moduleName, 'entry');
  f.LocalImport.discardPreview(f.context, preview);
  assert.equal(fs.readdirSync(f.context.cacheDir+'/local-hap-previews').length, 0);
});

test('single-package publication stays compatible with the old API and multi-selection requires server capability', async () => {
  const release = load('data/ReleaseInfo', {});
  const catalog = load('data/CatalogApp', { './ReleaseInfo': release });
  const actions = load('data/StoreActions', {});
  const { StoreClient } = load('data/StoreClient', { './CatalogApp': catalog, './ReleaseInfo': release,
    './StoreActions': actions, '@kit.ArkTS': { util: { TextDecoder: class { decodeToString() { return 'ca'; } } } }, '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' } } } });
  const client = new StoreClient({ resourceManager: { getRawFileContentSync: () => new Uint8Array() } }), captured = [];
  client.requestData = async (...args) => { captured.push(args[3]); return { app: { id: 7 } }; };
  const draft = actions.SubmitDraft.fromJson({ draft_token: 'test', inspection_status: 'ready' });
  await client.confirmSubmit(draft, ['main.hap'], '工具', {});
  assert.equal(captured[0].asset_name, 'main.hap');
  assert.deepEqual(Array.from(captured[0].asset_names), ['main.hap']);
  await assert.rejects(client.confirmSubmit(draft, ['main.hap', 'other.app'], '工具', {}), /先更新服务端/);
  assert.equal(captured.length, 1);
  draft.supportsMultiSelect = true;
  await client.confirmSubmit(draft, ['main.hap', 'other.app'], '工具', {});
  assert.deepEqual(Array.from(captured[1].asset_names), ['main.hap', 'other.app']);
});

test('APP inspection and icon reuse extracted modules; a changed file invalidates the cache', async () => {
  const sub = fixtures('reuse'), source = path.join(sub, 'multi.app');
  const original = native.extractPackageEntry;
  let extractions = 0;
  native.extractPackageEntry = async (...args) => { extractions++; return original(...args); };
  try {
    await archive.PackageArchive.inspect(source);
    await archive.PackageArchive.icon(source);
    await archive.PackageArchive.inspect(source);
    assert.equal(extractions, 2);
    const next = new Date(Date.now() + 2000); fs.utimesSync(source, next, next);
    await archive.PackageArchive.inspect(source);
    assert.equal(extractions, 4);
    archive.PackageArchive.release(source);
    assert(!fs.readdirSync(sub).some(n => n.includes('.module-')));
  } finally { native.extractPackageEntry = original; archive.PackageArchive.release(source); }
});
