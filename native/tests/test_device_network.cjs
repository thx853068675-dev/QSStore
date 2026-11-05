const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {DeviceInstallTarget:Target}=loadEts('jobs/DeviceInstallTarget');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function fixture(){
 let nets=[],capGate,lookups=0;const handlers=new Map();
 const connection={NetBearType:{BEARER_WIFI:1,BEARER_ETHERNET:3},
  createNetConnection:()=>({on:(name,fn)=>handlers.set(name,fn),register:fn=>fn()}),
  getAllNets:async()=>{lookups++;return nets.map(x=>({netId:x.id}));},
  getNetCapabilities:async h=>{const row=nets.find(x=>x.id===h.netId);if(capGate)await capGate;return{bearerTypes:row.types}},
  getConnectionProperties:async h=>{const row=nets.find(x=>x.id===h.netId);return{interfaceName:row.interface,linkAddresses:[{address:{address:row.ip}}]}}};
 const {DeviceNetwork:N}=loadEts('jobs/DeviceNetwork',{'@kit.NetworkKit':{connection},'./DeviceInstallTarget':{DeviceInstallTarget:Target}},{setTimeout,clearTimeout});
 return{N,handlers,get lookups(){return lookups;},set nets(v){nets=v},set gate(v){capGate=v}};
}
const wifi={id:100,types:[1],interface:'wlan0',ip:'192.168.3.8'};
test('physical Wi-Fi works without WAN validation, cellular/VPN alone cannot enable remote targets, PCs retain wired LAN',async()=>{
 const f=fixture();Target.localKind='phone';
 try{
  f.nets=[{id:102,types:[0],interface:'rmnet0',ip:'10.1.2.3'},{id:103,types:[4],interface:'tun0',ip:'10.2.3.4'}];
  assert.equal(await f.N.start(),false);
  f.nets=[wifi,{id:103,types:[4],interface:'tun0',ip:'10.2.3.4'}];assert.equal(await f.N.refresh(),true);
  f.nets=[{id:104,types:[3],interface:'eth0',ip:'10.0.2.15'}];assert.equal(await f.N.refresh(),false);
  Target.localKind='pc';assert.equal(await f.N.refresh(),true);
 }finally{Target.localKind='phone';}
});
test('losing the physical network immediately gates targets and a late old query cannot restore them',async()=>{
 const f=fixture();f.nets=[wifi];assert.equal(await f.N.start(),true);
 let release;f.gate=new Promise(resolve=>release=resolve);const old=f.N.refresh();await tick();
 f.nets=[];f.handlers.get('netLost')({netId:100});assert.equal(f.N.available,false);f.gate=undefined;await tick();release();await old;
 assert.equal(f.N.available,false);f.nets=[wifi];assert.equal(await f.N.refresh(),true);
});
test('network loss clears selected remote targets durably and immediately prevents new remote install snapshots',async()=>{
 const values=new Map(),events=[];let notify;const network={available:true,ready:true,start:async()=>true,subscribe:fn=>(notify=fn,1)};
 const remote=Object.assign(new Target(),{key:'a'.repeat(64),udid:'a'.repeat(64),host:'192.168.3.8',port:54321,name:'手机',kind:'phone'});
 values.set('remembered',JSON.stringify([Target.snapshot(remote)]));values.set('selected',remote.key);values.set('selection',JSON.stringify([remote.key]));values.set('enabled',true);
 const {MultiDeviceTargets:M}=loadEts('jobs/MultiDeviceTargets',{
  './DeviceInstallTarget':{DeviceInstallTarget:Target},'./DeviceNetwork':{DeviceNetwork:network},
  '@kit.ArkData':{preferences:{getPreferences:async()=>({get:async(k,d)=>values.get(k)??d,put:async(k,v)=>values.set(k,v),flush:async()=>{}})}},
  './InstallTaskState':{InstallTaskState:{setTargetProvider(){},targetChanged(){events.push('selection')}}},'./JobStore':{JobStore:{setTargetProvider(){}}},
 },{AppStorage:{setOrCreate(){}}});
 await M.load({});assert.equal(M.selection[0].key,remote.key);network.available=false;notify();
 assert.deepEqual(Array.from(M.snapshots()),['']);await tick();await tick();assert.equal(M.selection[0].key,'local');
 assert.deepEqual(JSON.parse(values.get('selection')),['local']);assert.equal(M.remembered.length,1);
 await assert.rejects(M.toggle(remote),/Wi-Fi/);await assert.rejects(M.selectMany([remote]),/Wi-Fi/);
});

test('same Wi-Fi and VPN metadata notifications coalesce without publishing a false network change',async()=>{
 const f=fixture();f.nets=[wifi];let changes=0;f.N.subscribe(()=>changes++);await f.N.start();assert.equal(changes,1);
 for(let i=0;i<30;i++)f.handlers.get('netAvailable')({netId:100});
 await new Promise(resolve=>setTimeout(resolve,180));assert.equal(f.lookups,2);assert.equal(changes,1);
 f.nets=[wifi,{id:200,types:[4],interface:'tun0',ip:'10.2.3.4'}];await f.N.refresh();assert.equal(changes,1);
 f.nets=[{...wifi,id:101}];await f.N.refresh();assert.equal(changes,2);
});
