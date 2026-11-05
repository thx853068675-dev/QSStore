const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {Palette}=loadEts('theme/Palette');
function fixture(supported,dark,options={}){
 let available=supported;const calls=[];const native=[];
 const store={supported:mode=>available&&mode!=='off',clearNative:instance=>instance.systemMaterial(undefined),unavailable:()=>{available=false;},fallbackFill:d=>'#E6'+Palette.forMode(d).surface.slice(1),blurStyle:()=>1,
  glass:()=>{if(options.constructorFails)throw Error('material unavailable');const value={glass:true};native.push(value);return value;},
  tinted:()=>{if(options.constructorFails)throw Error('material unavailable');const value={tinted:true};native.push(value);return value;}};
 const {DevicePanelMaterial}=loadEts('components/DevicePanelMaterial',{
  '@kit.ArkUI':{},'../theme/Palette':{Palette},'../theme/StoreMaterial':{StoreMaterial:store}
 },{Color:{Transparent:'transparent'},ThemeColorMode:{DARK:'dark',LIGHT:'light'}});
 const instance={};for(const key of ['backgroundColor','borderWidth','borderColor','backgroundBlurStyle','systemMaterial'])instance[key]=(...args)=>{
  calls.push([key,...args]);if(key==='systemMaterial'&&args[0]&&options.applyFails)throw Error('renderer unavailable');return instance;
 };
 return {calls,native,instance,DevicePanelMaterial,disable:()=>{available=false;},dark};
}
test('toolbar and IP actions use readable light/dark fallback when material is unsupported or fails',()=>{
 for(const dark of [false,true])for(const supported of [false,true])for(const options of [{},{constructorFails:true},{applyFails:true}]){
  if(supported&&!options.constructorFails&&!options.applyFails)continue;
  const f=fixture(supported,dark,options);new f.DevicePanelMaterial('adaptive',dark,false).applyNormalAttribute(f.instance);
  assert.equal(f.calls.filter(([key])=>key==='backgroundColor').at(-1)[1],'#E6'+Palette.forMode(dark).surface.slice(1));
  assert.equal(f.calls.find(([key])=>key==='backgroundBlurStyle')[2].colorMode,dark?'dark':'light');
  if(!supported)assert.equal(f.native.length,0,'old systems never create a native material');
 }
});
test('a cached native action clears its old renderer before falling back after service failure',()=>{
 const f=fixture(true,false),surface=new f.DevicePanelMaterial('strong',false,false);surface.applyNormalAttribute(f.instance);
 assert.equal(f.calls.at(-1)[0],'systemMaterial');f.calls.length=0;f.disable();surface.applyNormalAttribute(f.instance);
 assert.deepEqual(f.calls[0],['systemMaterial',undefined]);assert.equal(f.calls.find(([key])=>key==='backgroundColor')[1],'#E6FFFFFF');
});
test('explicit off on capable hardware paints the same readable panel as unsupported 6.1',()=>{
 for(const dark of [false,true])for(const selected of [false,true]){
  const f=fixture(true,dark);new f.DevicePanelMaterial('off',dark,selected).applyNormalAttribute(f.instance);
  assert.equal(f.native.length,0);assert.deepEqual(f.calls.filter(([key])=>key==='systemMaterial'),[['systemMaterial',undefined]]);
  assert.equal(f.calls.find(([key])=>key==='backgroundColor')[1],selected?Palette.forMode(dark).accent:'#E6'+Palette.forMode(dark).surface.slice(1));
 }
});
