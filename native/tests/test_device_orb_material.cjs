const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
function fixture(supported,options={}){
 let available=supported;
 const native=[];
 const colors={accent:'#2563EB',textSecondary:'#637085',surface:'#FFFFFF',border:'#E1E5EC',devicePanelTint:'#80FFFFFF'};
 const {DeviceOrbMaterial}=loadEts('components/DeviceOrbMaterial',{
  '@kit.ArkUI':{uiMaterial:{ImmersiveMaterial:class{constructor(value){assert(supported);if(options.constructorFails)throw Error('unsupported GPU');Object.assign(this,value);native.push(this);}}}},
  '../data/MaterialPreferences':{MaterialPreferences:{style:mode=>mode==='strong'?0:1,lightColor:(_mode,color)=>color}},
  '../theme/Palette':{Palette:{forMode:dark=>({...colors,devicePanelTint:dark?'#80000000':'#80FFFFFF'})}},
  '../theme/StoreMaterial':{StoreMaterial:{supported:mode=>available&&mode!=='off',clearNative:instance=>instance.systemMaterial(undefined),fallbackFill:()=> '#E6FFFFFF',unavailable(){available=false;}}}
 },{Color:{Transparent:'transparent'}});
 const calls=[],instance={};
 for(const name of ['backgroundColor','borderWidth','borderColor','shadow','systemMaterial'])instance[name]=value=>{calls.push([name,value]);if(name==='systemMaterial'&&value&&options.applyFails)throw Error('material renderer unavailable');return instance;};
 return {DeviceOrbMaterial,native,calls,instance};
}
test('same-layer device glass adds a 50 percent light tint without adding native deformation animation',()=>{
 const {DeviceOrbMaterial,native,calls,instance}=fixture(true);
 const surface=new DeviceOrbMaterial('adaptive',false);surface.applyNormalAttribute(instance);
 assert.equal(native.length,1);assert.equal(native[0].materialColor,'#80FFFFFF');
 assert.equal(native[0].interactive,false,'the shared spring is the only owner of shape animation');
 assert.equal(native[0].lightEffect,null,'the panel has no whole-surface touch light');assert.equal(native[0].colorInvert,true);
 assert.deepEqual(calls.slice(0,2),[['backgroundColor','transparent'],['borderWidth',0]]);
 assert.equal(calls.at(-1)[0],'systemMaterial','no subsequent fill or border may erase the native effect');
 surface.applyNormalAttribute(instance);assert.equal(native.length,1);assert.equal(calls.at(-1)[1],native[0]);
});
test('an API 26 material failure cannot leave the expanded panel painted transparent',()=>{
 for(const options of [{constructorFails:true},{applyFails:true}]){
  const {DeviceOrbMaterial,calls,instance}=fixture(true,options);
  new DeviceOrbMaterial('adaptive',false).applyNormalAttribute(instance);
  assert.equal(calls.filter(([name])=>name==='backgroundColor').at(-1)[1],'#FFFFFF');
  assert.equal(calls.at(-1)[0],'shadow');
 }
});
test('the shared material keeps the 50 percent theme tint at every material strength',()=>{
 const {DeviceOrbMaterial,native,instance}=fixture(true);
 new DeviceOrbMaterial('strong',true).applyNormalAttribute(instance);
 assert.equal(native[0].materialColor,'#80000000');assert.equal(native[0].style,0);assert.equal(native[0].applyShadow,true);
 assert.equal(native[0].colorInvert,true);assert.equal(native[0].lightEffect,null);
 new DeviceOrbMaterial('adaptive',true).applyNormalAttribute(instance);
 assert.equal(native[1].materialColor,'#80000000');assert.equal(native[1].applyShadow,true);
});
test('fallback panel has one theme-specific shadow; native material owns its own shadow',()=>{
 for(const supported of [true,false]){
  const light=fixture(supported),dark=fixture(supported);
  new light.DeviceOrbMaterial('adaptive',false).applyNormalAttribute(light.instance);
  new dark.DeviceOrbMaterial('adaptive',true).applyNormalAttribute(dark.instance);
  const a=light.calls.filter(([key])=>key==='shadow'),b=dark.calls.filter(([key])=>key==='shadow');
  assert.equal(a.length,supported?0:1);assert.equal(b.length,supported?0:1);
  if(supported){assert.equal(light.calls.at(-1)[0],'systemMaterial');assert.equal(light.native[0].applyShadow,true);}
  else{assert.equal(a[0][1].color,'#2815274A');assert.equal(b[0][1].color,'#70000000');}
 }
});
test('6.1 fallback uses the same host geometry without touching any API 26 material constructor',()=>{
 const {DeviceOrbMaterial,native,calls,instance}=fixture(false);
 new DeviceOrbMaterial('adaptive',false).applyNormalAttribute(instance);
 assert.equal(native.length,0);assert.deepEqual(calls.slice(0,3),[['backgroundColor','#FFFFFF'],['borderWidth',.5],['borderColor','#E1E5EC']]);assert.equal(calls[3][0],'shadow');assert.equal(calls[3][1].radius,24);
});
test('off uses the 6.1 orb surface even on a capable device and a new enabled modifier restores native material',()=>{
 const f=fixture(true);new f.DeviceOrbMaterial('off',false).applyNormalAttribute(f.instance);
 assert.equal(f.native.length,0);assert.equal(f.calls.find(([key])=>key==='backgroundColor')[1],'#FFFFFF');
 new f.DeviceOrbMaterial('adaptive',false).applyNormalAttribute(f.instance);assert.equal(f.native.length,1);assert.equal(f.calls.at(-1)[0],'systemMaterial');
});

test('semantic device picker tints use exactly half-alpha white in light mode and black in dark mode',()=>{
 const {Palette}=loadEts('theme/Palette');
 assert.equal(Palette.forMode(false).devicePanelTint,'#80FFFFFF');
 assert.equal(Palette.forMode(true).devicePanelTint,'#80000000');
});
