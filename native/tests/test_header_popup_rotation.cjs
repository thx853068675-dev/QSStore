const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/theme/StoreDesign.ets'),'utf8');
function fixture(supported=true){
 const start=source.indexOf('export struct StoreImmersiveIconButton {'),end=source.indexOf('  private controlWidth()',start);
 const code=source.slice(start,end).replace('export struct','class').replace(/@(StorageProp|Watch)\([^)]*\)\s*|@(Prop|State)\s*/g,'');
 let seq=0;const timers=new Map();
 const box={exports:{},I18n:{t:x=>x},$r:x=>x,StoreMaterial:{supported:mode=>supported&&mode!=='off'},
  setTimeout:fn=>{timers.set(++seq,fn);return seq;},clearTimeout:id=>timers.delete(id)};
 vm.runInNewContext(ts.transpileModule(code+'}\nexports.Button=StoreImmersiveIconButton;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}
 }).outputText,box);
 const button=new box.exports.Button();button.aboutToAppear();
 return {button,timers,flush:()=>{const callbacks=[...timers.values()];timers.clear();callbacks.forEach(fn=>fn());}};
}
test('rotation keeps header actions usable while their native window and anchor are recreated',()=>{
 const f=fixture(),b=f.button;
 assert(b.popupRequested());assert(b.fallbackVisible());
 b.onPopupStateChanged(true);assert(!b.fallbackVisible());
 for(let i=0;i<4;i++){
  b.onViewportChanged();b.onViewportChanged();assert.equal(f.timers.size,1);
  assert(!b.popupRequested());assert(b.fallbackVisible());
  b.onPopupStateChanged(true);assert(!b.popupVisible,'late acknowledgement belongs to the old orientation');
  f.flush();assert(b.popupRequested());assert(b.fallbackVisible());
  b.onPopupStateChanged(true);assert(!b.fallbackVisible());
 }
});
test('unexpected native dismissal retries once, then leaves a usable inline button without retry loops',()=>{
 const f=fixture(),b=f.button;b.onPopupStateChanged(true);b.onPopupStateChanged(false);
 assert.equal(f.timers.size,1);assert(b.fallbackVisible());f.flush();
 b.onPopupStateChanged(false);assert.equal(f.timers.size,0);assert(b.fallbackVisible());
});
test('page hiding, navigation, and disposal cannot resurrect an old native button',()=>{
 for(const field of ['visible','routeTransitioning']){
  const f=fixture(),b=f.button;b.onPopupStateChanged(true);b.onViewportChanged();
  b[field]=field==='visible'?false:true;b.onPopupRequestChanged();f.flush();
  b.onPopupStateChanged(true);assert(!b.popupVisible);assert(!b.fallbackVisible());
  b[field]=field==='visible'?true:false;b.onPopupRequestChanged();assert(b.fallbackVisible());
 }
 const f=fixture();f.button.onViewportChanged();f.button.aboutToDisappear();
 assert.equal(f.timers.size,0);f.button.onPopupStateChanged(true);assert(!f.button.popupVisible);
});
test('older systems and material-off mode retain inline header buttons across every resize',()=>{
 for(const supported of [true,false]){
  const f=fixture(supported),b=f.button;if(supported)b.materialMode='off';
  b.onPopupRequestChanged();
  for(let i=0;i<3;i++){b.onViewportChanged();assert(!b.popupRequested());assert(b.fallbackVisible());}
  assert.equal(f.timers.size,0);
 }
});
