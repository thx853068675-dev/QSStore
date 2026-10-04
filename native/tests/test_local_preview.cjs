const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
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
    statSync: p => typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p), renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
    copyFile: async (from, to) => typeof from === 'number' ?
      fs.writeFileSync(to, fs.readFileSync(from)) : fs.promises.copyFile(from, to)
  };
  const { LocalImport } = load('jobs/LocalImport', {
    './JobStore': { JobStore: { reservePackage: () => () => {} } },
    './StorageBudget': { StorageBudget: { require: async () => {} } },
    './InstallJob': jobs, './PackageArchive': { PackageArchive: { release: () => {}, inspect: async p => JSON.parse(fs.readFileSync(p)),
      extension: name => name.toLowerCase().endsWith('.app') ? '.app' : '.hap' } },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async p =>
      crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex') },
    picker: { DocumentViewPicker: class { async select() { return selection; } } } }
  });
  const store = { async save() {}, async enqueueLocal(cachePath, signedPath, sha256, bundleName, versionCode,
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
for (const renewal of [true, false]) test('explicit local import resets old approval and renewal state; renewal=' + renewal, async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  const existing = jobs.InstallJob.create(preview.id, 0, 'old.hap', 'local', preview.expectedSha256);
  Object.assign(existing, { stage: jobs.InstallStage.INSTALLED, allowDataLoss: true,
    renewalRequestedAt: 123, renewalPreparedAt: 123, renewalPreviousExpiry: 456,
    renewalExpiresAt: 789, renewalInstallBaseline: 987, signedProfileSha256: 'old' });
  const { JobStore } = load('jobs/JobStore', { './InstallJob': jobs, './RecoveryPlanner': {isPending:()=>false} });
  const store = new JobStore({}); store.get = async () => existing; store.save = async () => {};store.listAll=async()=>[existing];
  const job = await f.LocalImport.commitPreview(f.context, store, preview, renewal);
  assert.equal(job.allowDataLoss, false); assert.equal(job.reinstallRequired, true);
  assert.equal(job.renewalPreparedAt, 0); assert.equal(job.renewalPreviousExpiry, 0);
  assert.equal(job.renewalExpiresAt, 0); assert.equal(job.renewalInstallBaseline, 0);
  if (renewal) assert.equal(job.signedProfileSha256, '');
  if (renewal) assert.ok(job.renewalRequestedAt > 123); else assert.equal(job.renewalRequestedAt, 0);
  if(renewal){assert.notEqual(job.id,existing.id);assert.equal(existing.renewalPreparedAt,123);assert.equal(existing.allowDataLoss,true);}
});
for (const previousStage of [jobs.InstallStage.INSTALLED, jobs.InstallStage.TERMINAL_ERROR])
for (const pruned of [true, false]) test('reimporting a local package binds the fresh source; stage=' + previousStage + ', cleanup=' + pruned, async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  const existing = jobs.InstallJob.create(preview.id, 0, 'old.hap', 'local', preview.expectedSha256);
  existing.stage = previousStage;
  if(previousStage === jobs.InstallStage.TERMINAL_ERROR) {
    existing.renewalRequestedAt = 123; existing.renewalPreviousExpiry = 456;
    existing.profilePath = '/previous/original.p7b';
  }
  existing.cachePath = pruned ? '' : '/previous/source.hap';
  existing.signedPath = pruned ? '' : '/previous/source.signed.hap';
  existing.lastError = 'old error';
  const { JobStore } = load('jobs/JobStore', { './InstallJob': jobs, './RecoveryPlanner': {isPending:()=>false} });
  const store = new JobStore({});
  store.get = async () => existing;
  store.save = async () => {};
  store.listAll=async()=>[existing];
  const job = await f.LocalImport.commitPreview(f.context, store, preview, previousStage === jobs.InstallStage.TERMINAL_ERROR);
  if(previousStage===jobs.InstallStage.TERMINAL_ERROR)assert.notEqual(job,existing);else assert.equal(job,existing);
  assert.ok(job.cachePath.startsWith(f.context.filesDir + '/install-jobs/local-'));
  if(previousStage===jobs.InstallStage.TERMINAL_ERROR)assert.match(job.signedPath,/\.renew-.*\.signed\.hap$/);
  else assert.equal(job.signedPath, job.cachePath.replace(/\.hap$/, '.signed.hap'));
  assert.deepEqual(fs.readFileSync(job.cachePath), fs.readFileSync(f.source));
  assert.equal(job.expectedSha256, preview.expectedSha256);
  assert.equal(job.bundleName, f.identity.bundleName);
  assert.equal(job.versionName, f.identity.versionName);
  assert.equal(job.reinstallRequired, true);
  assert.equal(job.stage, jobs.InstallStage.PACKAGE_INSPECTED);
  assert.equal(job.lastError, '');
  if(previousStage === jobs.InstallStage.TERMINAL_ERROR) {
    assert.equal(job.renewalPreviousExpiry,0);assert.equal(job.profilePath,'');
    assert.equal(existing.renewalPreviousExpiry,456);assert.equal(existing.profilePath,'/previous/original.p7b');
  }
});
test('a changed preview is rejected before creating a task and remains selectable for retry', async t => {
  const f = fixture(t), preview = await f.LocalImport.pickPreview(f.context);
  fs.appendFileSync(preview.cachePath, 'changed');
  await assert.rejects(f.LocalImport.commitPreview(f.context, f.store, preview), /预览文件已变化/);
  assert.equal(f.enqueues(), 0); assert.equal(fs.existsSync(preview.cachePath), true);
});
test('cancelled selection and malformed metadata never leave staged preview files', async t => {
  const f = fixture(t); f.setSelection([]);
  await assert.rejects(f.LocalImport.pickPreview(f.context), /未选择安装文件/);
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
  const source = fs.readFileSync(path.join(root, 'pages/LocalInstall.ets'), 'utf8');
  const methods = names.map(name => {
    const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
    assert.notEqual(start, -1, name);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.join('\n')} }; globalThis.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const instance = new box.Page(); if (!instance.onExternalFileOpen) instance.onExternalFileOpen = () => {}; return instance;
}
test('the local installation page selection action only previews, never starts installation', async () => {
  const preview = { id: 'local:hash', cachePath: '/preview.hap', versionName: '1.2.0' };
  const ui = page(['pick'], { getContext: () => ({}), errorText: String,
    LocalTimelineView: class {}, LocalImport: { pickPreviews: async () => [preview] } });
  Object.assign(ui, { disposed: false, busy: false, preview: false, choices: [],
    discard() {}, choose: async job => { ui.selected = job; },
    resume: () => assert.fail('selection must not install') });
  await ui.pick();
  assert.equal(ui.preview, true); assert.equal(ui.selected, preview); assert.equal(ui.busy, false);
});
function installPage(job, signedIn = true) {
  let saved = [], drains = 0;
  const ui = page(['install'], { getContext: () => ({}), InstallStage: jobs.InstallStage,
    errorText: String, JobScheduler: { isRunning: () => false },
    JobStore: { open: async () => ({ save: async row => saved.push(row.stage) }) },
    AccountService: { current: async () => signedIn ? {} : undefined }, LocalBundles: { isSelfBundle: () => false },
    InstallCoordinator: { recovered: async () => drains++ },
    LocalImport: { commitPreview: async () => job } });
  Object.assign(ui, { busy: false, preview: true, selected: job, choices: [], disposed: false,
    discard() {}, refreshTimeline() {}, resume: () => assert.fail('new work must use the FIFO') });
  return { ui, saved, drains: () => drains };
}
for (const signedIn of [false,true]) test('store renewal hands off to the FIFO and shows a missing account explicitly; signedIn=' + signedIn, async () => {
  const job = Object.assign(jobs.InstallJob.create('renew:42',42,'main.hap','https://x/main.hap',''),
    { bundleName:'com.example.app',versionCode:7,renewalRequestedAt:123 });
  let saved = [], drains = 0;
  const ui = page(['renewFromStore'], { getContext:() => ({}),InstallStage:jobs.InstallStage,errorText:String,
    RenewalTarget:class {},StoreRenewal:{enqueue:async (_context,target,accountReady) => {
      assert.equal(target.versionCode,7);assert.equal(target.appId,42);assert.equal(accountReady,signedIn);
      if(!accountReady)job.stage=jobs.InstallStage.WAITING_ACCOUNT;return job;
    }},AccountService:{current:async () => signedIn?{}:undefined},
    JobStore:{open:async () => ({save:async row => saved.push(row.stage)})},
    InstallCoordinator:{recovered:async () => drains++,run:async () => assert.fail('new tasks must use FIFO')} });
  Object.assign(ui,{renewBundleName:job.bundleName,renewVersionCode:7,disposed:false,refreshTimeline(){}});
  await ui.renewFromStore(42);
  assert.equal(ui.selected,job);assert.equal(ui.busy,false);assert.equal(ui.preview,false);
  assert.equal(drains,signedIn?1:0);
  assert.deepEqual(saved,[]);assert.equal(job.stage,signedIn?jobs.InstallStage.QUEUED:jobs.InstallStage.WAITING_ACCOUNT);
});
test('confirmed manual fallback cancels a paused remote renewal before enqueuing a local replacement', async () => {
  const events = [],oldJob = {id:'remote:renew',stage:jobs.InstallStage.WAITING_NETWORK};
  const context={},store={get:async id => id===oldJob.id?oldJob:undefined,save:async ()=>{}};
  const ui=page(['install'],{getContext:()=>context,InstallStage:jobs.InstallStage,errorText:String,
    JobStore:{open:async()=>store},JobScheduler:{isRunning:()=>false,cancel:async(_context,_store,job)=>events.push('cancel:'+job.id)},
    LocalImport:{commitPreview:async()=>{events.push('enqueue');return jobs.InstallJob.create('local:new',0,'app.hap','local','');}},
    AccountService:{current:async()=>({})},InstallCoordinator:{recovered:async()=>{}}});
  Object.assign(ui,{busy:false,preview:true,selected:{id:'preview',bundleName:'com.example.app',versionCode:7},
    renewal:true,remoteJobId:oldJob.id,renewBundleName:'com.example.app',renewVersionCode:7,discard(){},refreshTimeline(){}});
  await ui.install();
  assert.deepEqual(events,['cancel:remote:renew','enqueue']);assert.equal(ui.remoteJobId,'');
});
test('the Install action queues the local HAP even when another job is active', async () => {
  const job = { id: 'local:hash', stage: 'package_inspected' };
  const f = installPage(job); f.ui.activeJobId = 'another-job';
  await f.ui.install();
  assert.deepEqual(f.saved, ['queued']); assert.equal(f.drains(), 1); assert.equal(f.ui.preview, false);
});
test('an old installed record is queued for live verification, not treated as a completed new installation', async () => {
  const f = installPage({ id: 'local:older', stage: 'installed' }); await f.ui.install();
  assert.deepEqual(f.saved, ['queued']);
});
test('manual renewal selection rejects another bundle or version before submitting', async () => {
  for (const mismatch of [{ bundleName: 'com.example.other', versionCode: 7 },
    { bundleName: 'com.example.app', versionCode: 8 }]) {
    const f = installPage({ id: 'local:wrong', ...mismatch });
    Object.assign(f.ui, { renewal: true, renewBundleName: 'com.example.app', renewVersionCode: 7 });
    await f.ui.install(true);
    assert.equal(f.saved.length, 0); assert.equal(f.drains(), 0); assert.equal(f.ui.preview, true);
    assert.match(f.ui.message, /相同/);
  }
});
test('a terminal local task asks for a new package while a paused renewal resumes its existing request', () => {
  const ui = page(['retry'], { InstallStage: jobs.InstallStage });
  let selected = 0, resumed = 0;
  Object.assign(ui, { selected: { id: 'local:renew' }, pick: () => selected++, resume: () => resumed++ });
  ui.task = () => ({ job: { stage: jobs.InstallStage.TERMINAL_ERROR } });
  ui.retry(); assert.equal(selected, 1); assert.equal(resumed, 0);
  ui.task = () => ({ job: { stage: jobs.InstallStage.WAITING_DEVICE } });
  ui.retry(); assert.equal(selected, 1); assert.equal(resumed, 1);
});
test('the local installation page shows missing account as a resumable waiting task', async () => {
  const f = installPage({ id: 'local:hash', bundleName: 'com.example.app' }, false);
  await f.ui.install();
  assert.equal(f.drains(), 0);
  assert.deepEqual(f.saved, ['queued', 'waiting_account']);
  assert.equal(f.ui.selected.stage, jobs.InstallStage.WAITING_ACCOUNT);
  assert.equal(f.ui.preview, false);
});

test('selecting an already running local package follows its progress without resetting or resubmitting it', async () => {
  const running = { id: 'local:hash', stage: 'installing' };
  const ui = page(['install'], { JobScheduler: { isRunning: id => id === running.id },
    LocalImport: { commitPreview: () => assert.fail('must not overwrite an active installation') } });
  Object.assign(ui, { busy: false, preview: true, selected: { id: running.id },
    task: () => ({ job: running, running: true }), discard() {}, refreshTimeline() {} });
  await ui.install();
  assert.equal(ui.selected, running); assert.equal(ui.preview, false);
  assert.equal(running.stage, 'installing');
});

for(const extension of ['hap','app'])test('edited '+extension+' preview owns its copy across editor cleanup',async t=>{
  const f=fixture(t),dir=f.context.cacheDir+'/package-editor';fs.mkdirSync(dir,{recursive:true});
  const source=dir+'/edited.'+extension;fs.writeFileSync(source,JSON.stringify(f.identity));
  const preview=await f.LocalImport.editedPreview(f.context,source,'edited.'+extension);
  assert.equal(f.enqueues(),0);assert.notEqual(preview.cachePath,source);
  fs.unlinkSync(source);assert.equal(fs.existsSync(preview.cachePath),true);
  const job=await f.LocalImport.commitPreview(f.context,f.store,preview);
  assert.equal(f.enqueues(),1);assert.equal(job.bundleName,f.identity.bundleName);
  assert.equal(fs.existsSync(preview.cachePath),false);assert.equal(fs.existsSync(job.cachePath),true);
});
test('edited preview rejects external paths and cleans invalid metadata copies',async t=>{
  const f=fixture(t);await assert.rejects(f.LocalImport.editedPreview(f.context,f.source,'source.hap'),/编辑文件无效/);
  const dir=f.context.cacheDir+'/package-editor';fs.mkdirSync(dir,{recursive:true});const source=dir+'/bad.app';fs.writeFileSync(source,'bad metadata');
  await assert.rejects(f.LocalImport.editedPreview(f.context,source,'bad.app'));
  assert.equal(fs.existsSync(source),true);assert.deepEqual(fs.readdirSync(f.context.cacheDir+'/local-hap-previews'),[]);
});

for(const reason of ['hidden','busy','returning','disposed'])test('FileOpen retains the pending grant while local preview is '+reason,()=>{
 let takes=0;
 const ui=page(['onExternalFileOpen'],{ExternalInstallOpen:{take(){takes++;return 'file://docs/new.hap';}}});
 Object.assign(ui,{pageActive:true,busy:false,returning:false,disposed:false,importExternal(){assert.fail('must retain pending selection');}});
 if(reason==='hidden')ui.pageActive=false;else ui[reason]=true;
 ui.onExternalFileOpen();assert.equal(takes,0);
});
test('FileOpen consumes the pending selection once when the local page is visible and idle',()=>{
 let takes=0,imports=[];
 const ui=page(['onExternalFileOpen'],{ExternalInstallOpen:{take(){takes++;return takes===1?'file://docs/new.hap':'';}}});
 Object.assign(ui,{pageActive:true,busy:false,returning:false,disposed:false,importExternal(uri){imports.push(uri);}});
 ui.onExternalFileOpen();ui.onExternalFileOpen();assert.deepEqual(imports,['file://docs/new.hap']);
});
