const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(component){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/'+component+'.ets'),'utf8');
 const struct=source.slice(source.indexOf('export struct '+component));
 function method(name){const a=struct.search(new RegExp('^  (?:private )?'+name+'\\(','m'));assert(a>=0);return struct.slice(a,struct.indexOf('\n  }',a)+4);}
 const ready=component==='DiscoverHeader'?'refreshPopup':'onActiveChanged';
 const f={frames:[],start:0,stop:0};
 const sliceModule={};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/components/DiscoverCategorySlice.ets'),'utf8'),{
   compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}
  }).outputText,{exports:sliceModule,Observed:value=>value,Track:()=>{}});
 const motionBox={};
 const toolbarSource=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DiscoverHeader.ets'),'utf8');
 const motionSource=toolbarSource.slice(toolbarSource.indexOf('export class DiscoverToolbarMotion'),toolbarSource.indexOf('export class DiscoverToolbarViewport'));
 vm.runInNewContext(ts.transpileModule(motionSource,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,{exports:motionBox});
 const box={I18n:{category:value=>value},StoreLayout:{contentInset:()=>16},StoreMaterial:{supported:mode=>mode!=='off'},afterPaint:(_,fn)=>f.frames.push(fn),DiscoverCategorySlice:sliceModule.DiscoverCategorySlice,DiscoverToolbarMotion:motionBox.DiscoverToolbarMotion};
 const methods=['aboutToAppear','aboutToDisappear',ready];
 if(component==='DiscoverHeader')methods.push('onMaterialChanged','searchControlWidth','categoryControlWidth',
  'refreshCategorySlices','sliceFor','onCategoriesChanged','onViewportChanged','isLandscape','mainCategoryWidth',
  'toolbarWidth','toolbarInteractive','nativeToolbarEligible','suspendToolbarPopup','searchPopupRequested');
 vm.runInNewContext(ts.transpileModule('class Page{'+methods.map(method).join('\n')+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 f.ui=Object.assign(new box.Page(),{homeVisibility:{visible:true},active:true,immersiveSupported:true,materialMode:'adaptive',routeTransitioning:false,disposed:false,popupGeneration:0,popupReady:false,
  windowWidth:364,windowHeight:822,categories:[],categorySlices:new Map(),toolbarMotionGeneration:0,
  toolbarRows:2,toolbarProgress:1,categoryOffset:0,channel:'apps',channelProgress:1,onMotionStateChanged() {},
  getUIContext:()=>({}),
  holding:{start(){f.start++;},stop(){f.stop++;}}});
 f.refresh=()=>f.ui[ready]();f.paint=()=>{const frames=f.frames.splice(0);frames.forEach(fn=>fn());};return f;
}
test('one-row search and categories share the toolbar width during the morph',()=>{
 const f=fixture('DiscoverHeader');f.ui.toolbarRows=1;
 for (const progress of [0,.25,.5,1,.5,0]) {
  f.ui.toolbarProgress=progress;
  assert.equal(f.ui.searchControlWidth()+f.ui.categoryControlWidth()+64,f.ui.toolbarWidth());
 }
 assert.equal(f.ui.searchControlWidth(),f.ui.toolbarWidth()-108);
 f.ui.toolbarProgress=1;assert.equal(f.ui.searchControlWidth(),44);
});
for(const component of ['DiscoverHeader','DiscoverTopAction']){
 test(component+' restores native material only after a paint and coalesces repeated foreground signals',()=>{
  const f=fixture(component);f.ui.aboutToAppear();f.refresh();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.paint();
  if(component==='DiscoverHeader'){assert(!f.ui.popupReady);f.paint();}
  assert(f.ui.popupReady);assert.equal(f.start,component==='DiscoverTopAction'?1:0);
  f.refresh();assert.equal(f.frames.length,0,'an already restored popup must not be rebuilt');
 });
 test(component+' invalidates late callbacks on hiding, route transitions and disposal',()=>{
  const f=fixture(component);f.ui.aboutToAppear();f.ui.active=false;f.refresh();f.paint();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.ui.active=true;f.refresh();f.ui.routeTransitioning=true;f.refresh();f.paint();assert(!f.ui.popupReady);
  f.ui.routeTransitioning=false;f.refresh();f.ui.aboutToDisappear();f.paint();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.ui.aboutToAppear();f.paint();
  if(component==='DiscoverHeader')f.paint();
  assert(f.ui.popupReady);
 });
}

test('visibility geometry retains full control dimensions and skips position work for hidden categories',()=>{
 const f=fixture('DiscoverHeader');f.ui.categories=['办公','工具','安全隐私'];
 f.ui.refreshCategorySlices();const safety=f.ui.sliceFor('安全隐私');
 assert.equal(safety.visibleWidth,56);assert.equal(safety.viewportOffset,222);
 f.ui.categoryOffset=40;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,88);assert.equal(safety.viewportOffset,182);
 f.ui.categoryOffset=450;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,0);const hiddenOffset=safety.viewportOffset;
 f.ui.categoryOffset=500;f.ui.refreshCategorySlices();assert.equal(safety.viewportOffset,hiddenOffset);
 f.ui.categoryOffset=250;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,60);assert.equal(safety.viewportOffset,-28);
});

test('a category keeps its light material as it approaches the fixed edge',()=>{
 const f=fixture('DiscoverHeader');f.ui.categories=['其他','办公','安全隐私','实用工具','工具'];
 for(const offset of [0,20,40,60,100]){
  f.ui.categoryOffset=offset;f.ui.refreshCategorySlices();
  assert(f.ui.sliceFor('实用工具').materialVisible);
 }
 f.ui.categoryOffset=900;f.ui.refreshCategorySlices();
 assert(!f.ui.sliceFor('其他').materialVisible);
});

test('API 24/25 inline search and categories never wait for a popup paint on lifecycle changes',()=>{
 const f=fixture('DiscoverHeader');f.ui.immersiveSupported=false;f.ui.aboutToAppear();
 assert(f.ui.popupReady);assert.equal(f.frames.length,0);
 for(const visible of [false,true,false,true]){
  f.ui.homeVisibility.visible=visible;f.refresh();
  assert(f.ui.popupReady);assert.equal(f.frames.length,0);
 }
 f.ui.active=false;f.ui.routeTransitioning=true;f.refresh();
 assert.equal(f.frames.length,0,'route and control enabled state still gate the inline buttons directly');
});
test('changing material to off cancels queued search popup restores and reenable waits for a fresh paint',()=>{
 const f=fixture('DiscoverHeader');f.ui.aboutToAppear();assert.equal(f.frames.length,1);
 f.ui.materialMode='off';f.ui.onMaterialChanged();assert.equal(f.ui.immersiveSupported,false);assert.equal(f.ui.popupReady,true);
 f.ui.active=false;f.paint();assert.equal(f.ui.popupReady,true,'retired native callbacks cannot change the inline fallback');
 f.ui.active=true;f.ui.materialMode='adaptive';f.ui.onMaterialChanged();assert.equal(f.ui.popupReady,false);
 f.paint();assert.equal(f.ui.popupReady,false);
 f.paint();assert.equal(f.ui.popupReady,true);assert.equal(f.ui.immersiveSupported,true);
});

test('swiping and settling keep one toolbar geometry while native windows wait for a stable frame',()=>{
 const f=fixture('DiscoverHeader');
 f.ui.channel='discover';f.ui.channelProgress=0;f.ui.aboutToAppear();f.paint();
 assert(!f.ui.searchPopupRequested());
 const widths=[f.ui.searchControlWidth(),f.ui.categoryControlWidth()];
 f.ui.channelInMotion=true;f.ui.channelProgress=.5;f.refresh();
 assert(f.ui.suspendToolbarPopup());
 assert(!f.ui.toolbarInteractive());
 assert.deepEqual([f.ui.searchControlWidth(),f.ui.categoryControlWidth()],widths);
 f.ui.channel='apps';f.refresh();f.paint();
 assert(!f.ui.searchPopupRequested());
 f.ui.channelInMotion=false;f.refresh();assert(!f.ui.searchPopupRequested());
 assert(f.ui.toolbarInteractive(), 'inline controls become usable before native material attaches');
 f.paint();assert(!f.ui.searchPopupRequested(), 'allow a frame for scroll restoration to move the anchors');
 f.paint();assert(f.ui.searchPopupRequested());
 f.ui.searchPopupVisible=true;f.ui.channelInMotion=true;f.refresh();
 assert(!f.ui.searchPopupVisible);
 f.ui.channelInMotion=false;f.refresh();f.paint();
 f.ui.channelInMotion=true;f.refresh();f.paint();
 assert(!f.ui.searchPopupRequested(), 'a new swipe invalidates a queued native handoff');
});

test('the two-row toolbar gives search the full width and leaves room for sort below',()=>{
 const f=fixture('DiscoverHeader');
 for (const available of [240,320,520,720]) {
  f.ui.windowWidth=available+32;
  assert.equal(f.ui.searchControlWidth(),available);
  assert.equal(f.ui.categoryControlWidth()+54,available);
 }
});

test('viewport changes defer category scrolling and skip the detached discover toolbar',()=>{
 const f=fixture('DiscoverHeader');
 let offset=100, resets=0;
 f.ui.toolbarRows=1;
 f.ui.channel='discover';
 f.ui.categoryOffset=offset;
 f.ui.categoryScroller={currentOffset:()=>({xOffset:offset}),scrollTo:()=>{resets++;offset=0;}};
 f.ui.onViewportChanged();
 f.paint();
 assert.equal(resets,0,'the category scroller is not mounted in the Discover channel');
 f.ui.channel='apps';
 f.ui.onViewportChanged();
 f.ui.onViewportChanged();
 assert.equal(resets,0,'resize observers must not scroll during layout');
 f.paint();
 assert.equal(resets,1,'only the last viewport update resets the attached scroller');
});
