const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function methods(file,names,globals){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components',file+'.ets'),'utf8');
 const code=names.map(name=>{
  const at=source.search(new RegExp('^  (?:private )?'+name+'\\(','m'));assert(at>=0,name);
  const parsed=ts.createSourceFile('subject.ts','class Subject{\n'+source.slice(at),ts.ScriptTarget.ES2020,true);
  return parsed.statements[0].members[0].getText(parsed);
 }).join('\n');
 const box={...globals};vm.runInNewContext(ts.transpileModule('class Subject{'+code+'};globalThis.Subject=Subject;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);return new box.Subject();
}
function fixture(){
 const timers=new Map(),ready=new Map(),requests=[],changes=[];let next=0;
 const key=(kind,model,name)=>JSON.stringify([kind,model,name]);
 const local={source:'file:///cache/pura-x.png',frame:{contentWidth:.55,contentHeight:.94}};
 const remote={source:'file:///cache/pura-70.png',frame:{contentWidth:.61,contentHeight:.94}};
 const artwork={cached:(_ctx,...args)=>ready.get(key(...args)),portrait:(_ctx,...args)=>new Promise(resolve=>requests.push({args,resolve}))};
 const make=()=>Object.assign(methods('DevicePortrait',['aboutToAppear','aboutToDisappear','reload'],{
  DeviceArtwork:artwork,getContext:()=>({cacheDir:'/cache'}),setTimeout:(fn,delay)=>{assert.equal(delay,450);timers.set(++next,fn);return next;},clearTimeout:id=>timers.delete(id)}),{
  alive:false,generation:0,timer:-1,source:'',kind:'phone',model:'VDE-AL10',marketName:'Pura X',
  fallbackFrame:{contentWidth:.82,contentHeight:.94},onFrameChanged:frame=>changes.push(frame)});
 return{make,timers,requests,changes,local,remote,cache:(model,name,portrait)=>ready.set(key('phone',model,name),portrait),
  tick(){const fns=[...timers.values()];timers.clear();fns.forEach(fn=>fn());}};
}
test('repeated enable/disable mounts start with the correct cached model, without a placeholder frame or 450ms timer',()=>{
 const f=fixture();f.cache('VDE-AL10','Pura X',f.local);
 for(let i=0;i<20;i++){
  const row=f.make(),writes=[];Object.defineProperty(row,'source',{get:()=>writes.at(-1),set:value=>writes.push(value)});
  row.aboutToAppear();assert.equal(row.source,f.local.source);assert.equal(row.frame,f.local.frame);
  assert.deepEqual(writes,[f.local.source],'do not blank the correct model on mount');
  assert.equal(f.timers.size,0);assert.equal(f.requests.length,0);assert.equal(f.changes.at(-1),f.local.frame);
  row.aboutToDisappear();assert.equal(f.timers.size,0);
 }
});
test('cold artwork, changed identities and disposed views cannot leak a previous model into the current capsule',async()=>{
 const f=fixture(),row=f.make();row.aboutToAppear();assert.equal(row.source,'');assert.equal(f.timers.size,1);f.tick();
 row.model='HBN-AL00';row.marketName='Pura 70 Pro';row.reload();f.tick();assert.equal(f.requests.length,2);
 f.requests[0].resolve(f.local);await Promise.resolve();assert.equal(row.source,'','a late local image must not replace the new remote identity');
 f.requests[1].resolve(f.remote);await Promise.resolve();assert.equal(row.source,f.remote.source);
 row.model='VDE-AL10';row.marketName='Pura X';row.reload();f.tick();row.aboutToDisappear();
 f.requests[2].resolve(f.local);await Promise.resolve();assert.equal(row.source,'','an unmounted capsule cannot publish late artwork');
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DevicePortrait.ets'),'utf8');
 assert(!source.includes('fallbackPicture'),'a cold capsule uses a type glyph, never another model photo');
});
test('stack geometry is restored from the exact cached silhouette before its children mount',()=>{
 const f=fixture();f.cache('VDE-AL10','Pura X',f.local);f.cache('HBN-AL00','Pura 70 Pro',f.remote);
 const rows=[{key:'remote',kind:'phone',model:'HBN-AL00',marketName:'Pura 70 Pro'},{key:'local',kind:'phone',model:'VDE-AL10',marketName:'Pura X'}];
 const row=methods('DeviceStackPortrait',['syncDevices'],{DeviceArtwork:{cached:(_ctx,_kind,model)=>model==='VDE-AL10'?f.local:f.remote},
  MultiDeviceTargets:{selection:rows},DeviceStackLayout:{targets:x=>x},getContext:()=>({})});
 Object.assign(row,{alive:true,multiEnabled:true,selectionKey:'',frame:()=>assert.fail('warm geometry must not reset to generic phone bounds')});
 row.syncDevices();assert.equal(row.frames[0],f.remote.frame);assert.equal(row.frames[1],f.local.frame);
 const frames=row.frames;row.syncDevices();assert.equal(row.frames,frames,'unchanged selection does not rebuild the stack');
});
