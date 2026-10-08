const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(component){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/'+component+'.ets'),'utf8');
 const struct=source.slice(source.indexOf('export struct '+component));
 function method(name){const a=struct.search(new RegExp('^  (?:private )?'+name+'\\(','m'));assert(a>=0);return struct.slice(a,struct.indexOf('\n  }',a)+4);}
 const ready=component==='DiscoverHeader'?'refreshPopup':'onActiveChanged';
 const f={frames:[],animations:[],motion:[],start:0,stop:0};
 const sliceModule={};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/components/DiscoverCategorySlice.ets'),'utf8'),{
   compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}
  }).outputText,{exports:sliceModule,Observed:value=>value,Track:()=>{}});
 const box={afterPaint:(_,fn)=>f.frames.push(fn),DiscoverCategorySlice:sliceModule.DiscoverCategorySlice,
  DiscoverToolbarMotion:{options:(begin,end)=>({duration:560,begin,end})}};
 const methods=['aboutToAppear','aboutToDisappear',ready];
 if(component==='DiscoverHeader')methods.push('mainCategoryWidth','onToolbarModeChanged','searchControlWidth','categoryControlWidth',
  'refreshCategorySlices','sliceFor','onCategoriesChanged');
 vm.runInNewContext(ts.transpileModule('class Page{'+methods.map(method).join('\n')+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 f.ui=Object.assign(new box.Page(),{homeVisibility:{visible:true},active:true,immersiveSupported:true,routeTransitioning:false,disposed:false,popupGeneration:0,popupReady:false,
  categories:[],categorySlices:new Map(),searchWidth:386,categoryOffset:0,
  categoryScroller:{scrollTo(options){f.scrollOffset=options.xOffset;}},
  categoriesExpanded:false,categoriesOpen:false,toolbarMotionGeneration:0,toolbarProgress:0,
  onMotionStateChanged:moving=>f.motion.push(moving),
  getUIContext:()=>({createAnimator(options){
   const animation={options,play(){this.playing=true;},cancel(){this.cancelled=true;}};
   f.animations.push(animation);return animation;
  }}),
  holding:{start(){f.start++;},stop(){f.stop++;}}});
 f.refresh=()=>f.ui[ready]();f.paint=()=>{const frames=f.frames.splice(0);frames.forEach(fn=>fn());};return f;
}
test('rapidly reversing the toolbar cannot let an old completion reenable page caching mid-animation',()=>{
 const f=fixture('DiscoverHeader');f.ui.aboutToAppear();
 f.ui.categoriesExpanded=true;f.ui.onToolbarModeChanged();assert(f.ui.categoriesOpen);
 f.animations[0].onFrame(.4);assert.equal(f.ui.toolbarProgress,.4);
 f.ui.categoriesExpanded=false;f.ui.onToolbarModeChanged();assert(!f.ui.categoriesOpen);
 assert(f.animations[0].cancelled);assert.equal(f.animations[1].options.begin,.4);
 f.animations[0].onFrame(.8);assert.equal(f.ui.toolbarProgress,.4,'cancelled frames must not move the new animation');
 assert.deepEqual(f.motion,[true,true]);
 f.animations[0].onFinish();assert.deepEqual(f.motion,[true,true]);
 f.animations[1].onFinish();assert.deepEqual(f.motion,[true,true,false]);
 f.ui.categoriesExpanded=true;f.ui.onToolbarModeChanged();f.ui.aboutToDisappear();
 const count=f.motion.length;f.animations[2].onFinish();assert.equal(f.motion.length,count);
});
test('one frame progress keeps search width and category reveal within the same toolbar',()=>{
 const f=fixture('DiscoverHeader');
 for(const progress of [0,.1,.5,.9,1]){
  f.ui.toolbarProgress=progress;
  assert(Math.abs(f.ui.searchControlWidth()+f.ui.categoryControlWidth()+44+20-f.ui.searchWidth)<.0001);
  assert.equal(f.ui.mainCategoryWidth(),44+20*progress);
 }
});
test('closing a scrolled category row returns its shared button in sync and finalizes at the start',()=>{
 const f=fixture('DiscoverHeader');f.ui.aboutToAppear();
 f.ui.categoriesExpanded=true;f.ui.onToolbarModeChanged();f.animations[0].onFrame(.4);
 f.ui.categoryOffset=100;f.ui.categoriesExpanded=false;f.ui.onToolbarModeChanged();
 f.animations[1].onFrame(.2);assert.equal(f.scrollOffset,50);
 f.animations[1].onFinish();assert.equal(f.scrollOffset,0);assert.equal(f.ui.categoryOffset,0);
 assert.equal(f.ui.mainCategoryWidth(),44);
});
for(const component of ['DiscoverHeader','DiscoverTopAction']){
 test(component+' restores native material only after a paint and coalesces repeated foreground signals',()=>{
  const f=fixture(component);f.ui.aboutToAppear();f.refresh();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.paint();assert(f.ui.popupReady);assert.equal(f.start,component==='DiscoverTopAction'?1:0);
  f.refresh();assert.equal(f.frames.length,0,'an already restored popup must not be rebuilt');
 });
 test(component+' invalidates late callbacks on hiding, route transitions and disposal',()=>{
  const f=fixture(component);f.ui.aboutToAppear();f.ui.active=false;f.refresh();f.paint();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.ui.active=true;f.refresh();f.ui.routeTransitioning=true;f.refresh();f.paint();assert(!f.ui.popupReady);
  f.ui.routeTransitioning=false;f.refresh();f.ui.aboutToDisappear();f.paint();assert(!f.ui.popupReady);assert.equal(f.start,0);
  f.ui.aboutToAppear();f.paint();assert(f.ui.popupReady);
 });
}

test('visibility geometry retains full control dimensions and skips position work for hidden categories',()=>{
 const f=fixture('DiscoverHeader');f.ui.categories=['办公','工具','安全隐私'];f.ui.toolbarProgress=1;
 f.ui.refreshCategorySlices();const safety=f.ui.sliceFor('安全隐私');
 assert.equal(safety.visibleWidth,56);assert.equal(safety.viewportOffset,222);
 f.ui.categoryOffset=40;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,88);assert.equal(safety.viewportOffset,182);
 f.ui.categoryOffset=450;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,0);const hiddenOffset=safety.viewportOffset;
 f.ui.categoryOffset=500;f.ui.refreshCategorySlices();assert.equal(safety.viewportOffset,hiddenOffset);
 f.ui.categoryOffset=250;f.ui.refreshCategorySlices();
 assert.equal(safety.visibleWidth,60);assert.equal(safety.viewportOffset,-28);
 assert.equal(f.ui.mainCategoryWidth(),64);
});

test('opening and closing a category viewport keeps its edge materials alive behind the fixed mask',()=>{
 const f=fixture('DiscoverHeader');f.ui.categories=['其他','办公','安全隐私','实用工具','工具'];
 for(const progress of [0,.01,.2,.6,1,.6,.2,0]){
  f.ui.toolbarProgress=progress;f.ui.refreshCategorySlices();
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

test('search, category and fixed sorting capsule fit compact phones throughout the morph',()=>{
 const f=fixture('DiscoverHeader');
 for(const width of [240,280,320,406,560]){
  f.ui.searchWidth=width;
  for(const progress of [0,.25,.5,.75,1]){
   f.ui.toolbarProgress=progress;
   assert.equal(f.ui.searchControlWidth()+f.ui.categoryControlWidth()+44+20,width);
   assert(f.ui.searchControlWidth()>=44);assert(f.ui.categoryControlWidth()>=44);
  }
 }
});
