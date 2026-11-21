const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const tick=()=>new Promise(setImmediate);
const transport=code=>Object.assign(Error('private transport detail'),{code});
function fixture(){
 const f={connected:true,vpn:true,validated:true,portal:false,checking:false,allowed:true,head:{responseCode:302},calls:[],destroyed:0,timers:new Map(),now:100000};let serial=0;
 const connection={NetCap:{NET_CAPABILITY_VALIDATED:16,NET_CAPABILITY_PORTAL:17,NET_CAPABILITY_CHECKING_CONNECTIVITY:31},NetBearType:{BEARER_VPN:4},
  hasDefaultNet:async()=>f.connected,getDefaultNet:async()=>({netId:1}),getAllNets:async()=>f.vpn?[{netId:1},{netId:2}]:[{netId:1}],
  getNetCapabilities:async(net)=>({networkCap:[...(f.validated?[16]:[]),...(f.portal?[17]:[]),...(f.checking?[31]:[])],bearerTypes:net.netId===2?[4]:[1]})};
 const kit={connection,http:{RequestMethod:{HEAD:'HEAD'},createHttp:()=>({request:async(url,options)=>{f.calls.push({url,options});const value=await f.head;if(value instanceof Error)throw value;return value;},destroy(){f.destroyed++;}})}};
 const consent={assertBusinessAllowed(){if(!f.allowed)throw Error('consent required');}};
 const exports=loadEts('data/StoreConnectivity',{'@kit.NetworkKit':kit,'./PrivacyConsent':{PrivacyConsent:consent}},
  {Date:{now:()=>f.now},setTimeout:(fn,ms)=>{const id=++serial;f.timers.set(id,{fn,ms});return id;},clearTimeout:id=>f.timers.delete(id)});
 Object.assign(f,exports);f.explain=(code=2300035)=>f.StoreConnectivity.explain(transport(code));
 f.fire=ms=>{const pair=[...f.timers].find(([,v])=>v.ms===ms);assert(pair,'expected bounded timer');f.timers.delete(pair[0]);pair[1].fn();};return f;
}
test('offline and captive networks show actionable network guidance without an internet probe',async()=>{
 const f=fixture();f.connected=false;assert.match((await f.explain()).message,/网络未连接/);assert.equal(f.calls.length,0);
 const portal=fixture();portal.portal=true;assert.match((await portal.explain()).message,/需要认证/);assert.equal(portal.calls.length,0);
});
test('reachable internet with a failed store suggests changing nodes only conditionally when VPN is unknown',async()=>{
 const f=fixture(),error=await f.explain();assert.match(error.message,/网络正常.*更换代理节点/);assert.equal(error.code,2300035);
 assert.equal(error.userMessage,error.message);assert.equal(f.calls.length,1);assert.equal(f.destroyed,1);assert.equal(f.timers.size,0);
 const call=f.calls[0];assert.equal(call.url,'https://www.huawei.com/');assert.equal(call.options.method,'HEAD');
 assert.equal(call.options.usingCache,false);assert.equal(call.options.extraData,undefined);assert.equal(call.options.header.Authorization,undefined);
 assert.equal(call.options.certificatePinning,undefined);assert.equal(call.options.caData,undefined);
 const plain=fixture();plain.vpn=false;assert.match((await plain.explain()).message,/如使用代理/);
});
test('HTTP service errors, certificate failures, authentication and parameter errors do not blame proxy nodes or probe',async()=>{
 for(const status of [200,401,403,429,503]){
  const f=fixture(),error=await f.StoreConnectivity.explain(Object.assign(Error('bad response'),{code:0,status}));
  assert.match(error.message,status===429?/过于频繁/:/服务响应异常/);assert.doesNotMatch(error.message,/节点/);assert.equal(f.calls.length,0);
 }
 for(const code of [2300058,2300060,2300077,2300090]){
  const f=fixture();assert.match((await f.explain(code)).message,/安全连接校验失败/);assert.equal(f.calls.length,0);
 }
 for(const code of [401,201,2300003]){
  const f=fixture(),error=transport(code);assert.equal(await f.StoreConnectivity.explain(error),error);assert.equal(f.calls.length,0);
 }
});
test('failure diagnostics coalesce, expire and invalidate on network changes without polling',async()=>{
 const f=fixture();await Promise.all([f.explain(),f.explain(2300028),f.explain(2300999)]);assert.equal(f.calls.length,1);
 await f.explain();assert.equal(f.calls.length,1);assert.equal(f.timers.size,0);
 f.now+=10001;await f.explain();assert.equal(f.calls.length,2);
 f.StoreConnectivity.reset();await f.explain();assert.equal(f.calls.length,3);
});
test('a stalled public probe times out and releases its request, and old-network evidence cannot classify a new connection',async()=>{
 const f=fixture();f.head=new Promise(()=>{});const pending=f.explain();await tick();f.fire(900);
 assert.match((await pending).message,/尝试更换代理节点/);assert.equal(f.destroyed,1);assert.equal(f.timers.size,0);
 const changed=fixture();let resolve;changed.head=new Promise(r=>resolve=r);const old=changed.explain();await tick();
 changed.StoreConnectivity.reset();resolve({responseCode:200});assert.match((await old).message,/网络已切换/);
 await changed.explain();assert.equal(changed.calls.length,2);
});
test('privacy withdrawal prevents or terminates diagnosis without exposing raw transport details to users',async()=>{
 const f=fixture();f.allowed=false;await assert.rejects(f.explain(),/consent/);assert.equal(f.calls.length,0);
 const next=fixture();let resolve;next.head=new Promise(r=>resolve=r);const pending=next.explain();await tick();next.allowed=false;resolve({responseCode:200});await assert.rejects(pending,/consent/);assert.equal(next.destroyed,1);
 const {errorText}=loadEts('jobs/ErrorText');const clean=fixture(),failure=await clean.explain();
 assert.equal(errorText(failure),failure.userMessage);assert.doesNotMatch(errorText(failure),/2300035|private transport/);
});
