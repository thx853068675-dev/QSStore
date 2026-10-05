const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: key => mocks[key] || {} });
  return exports;
}
const jobs = load('jobs/InstallJob'), assets = load('data/ReleaseInfo');
function fixture(rows = [], pages = {}) {
  const calls = [], saves = [];
  const store = { listAll: async () => rows, async enqueueRenewal(...args) { saves.push(args); return { id: 'renew' }; } };
  const client = { async listReleases(id, page, size, preview) {
    calls.push({ id, page, size, preview });
    return pages[preview + ':' + page] || { items: [], hasMore: false };
  } };
  const { StoreRenewal, RenewalTarget } = load('jobs/StoreRenewal', {
    './InstallJob': jobs, '../data/ReleaseInfo': assets,
    './RecoveryPlanner': load('jobs/RecoveryPlanner', { './InstallJob': jobs }),
    './JobStore': { JobStore: { open: async () => store } },
    '../data/StoreClient': { StoreClient: class { listReleases(...args) { return client.listReleases(...args); } } }
  });
  const target = Object.assign(new RenewalTarget(), { appId: 1, bundleName: 'com.example.app', versionCode: 7 });
  return { StoreRenewal, target, calls, saves, client };
}
const asset = (url, code = 7, bundle = 'com.example.app') => Object.assign(new assets.HapAsset(),
  { name: url.split('/').pop(), url, bundleName: bundle, versionCode: code, versionName: '1.0', mirrorUrls: [] });
const page = (items, hasMore = false) => ({ items: [{ tag: 'unrelated-tag', assets: items }], hasMore });
const old = () => Object.assign(jobs.InstallJob.create('old', 1, 'hicar.hap', 'https://github.com/o/r/hicar.hap', ''),
  { bundleName: 'com.example.app', versionCode: 7, stage: jobs.InstallStage.INSTALLED, versionName: '1.0' });

test('confirmed source keeps the installed variant without catalog collection or metadata calls', async () => {
  const previous = old(); previous.mirrorUrls = ['https://mirror.example/hicar.hap'];
  const f = fixture([previous]);
  const result = await f.StoreRenewal.source(f.target, [previous], f.client);
  assert.equal(result.url, previous.sourceUrl); assert.equal(result.name, 'hicar.hap');
  assert.equal(result.versionCode, 7); assert.equal(f.calls.length, 0);
});
test('a retained ZIP/APP selection keeps its exact archive entry and mirrors', async () => {
  const previous = old(); previous.assetName = 'apps.zip / sub/main.app';
  previous.sourceUrl = 'https://x/apps.zip#qingqi-package=sub%2Fmain.app';
  const f = fixture([previous]);
  const result = await f.StoreRenewal.source(f.target,[previous],f.client);
  assert.equal(result.url,previous.sourceUrl);assert.equal(result.name,previous.assetName);
  assert.equal(f.calls.length,0);
});
test('both channels are searched by inspected bundle/internal code, independently of tags and newer versions', async () => {
  const desired = asset('https://github.com/o/r/releases/v7/main.app');
  const f = fixture([], { 'false:1': page([asset('https://x/new.hap', 8), asset('https://x/unknown.hap', 0)]),
    'true:1': page([desired, asset('https://x/other.hap', 7, 'com.example.other')]) });
  assert.equal((await f.StoreRenewal.source(f.target, [], f.client)).url, desired.url);
  assert.deepEqual(f.calls.map(r => r.preview), [false, true]);
});
test('same-version ambiguous variants require manual selection', async () => {
  const f = fixture([], { 'false:1': page([asset('https://x/phone.hap'), asset('https://x/hicar.hap')]) });
  await assert.rejects(f.StoreRenewal.source(f.target, [], f.client), /多个安装包/);
});
test('missing and uninspected versions never silently fall back to latest', async () => {
  const f = fixture([], { 'false:1': page([asset('https://x/new.hap', 8), asset('https://x/unknown.hap', 0)]) });
  await assert.rejects(f.StoreRenewal.source(f.target, [], f.client), /没有已安装版本/);
});
test('a foreign repository or a different installed code cannot supply the original package', async () => {
  const wrongRepo = old(); wrongRepo.appId = 2;
  const wrongVersion = old(); wrongVersion.versionCode = 8;
  const f = fixture([wrongRepo, wrongVersion]);
  await assert.rejects(f.StoreRenewal.source(f.target, [wrongRepo, wrongVersion], f.client), /没有已安装版本/);
  assert.equal(f.calls.length, 2);
});
test('paginated preview history is searched; duplicated URL is not a second variant', async () => {
  const wanted = asset('https://x/v7.hap');
  const f = fixture([], { 'false:1': page([wanted]), 'true:1': page([], true), 'true:2': page([wanted]) });
  assert.equal((await f.StoreRenewal.source(f.target, [], f.client)).url, wanted.url);
  assert.deepEqual(f.calls.map(r => r.page), [1, 1, 2]);
});
test('incomplete large histories are bounded and never treated as proof of a unique variant', async () => {
  const pages = {}; for (let i = 1; i <= 5; i++) pages['false:' + i] = page([asset('https://x/v7.hap')], true);
  const f = fixture([], pages);
  await assert.rejects(f.StoreRenewal.source(f.target, [], f.client), /历史版本过多/);
  assert.equal(f.calls.length, 6);
});
test('concurrent entry points share source discovery and one enqueue', async () => {
  const f = fixture([], { 'false:1': page([asset('https://x/v7.hap')]) });
  const [a, b] = await Promise.all([f.StoreRenewal.enqueue({}, f.target), f.StoreRenewal.enqueue({}, f.target)]);
  assert.equal(a, b); assert.equal(f.saves.length, 1); assert.equal(f.calls.length, 2);
});
test('already queued renewal is resumed without metadata requests or changing its request identifier', async () => {
  const job = old(); job.stage = jobs.InstallStage.WAITING_DEVICE; job.renewalRequestedAt = 123;
  const f = fixture([job]);
  assert.equal(await f.StoreRenewal.enqueue({}, f.target), job);
  assert.equal(f.calls.length, 0); assert.equal(f.saves.length, 0); assert.equal(job.renewalRequestedAt, 123);
});
test('an ordinary update in flight cannot be replaced by renewal', async () => {
  const job = old(); job.stage = jobs.InstallStage.DOWNLOADING;
  const f = fixture([job]);
  await assert.rejects(f.StoreRenewal.enqueue({}, f.target), /已有安装任务/);
  assert.equal(f.saves.length, 0); assert.equal(f.calls.length, 0);
});
test('Management and application information retain a confirmed online renewal source when catalog identity is incomplete', () => {
  const source=fs.readFileSync(path.join(root,'pages/Index.ets'),'utf8');
  const methods=['renewalAppId','renewInstalled','openRenewal','pendingRenewal','renewalButtonLabel','openJobDetails'].map(name=>{
    const start=source.search(new RegExp('^  private '+name+'\\(', 'm'));
    assert.notEqual(start,-1);return source.slice(start,source.indexOf('\n  }',start)+4);
  });
  let dialog;
  const routes=[],box={AlertDialog:{show:options=>dialog=options},InstallStage:jobs.InstallStage,InstalledInspection:{selection:(job,title,appId)=>({bundleName:job.bundleName,title,appId})},
    StorePageMotion:{pushUrl:args=>routes.push(args)}};
  vm.runInNewContext(ts.transpileModule('class Page { '+methods.join('\n')+' };globalThis.Page=Page;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const ui=new box.Page();Object.assign(ui,{catalogForJob:()=>undefined,currentInstalledView:job=>job,jobTitle:()=> 'title',jobIcon:()=>undefined,pendingJobs:[],renewalPreparing:[]});
  ui.allInstalledJobs=()=>[job];
  const job=old();ui.renewInstalled(job);ui.openJobDetails(job);
  assert.equal(routes.length,1,'opening the renewal choice does not enqueue or navigate');
  assert.equal(JSON.parse(routes[0].params.selection).appId,1);
  assert.deepEqual(Array.from(dialog.buttons,b=>b.value),['商店自动续签','自选 HAP 包续签','取消']);
  dialog.buttons[0].action();assert.equal(ui.renewalSourceAppId,1);assert.equal(ui.showRenewal,true);
  dialog.buttons[1].action();assert.equal(ui.renewalSourceAppId,0);
  dialog.buttons[2].action();assert.equal(routes.length,1);
  ui.allInstalledJobs=()=>[{...job,versionCode:8}];dialog.buttons[0].action();
  assert.equal(ui.renewalTarget.versionCode,8,'choice uses the current installed version');
  ui.allInstalledJobs=()=>[];dialog.buttons[0].action();assert.equal(routes.length,1);
  ui.allInstalledJobs=()=>[job];
  ui.pendingJobs=[{...job,id:'running-renewal',renewalRequestedAt:1,stage:'waiting_device'}];
  dialog=undefined;ui.renewInstalled(job);
  assert.equal(dialog,undefined,'a running renewal reopens progress without asking its source again');
  assert.equal(ui.renewalExistingJobId,'running-renewal');assert.equal(ui.renewalButtonLabel(job),'续签中');
  assert.equal(ui.renewalAppId({...job,sourceUrl:'device'}),0,'a synthetic device observation is not proof of its old repository');
  ui.catalogForJob=()=>({id:2});assert.equal(ui.renewalAppId({...job,appId:0,sourceUrl:'local'}),2);
});

test('an installed card remains available for reopening a renewal while ordinary installs stay in the queue', () => {
  const source=fs.readFileSync(path.join(root,'pages/Index.ets'),'utf8');
  const start=source.indexOf('  private managementInstalledJobs(');
  const method=source.slice(start,source.indexOf('\n  }',start)+4);
  const box={};
  vm.runInNewContext(ts.transpileModule('class Page { '+method+' };globalThis.Page=Page;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page=new box.Page(),installed=old();
  Object.assign(page,{installedLocalOnly:false,allInstalledJobs:()=>[installed],
    renewalDeadline:()=>1800000000,
    updateApps:()=>[{id:1}],installedAssets:()=>[{bundleName:installed.bundleName}],updateFor:()=>undefined,
    pendingJobs:[{...installed,stage:jobs.InstallStage.WAITING_CONFIRMATION,renewalRequestedAt:123}]});
  assert.equal(page.managementInstalledJobs().length,1);
  assert.equal(page.managementInstalledJobs()[0],installed);
  page.updateApps=()=>[];
  assert.equal(page.managementInstalledJobs(true).length,1,'offline renewal keeps its installed card too');
  page.pendingJobs[0].renewalRequestedAt=0;
  assert.equal(page.managementInstalledJobs(true).length,0,'ordinary install retains the existing queue grouping');
  page.pendingJobs=[{appId:installed.appId,bundleName:'',catalogBundleName:''}];
  assert.equal(page.managementInstalledJobs(true).length,0,'an uninspected ordinary task is also excluded');
});
