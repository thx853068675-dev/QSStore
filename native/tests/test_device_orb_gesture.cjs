const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
function fixture(original=true){
 let now=1000,next=0;const timers=new Map(),calls=[];
 const {DeviceOrbGestureGuard:guard}=loadEts('jobs/DeviceOrbGestureGuard',{},
  {Date:{now:()=>now},setTimeout:(fn,ms)=>{timers.set(++next,{fn,ms});return next;},clearTimeout:id=>timers.delete(id)});
 const win={isGestureBackEnabled:()=>original,setGestureBackEnabled:async value=>{calls.push(value);}};
 guard.attach(win);
 return {guard,win,timers,calls,advance:(ms)=>{now+=ms;for(const [id,t] of [...timers])if(t.ms<=ms){timers.delete(id);t.fn();}}};
}
test('ordinary page touches and idle foreground releases never change window gestures',async()=>{
 const {guard,calls}=fixture();assert.equal(guard.blocksBack(),false);guard.release();await guard.tail;assert.deepEqual(calls,[]);
});
test('a handle touch disables side return for its sequence, then restores the original setting after release',async()=>{
 const {guard,calls,advance}=fixture();guard.begin();await guard.tail;assert.deepEqual(calls,[false]);assert.equal(guard.blocksBack(),true);
 guard.end();assert.equal(guard.blocksBack(),true);advance(280);await guard.tail;assert.equal(guard.blocksBack(),false);assert.deepEqual(calls,[false,true]);
});
test('rapid repeated drags cannot let a late restore re-enable side return during the next drag',async()=>{
 const {guard,calls,advance}=fixture();guard.begin();await guard.tail;guard.end();advance(280);guard.begin();await guard.tail;
 assert.equal(calls.at(-1),false);assert.equal(guard.blocksBack(),true);guard.release();await guard.tail;assert.equal(calls.at(-1),true);
});
test('an originally disabled gesture setting remains disabled after a handle interaction',async()=>{
 const {guard,calls,advance}=fixture(false);guard.begin();await guard.tail;guard.end();advance(280);await guard.tail;assert(calls.every(v=>v===false));
});
test('detach restores after an in-flight disable and ignores any old queued request',async()=>{
 const {guard,win,calls}=fixture();let finish;win.setGestureBackEnabled=async value=>{calls.push(value);if(!value)await new Promise(resolve=>{finish=resolve;});};
 guard.begin();await Promise.resolve();await Promise.resolve();guard.detach();finish();await guard.tail;assert.deepEqual(calls,[false,true]);assert.equal(guard.blocksBack(),false);
});
test('unsupported window calls do not crash touch handling and the back guard always expires',async()=>{
 const {guard,win,advance}=fixture();win.setGestureBackEnabled=async()=>{throw Error('not supported');};guard.begin();await guard.tail;
 assert.equal(guard.blocksBack(),true);guard.end();advance(280);await guard.tail;assert.equal(guard.blocksBack(),false);
});
test('a system-cancelled handle drag consumes its delayed back event without leaving window navigation disabled',async()=>{
 const {guard,calls,advance}=fixture();guard.begin();await guard.tail;guard.end(true);await guard.tail;
 assert.equal(calls.at(-1),true);advance(850);assert.equal(guard.blocksBack(),true);
 guard.release();await guard.tail;assert.equal(guard.blocksBack(),false);
});
