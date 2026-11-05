const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
function fixture(store){return loadEts('data/DeviceDiscoveryPreferences',{'@kit.ArkData':{preferences:{getPreferences:async()=>store}}}).DeviceDiscoveryPreferences;}
test('the connection view survives a fresh preferences instance',async()=>{
 const values=new Map(),store={get:async(k,d)=>values.get(k)??d,put:async(k,v)=>values.set(k,v),flush:async()=>{}};
 const first=fixture(store);assert.equal(await first.load({}),false);await first.save({},true);
 const restarted=fixture(store);assert.equal(await restarted.load({}),true);assert.equal(restarted.current(),true);
 await restarted.save({},false);assert.equal(await fixture(store).load({}),false);
});
test('a late disk read cannot overwrite a view chosen while the read was pending',async()=>{
 let release;const gate=new Promise(resolve=>release=resolve);
 const D=fixture({get:async()=>gate,put:async()=>{},flush:async()=>{}}),loading=D.load({});
 await new Promise(resolve=>setImmediate(resolve));await D.save({},true);release(false);
 assert.equal(await loading,true);assert.equal(D.current(),true);
});
test('rapid writes keep order and a failed write cannot block the next choice',async()=>{
 const calls=[];let fail=true;
 const D=fixture({get:async()=>false,put:async(k,v)=>{calls.push(v);if(fail){fail=false;throw Error('temporary failure');}},flush:async()=>{}});
 const a=D.save({},true),b=D.save({},false);await assert.rejects(a,/temporary/);await b;
 assert.deepEqual(calls,[true,false]);assert.equal(D.current(),false);
});
