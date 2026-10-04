const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks={}) {
  const exports={};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,file+'.ets'),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText,{exports,require:key=>mocks[key]||{}});return exports;
}
const release=load('data/ReleaseInfo');
const catalog=load('data/CatalogApp',{'./ReleaseInfo':release});
function page(file,names,globals={}) {
  const source=fs.readFileSync(path.join(root,'pages',file+'.ets'),'utf8');
  const methods=names.map(name=>{
    const start=source.search(new RegExp('^  private (?:async )?'+name+'\\(', 'm'));
    assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n  }',start)+4);
  });
  const box={...globals};vm.runInNewContext(ts.transpileModule('class Page { '+methods.join('\n')+' };globalThis.Page=Page;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);return new box.Page();
}
const row=(repo,kind)=>release.ReleaseInfo.fromJson({tag:'v2',name:'2.0',source_repo:repo,source_kind:kind,
  published_at:'2026-10-03',assets:[{name:'app.hap',url:'https://github.com/'+repo+'/app.hap'}]});
test('source metadata survives catalog copying and release identities distinguish identical tags',()=>{
  const app=catalog.CatalogApp.fromJson({id:1,repo:'dev/main',secondary_repo:'mirror/releases',stars:120,github_downloads:30});
  assert.equal(catalog.CatalogApp.copy(app).secondaryRepo,'mirror/releases');
  assert.equal(app.stars,120,'server already supplied the sum; client must not add twice');
  assert.notEqual(row('dev/main','primary').identity(),row('mirror/releases','secondary').identity());
  const old=release.ReleaseInfo.fromJson({tag:'v1'});assert.equal(old.sourceLabel(),'主仓');
});
test('release history labels place the repository marker immediately after the version',()=>{
  const ui=page('Detail',['currentRelease','currentReleaseLabel','releaseOptions']);
  ui.app={secondaryRepo:'mirror/releases'};
  ui.releases=[row('mirror/releases','secondary'),row('dev/main','primary')];
  ui.selectedReleaseIndex=0;ui.releaseTotal=2;
  assert.equal(ui.currentReleaseLabel(),'2.0 · 子仓  ·  2026-10-03');
  assert.equal(ui.releaseOptions()[1].value,'2.0 · 主仓  ·  2026-10-03');
});
test('a single repository has no source marker in the selected label or history options',()=>{
  const ui=page('Detail',['currentRelease','currentReleaseLabel','releaseOptions']);
  ui.app={secondaryRepo:''};ui.releases=[row('dev/main','primary')];
  ui.selectedReleaseIndex=0;ui.releaseTotal=1;
  assert.equal(ui.currentReleaseLabel(),'2.0  ·  2026-10-03');
  assert.equal(ui.releaseOptions()[0].value,'2.0  ·  2026-10-03');
});
test('paged releases keep a primary and a mirror version with the same tag while dropping exact duplicates',async()=>{
  const primary=row('dev/main','primary'),secondary=row('mirror/releases','secondary');
  const ui=page('Detail',['loadMoreReleases'],{getContext:()=>({}),Detail:{RELEASES_PER_PAGE:20},errorText:e=>String(e),StoreClient:class {
    async listReleases(){return {items:[primary,secondary],total:2,page:2};}
  }});
  Object.assign(ui,{app:{id:1},releases:[secondary],releasePage:1,releaseHasMore:()=>true,showPreviewReleases:false});
  await ui.loadMoreReleases();assert.equal(ui.releases.length,2);
  assert.equal(ui.releases[1].sourceRepo,'dev/main');
});
test('editing a source address requires a new verified draft before saving or silently unlinking',async()=>{
  let writes=0;
  const ui=page('Index',['configSourceChanged','saveAppConfig'],{StoreClient:class {
    async configureMyApp(){writes++;throw Error('unexpected');}
  },getContext:()=>({})});
  Object.assign(ui,{configBusy:false,configApp:{id:1,secondaryRepo:'mirror/releases'},
    configSourceUrl:'https://github.com/new/source',configCategories:['工具'],configCategory:'工具',
    configSourceDraft:{token:''},configSourceRemove:false});
  await ui.saveAppConfig();assert.equal(writes,0);
  ui.configSourceUrl='';await ui.saveAppConfig();assert.equal(writes,0);
  ui.configSourceUrl='https://github.com/MIRROR/RELEASES/';assert.equal(ui.configSourceChanged(),false);
});
test('closing an in-flight source check cannot update the next configuration sheet',async()=>{
  let resolve;
  const pending=new Promise(done=>resolve=done);
  const ui=page('Index',['checkAppSource'],{SubmitDraft:class {},getContext:()=>({}),
    StoreClient:class {async prepareAppSource(){return pending;}},errorText:e=>String(e)});
  Object.assign(ui,{configBusy:false,configSourceGeneration:0,showAppConfig:true,configSourceUrl:'https://github.com/mirror/releases',
    configApp:{id:1,latestAssets:[{bundleName:'com.example.app'}]}});
  const work=ui.checkAppSource();ui.configSourceGeneration++;ui.showAppConfig=false;
  ui.configSourceMessage='next sheet';ui.configBusy=false;
  resolve({inspectionStatus:'ready',choices:[{bundleName:'com.example.app'}],token:'draft'});await work;
  assert.equal(ui.configSourceMessage,'next sheet');assert.equal(ui.configBusy,false);
});
