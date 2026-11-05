const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function component(name,methods,globals){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/'+name+'.ets'),'utf8');
 const members=methods.map(name=>{
  const at=source.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert(at>=0,name);
  const parsed=ts.createSourceFile('subject.ts','class Subject {\n'+source.slice(at),ts.ScriptTarget.ES2020,true);
  return parsed.statements[0].members[0].getText(parsed);
 }).join('\n');
 const box={...globals};vm.runInNewContext(ts.transpileModule('class Subject{'+members+'};globalThis.Subject=Subject;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);return new box.Subject();
}
test('inactive unified content does not scan; opening it observes shared discovery without enabling the mode',()=>{
 const calls=[],targets={selection:[{key:'local'}],load:()=>{calls.push('load');return Promise.resolve();},
  subscribe:()=>1,unsubscribe:()=>{},enable:()=>assert.fail('viewing cannot enable')};
 const row=component('DeviceDiscoveryContent',['aboutToAppear','onActiveChanged','clearFlush'],{
  DeviceDiscoveryPreferences:{load:async()=>false},DeviceLanPorts:{load:async()=>{}},
  clearTimeout:()=>{},MultiDeviceTargets:targets,DeviceDiscovery:{shared:()=>({subscribe:()=>1,unsubscribe:()=>{},ensureStarted:()=>{calls.push('scan');return Promise.resolve();}})},getContext:()=>({}),errorText:String
 });
 Object.assign(row,{scrollOwners:new Set(),active:false,devices:[],subscription:-1,targetSubscription:-1,generation:0,syncSelection:()=>{},requestDiscovery:()=>{},drawLines:()=>{},reportHeight:()=>{}});
 row.aboutToAppear();assert.deepEqual(calls,[]);row.active=true;row.onActiveChanged();assert.deepEqual(calls,['load','scan']);
});
test('enable only shows the capsule after persistence; repeated taps cannot trigger a second transition',async()=>{
 const calls=[];let release;
 const targets={modeEnabled:false,load:async()=>{calls.push('load');},enable:async()=>{
  calls.push('enable');await new Promise(resolve=>release=resolve);targets.modeEnabled=true;
 }};
 const row=component('MultiDeviceCard',['toggle'],{MultiDeviceTargets:targets,getContext:()=>({}),
  promptAction:{showToast:()=>assert.fail('unexpected error')},errorText:String});
 row.saving=false;row.open=()=>assert.fail('enabling must not open a panel');
 const pending=row.toggle();await new Promise(resolve=>setImmediate(resolve));
 await row.toggle();assert.deepEqual(calls,['load','enable']);assert.equal(row.saving,true);
 release();await pending;assert.deepEqual(calls,['load','enable']);assert.equal(row.saving,false);
});
test('stop uses the durable disable operation and never opens discovery or changes existing jobs',async()=>{
 const calls=[];
 const row=component('MultiDeviceCard',['toggle'],{MultiDeviceTargets:{modeEnabled:true,
  load:async()=>{},disable:async()=>calls.push('disable')},getContext:()=>({}),
  promptAction:{showToast:()=>assert.fail('unexpected error')},errorText:String});
 row.saving=false;row.open=()=>assert.fail('stopping must not open discovery');
 await row.toggle();assert.deepEqual(calls,['disable']);assert.equal(row.saving,false);
});
test('a persistence failure shows its reason without opening selection and releases the action',async()=>{
 const messages=[];
 const row=component('MultiDeviceCard',['toggle'],{MultiDeviceTargets:{modeEnabled:false,
  load:async()=>{},enable:async()=>{throw Error('disk full');}},getContext:()=>({}),
  promptAction:{showToast:value=>messages.push(value.message)},errorText:String});
 row.saving=false;row.open=()=>assert.fail('not enabled');await row.toggle();
 assert.match(messages[0],/disk full/);assert.equal(row.saving,false);
});
