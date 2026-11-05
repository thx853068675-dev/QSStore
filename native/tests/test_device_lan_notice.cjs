const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
function fixture(){
 let next=0;const timers=new Map(),history=[];
 const {DeviceLanDraft}=loadEts('data/DeviceLanDraft',{}, {Observed:x=>x,
  setTimeout:(fn,delay)=>{const id=++next;timers.set(id,fn);history.push({fn,delay});return id;},
  clearTimeout:id=>timers.delete(id)});
 const draft=new DeviceLanDraft();return{draft,timers,history};
}
test('port notices expire in ten seconds without losing the saved draft',()=>{
 const {draft,timers,history}=fixture();let changes=0;draft.onNoticeChanged=()=>changes++;
 draft.port='49231';draft.edited=true;draft.setNotice('端口未开启');
 assert.equal(history[0].delay,10000);assert.equal(draft.notice,'端口未开启');
 [...timers.values()][0]();assert.equal(draft.notice,'');assert.equal(draft.port,'49231');assert.equal(draft.edited,true);assert.equal(changes,2);
});
test('a replaced, edited or disposed notice cannot be cleared by an older callback',()=>{
 const {draft,timers,history}=fixture();
 draft.setNotice('first');draft.setNotice('second');assert.equal(timers.size,1);
 history[0].fn();assert.equal(draft.notice,'second');
 draft.setNotice('');assert.equal(timers.size,0);history[1].fn();assert.equal(draft.notice,'');
 draft.setNotice('third');draft.dispose();assert.equal(timers.size,0);history[2].fn();assert.equal(draft.notice,'');
});
