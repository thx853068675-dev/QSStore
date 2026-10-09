const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {CatalogPackageVariant:Variant}=loadEts('data/CatalogPackageVariant');
const {CatalogLookup}=loadEts('data/CatalogLookup');
const direct={name:'HarmonyX-v2.4.2-unsigned.hap',url:'https://github.com/haohaoai0/HarmonyX/releases/download/v2.4.2/HarmonyX-v2.4.2-unsigned.hap',bundleName:'com.haohaoai0.harmonx',versionCode:16};
const archive={...direct,name:'HarmonyX-v2.4.2-unsigned.app.zip / entry-default.hap',url:direct.url+'.zip#qingqi-package=entry-default.hap'};
test('Harmony X old filename tracks the same HAP or archive variant through a release rename',()=>{
 assert.equal(Variant.choose([direct,archive],'HarmonyX-v2.4.0-unsigned.hap',direct),direct);
 assert.equal(Variant.choose([direct,archive],'HarmonyX-v2.4.0-unsigned.app.zip / entry-default.hap',direct),archive);
 assert.equal(Variant.choose([direct,archive],'Harmony X',direct),direct);
 assert.equal(Variant.choose([direct,archive],'com.haohaoai0.harmonx.hap',direct),direct);
});
test('variant matching retains platform and packaging distinctions and refuses ambiguous renamed files',()=>{
 const a={...direct,name:'Example-v1.2.3-arm64.hap'},b={...direct,name:'Example-v1.2.3-tablet.hap'};
 assert.equal(Variant.choose([a,b],'Example-v1.2.2-arm64.hap',a),a);
 assert.equal(Variant.choose([a,b],'Example-v1.2.2-x64.hap',a),undefined);
 assert.equal(Variant.choose([a,{...a,url:'another'}],'Example-v1.2.2-arm64.hap',a),undefined);
});
test('Discovery lookup, Management source and complete rows share the freshest known catalog snapshot',()=>{
 const old={id:23,updatedAt:'100',latestAsset:{...direct,versionCode:14},latestAssets:[{...direct,versionCode:14}]};
 const fresh={id:23,updatedAt:'200',latestAsset:direct,latestAssets:[direct,archive]};
 const lookup=new CatalogLookup([old],[fresh],true,0,a=>a);
 assert.equal(lookup.app(23),fresh);assert.equal(lookup.rows[0],fresh);
 assert.equal(lookup.source(23,direct.bundleName),fresh);assert.equal(lookup.source(0,direct.bundleName),fresh);
 const sameCode={...fresh,updatedAt:'300',latestAsset:{...direct,releaseTag:'v2.4.3'}};
 const equal=new CatalogLookup([fresh],[sameCode],true,0,a=>a);
 assert.equal(equal.rows[0],sameCode);assert.equal(equal.source(23,direct.bundleName),sameCode);
});
test('a stale discovery row cannot resurrect a removed app after a complete management refresh',()=>{
 const lookup=new CatalogLookup([], [{id:23,latestAsset:direct}],true,0,a=>a);
 assert.equal(lookup.app(23),undefined);assert.equal(lookup.rows.length,0);
 assert.equal(lookup.source(0,direct.bundleName),undefined);
});
