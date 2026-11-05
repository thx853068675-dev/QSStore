const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {DeviceArtworkFrame:F}=loadEts('data/DeviceArtworkFrame',{'@kit.ImageKit':{image:{}}});
const {DeviceInstallTarget:T}=loadEts('jobs/DeviceInstallTarget');
const {DeviceStackLayout:L}=loadEts('data/DeviceStackLayout',{
 './DeviceArtworkFrame':{DeviceArtworkFrame:F},'../jobs/DeviceInstallTarget':{DeviceInstallTarget:T}
});
function frame(w,h){const f=new F();f.contentWidth=w;f.contentHeight=h;return f;}
test('one, two and three portraits center their visible union for phone, tablet and PC shapes',()=>{
 const shapes=[frame(.82,.94),frame(.94,.64),frame(.94,.536)];
 for(const a of shapes)for(const b of shapes)for(const c of shapes)for(const count of [1,2,3]){
  const frames=[a,b,c].slice(0,count),layout=new L(frames);
  const boxes=Array.from(layout.layers,(p,i)=>({
   left:p.x+p.size*(1-frames[i].contentWidth)/2,right:p.x+p.size*(1+frames[i].contentWidth)/2,
   top:p.y+p.size*(1-frames[i].contentHeight)/2,bottom:p.y+p.size*(1+frames[i].contentHeight)/2
  }));
  const left=Math.min(...boxes.map(p=>p.left)),right=Math.max(...boxes.map(p=>p.right));
  const top=Math.min(...boxes.map(p=>p.top)),bottom=Math.max(...boxes.map(p=>p.bottom));
  assert(Math.abs((left+right)/2-.5)<1e-9);assert(Math.abs((top+bottom)/2-.5)<1e-9);
  assert(left>=.03-1e-9&&right<=.97+1e-9&&top>=.03-1e-9&&bottom<=.97+1e-9);
  assert(Math.abs(Math.max(right-left,bottom-top)-.94)<1e-9);
 }
});
test('selected portraits are unique, capped at three, with local or the first chosen device in front',()=>{
 const row=key=>Object.assign(new T(),{key});
 assert.deepEqual(Array.from(L.targets([]),r=>r.key),['local']);
 assert.deepEqual(Array.from(L.targets([row('a')]),r=>r.key),['a']);
 assert.deepEqual(Array.from(L.targets([row('a'),row('local')]),r=>r.key),['a','local']);
 assert.deepEqual(Array.from(L.targets([row('a'),row('a'),row('b'),row('c'),row('local')]),r=>r.key),['b','a','local']);
 assert.deepEqual(Array.from(L.targets([row('a'),row('b'),row('c'),row('d')]),r=>r.key),['c','b','a']);
});
