const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {DeviceInstallTarget}=loadEts('jobs/DeviceInstallTarget');
const lan='101|wlan0|192.168.3.163/24',renewed='202|wlan0|192.168.3.99/24',other='303|wlan0|192.168.4.99/24';
function fixture(store){return loadEts('data/DeviceLanPorts',{'@kit.ArkData':{preferences:{getPreferences:async()=>store}},'../jobs/DeviceInstallTarget':{DeviceInstallTarget}}).DeviceLanPorts;}
function store(){const values=new Map();return {values,get:async(k,d)=>values.get(k)??d,put:async(k,v)=>values.set(k,v),flush:async()=>{}};}
test('ports survive restart and a missing device, follow IP rather than row order, and tolerate DHCP/net-ID changes',async()=>{
 const disk=store(),D=fixture(disk);await D.load({});
 await D.save({},lan,'192.168.3.8','49231');await D.save({},lan,'192.168.3.20','54104');
 const restarted=fixture(disk);await restarted.load({});
 assert.equal(restarted.get(renewed,'192.168.3.20'),'54104');assert.equal(restarted.get(renewed,'192.168.3.8'),'49231');
 assert.equal(restarted.get(other,'192.168.3.8'),'');assert.equal(restarted.get(renewed,'192.168.3.9'),'');
 await restarted.save({},renewed,'192.168.3.8','');const again=fixture(disk);await again.load({});assert.equal(again.get(lan,'192.168.3.8'),'');
});
test('an edit or clear during startup wins over a delayed disk read',async()=>{
 const disk=store(),seed=fixture(disk);await seed.save({},lan,'192.168.3.8','49231');
 for(const port of ['54321','']){
  let release;const gate=new Promise(resolve=>release=resolve),raw=disk.values.get('ports');
  const D=fixture({get:async()=>{await gate;return raw;},put:disk.put,flush:disk.flush});
  const loading=D.load({});await new Promise(resolve=>setImmediate(resolve));const writing=D.save({},lan,'192.168.3.8',port);release();
  await Promise.all([loading,writing]);assert.equal(D.get(lan,'192.168.3.8'),port);
 }
});
test('invalid drafts are not persisted and failed writes do not block a later edit',async()=>{
 const disk=store(),D=fixture(disk);await D.load({});
 for(const port of ['1234','65536','00000','12abc'])await D.save({},lan,'192.168.3.8',port);
 assert.equal(disk.values.size,0);await D.save({},'', '192.168.3.8','54321');assert.equal(disk.values.size,0);
 let failed=true;disk.put=async(k,v)=>{if(failed){failed=false;throw Error('temporary');}disk.values.set(k,v);};
 await assert.rejects(D.save({},lan,'192.168.3.8','49231'),/temporary/);await D.save({},lan,'192.168.3.8','49231');
 const restarted=fixture(disk);await restarted.load({});assert.equal(restarted.get(lan,'192.168.3.8'),'49231');
});
