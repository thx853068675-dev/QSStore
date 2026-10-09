const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const s=fs.readFileSync(__dirname+'/../entry/src/main/ets/pages/Index.ets','utf8'),a=s.indexOf('  private updateForApp(');
const method=s.slice(a,s.indexOf('\n  }',a)+4);
function fixture(version){
 const box={ReleaseUpdate:require('./release_update_fixture.cjs').releaseUpdate(),InstalledAppRegistry:{versionName:()=>'',signingIdentity:()=>undefined},LocalBundles:{isKnown:v=>v>=0},UpdateTarget:class{}};
 vm.runInNewContext(ts.transpileModule('class Page{'+method+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const asset={bundleName:'one',versionCode:2,name:'app.hap',url:'https://source/app.hap',versionName:'2'},f={merges:0};
 f.ui=Object.assign(new box.Page(),{installedJobs:[],catalogApp:()=>({latestAsset:asset}),assetForBundle:()=>asset,
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
