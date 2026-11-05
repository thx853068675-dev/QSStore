const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const {loadEts}=require('./load_ets.cjs');
const ReleaseUpdate=require('./release_update_fixture.cjs').releaseUpdate();
const {CatalogPackageVariant}=loadEts('data/CatalogPackageVariant');
const {InstallJob,InstallStage}=loadEts('jobs/InstallJob');
const {CatalogInstallTarget}=loadEts('jobs/CatalogInstallTarget',{
 '../data/CatalogPackageVariant':{CatalogPackageVariant},'./ReleaseUpdate':{ReleaseUpdate},'./InstallJob':{InstallJob,InstallStage}
});
const s=fs.readFileSync(__dirname+'/../entry/src/main/ets/pages/Index.ets','utf8');
const method=['updateForApp','catalogTarget','latestAssets','assetForBundle'].map(name=>{
 const a=s.indexOf('  private '+name+'(');assert.notEqual(a,-1,name);return s.slice(a,s.indexOf('\n  }',a)+4);
}).join('\n');
function fixture(version){
 const box={ReleaseUpdate,CatalogInstallTarget,UpdatePolicy:{disabled:()=>false},InstalledAppRegistry:{isAppGallery:()=>false,hasApplicationOrigin:()=>true,persist:async()=>{},versionName:()=>'',signingIdentity:()=>undefined},LocalBundles:{isKnown:v=>v>=0},UpdateTarget:class{}};
 vm.runInNewContext(ts.transpileModule('class Page{'+method+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const asset={bundleName:'one',versionCode:2,name:'app.hap',url:'https://source/app.hap',versionName:'2'},f={merges:0};
 f.ui=Object.assign(new box.Page(),{updatePolicyReady:true,installedJobs:[],catalogApp:()=>({latestAsset:asset}),
  displayInstalledVersion:()=>version,allInstalledJobs:()=>{f.merges++;return [{bundleName:'one',versionCode:1}];},installedVersionOf:()=>-1});return f;
}
test('known device versions skip complete inventory merging for every card getter, including absent/current/newer versions',()=>{
 for(const version of [0,1,2,3]){
  const f=fixture(version);for(let i=0;i<50;i++)assert.equal(f.ui.updateForApp(1)?.versionCode,version===1?2:undefined);
  assert.equal(f.merges,0);
 }
});
test('unknown device state still falls back to the freshly recorded installed version',()=>{
 const f=fixture(-1);assert.equal(f.ui.updateForApp(1).versionCode,2);assert.equal(f.merges,1);
 f.ui.allInstalledJobs=()=>[{bundleName:'one',versionCode:2}];assert.equal(f.ui.updateForApp(1),undefined);
});
