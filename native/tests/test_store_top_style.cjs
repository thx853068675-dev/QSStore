const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/theme/StoreDesign.ets'),'utf8');
const start=source.indexOf('export class StoreTopStyle {');let depth=1,end=source.indexOf('{',start)+1;
for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;if(source[end]==='}')depth--;}
const box={exports:{},MaterialPreferences:{type:mode=>mode==='off'?0:1},LengthMetrics:{vp:value=>value},Color:{Transparent:'transparent'},
 hdsMaterial:{MaterialType:{IMMERSIVE:1},MaterialLevel:{ADAPTIVE:0}},BlurStrategy:{ENABLE:1},
 ScrollEffectType:{GRADIENT_BLUR:2,IMMERSIVE_GRADIENT_BLUR:3},Palette:{forMode:dark=>({bg:dark?'#161F2E':'#F7F9FC'})}};
vm.runInNewContext(ts.transpileModule(source.slice(start,end),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,box);
const {StoreTopStyle}=box.exports;
test('pinned title starts native blur on the first movement and completes before content crosses its title',()=>{
 for(const status of [0,24,39,48,56])for(const dark of [false,true]){
  const opts=StoreTopStyle.navigationStyle(56,status,dark,0,true).scrollEffectOpts;
  assert.equal(opts.blurEffectiveStartOffset,0);assert.equal(opts.blurEffectiveEndOffset,12);
  assert.equal(opts.enableRefreshOffsetChange,false);
  const progress=travel=>Math.max(0,Math.min(1,(travel-opts.blurEffectiveStartOffset)/(opts.blurEffectiveEndOffset-opts.blurEffectiveStartOffset)));
  assert.equal(progress(0),0);assert(progress(1)>0);assert.equal(progress(12),1);assert.equal(progress(-20),0);
 }
});
test('discovery retains its existing scrolling title thresholds, native material and gradient height',()=>{
 for(const dark of [false,true]){
  const style=StoreTopStyle.navigationStyle(112,40,dark);
  assert.equal(style.scrollEffectOpts.blurEffectiveStartOffset,24);
  assert.equal(style.scrollEffectOpts.blurEffectiveEndOffset,72);
  assert.equal(style.blurStrategy,1);assert.equal(style.scrollEffectStyle.backgroundStyle.blurRadius,32);
  assert.equal(style.scrollEffectStyle.backgroundStyle.maskExtraHeight,16);
  assert.equal(style.systemMaterialEffect.materialType,1);
 }
});
test('explicit off keeps the existing gradient geometry but opts out of immersive HDS material',()=>{
 const style=StoreTopStyle.navigationStyle(112,40,false,2,false,'off');
 assert.equal(style.systemMaterialEffect.materialType,0);assert.equal(style.scrollEffectOpts.scrollEffectType,2);
 assert.equal(style.scrollEffectOpts.blurEffectiveStartOffset,24);assert.equal(style.scrollEffectStyle.backgroundStyle.blurRadius,32);
});
