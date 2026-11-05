const {test}=require('node:test');
const assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
class App{constructor(){this.bundleName='';this.displayName='';this.versionCode=0;this.versionName='';this.moduleName='';this.abilityName='';}}
const side=Object.assign(new App(),{bundleName:'com.example.side',displayName:'侧载',versionCode:12});
let disk='',raw='';
const registry={load:async()=>{},sideloadedApps:()=>[side]};
const mocks={'../jobs/InstalledAppRegistry':{InstalledAppRegistry:registry,InstalledDeviceApp:App},
 '../jobs/HdcDeviceBridge':{HdcDeviceBridge:class{async installedApplicationLabels(){return raw;}}},
 '@kit.ArkData':{preferences:{getPreferences:async()=>({get:async()=>disk,put:async(k,v)=>{disk=v;},flush:async()=>{}})}}};
const {InstalledApplications:catalog}=loadEts('data/InstalledApplications',mocks);
test('complete local label list includes system apps, keeps sideload metadata, and survives restart',async()=>{
 raw=JSON.stringify([{bundleName:'com.huawei.system',label:'系统'},{bundleName:'com.example.side',label:'侧载新版'}]);
 const rows=await catalog.refresh({});assert.equal(rows.length,2);assert.equal(rows.find(x=>x.bundleName==='com.example.side').versionCode,12);
 assert.equal(rows.find(x=>x.bundleName==='com.huawei.system').displayName,'系统');assert.equal((await catalog.cached({})).length,2);
});
test('incomplete responses never replace last complete cache',async()=>{
 const before=disk;raw='[Fail] disconnected';await assert.rejects(catalog.refresh({}));assert.equal(disk,before);
 raw='[]';await assert.rejects(catalog.refresh({}));assert.equal(disk,before);
});
test('untrusted duplicate and malformed package records are filtered',()=>{
 const rows=catalog.parse(JSON.stringify([{bundleName:'com.a.app',label:'A'},{bundleName:'com.a.app',label:'duplicate'},
  {bundleName:'../../bad',label:'bad'},{bundleName:'com.valid.ok',label:''}]));
 assert.deepEqual(Array.from(rows,x=>x.bundleName),['com.a.app','com.valid.ok']);
});
const {marketApplicationIcon}=loadEts('data/ApplicationIcons');
test('market icons require the exact HarmonyOS package and a trusted CDN',()=>{
 const record=(pkg,ctype,icon)=>JSON.stringify({pkgName:pkg,ctype,icon});
 assert.equal(marketApplicationIcon('com.a.app',record('com.a.app',17,'https://cdn.dbankcdn.com/a.png')),'https://cdn.dbankcdn.com/a.png');
 assert.equal(marketApplicationIcon('com.a.app',record('com.b.app',17,'https://cdn.dbankcdn.com/a.png')),'');
 assert.equal(marketApplicationIcon('com.a.app',record('com.a.app',1,'https://cdn.dbankcdn.com/a.png')),'');
 assert.equal(marketApplicationIcon('com.a.app',record('com.a.app',17,'https://evil.example/a.png')),'');
});
