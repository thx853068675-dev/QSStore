const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(__dirname+'/../entry/src/main/ets/components/RefreshFailureNotice.ets','utf8').split('@Component')[0].replace(/^import .*;\n/gm,'');
function fixture(supported,mode,dark,fail=false){
 const calls=[],materials=[];let available=supported;
 const box={exports:{},Color:{Transparent:'transparent'},ThemeColorMode:{DARK:'dark',LIGHT:'light'},
  uiMaterial:{ImmersiveMaterial:class{constructor(options){materials.push(options);Object.assign(this,options);}}},
  MaterialPreferences:{style:value=>value,lightColor:()=> 'light'},Palette:{forMode:()=>({surface:dark?'#161C28':'#FFFFFF',border:'border'})},
  StoreMaterial:{supported:value=>available&&value!=='off',unavailable:()=>{available=false;},clearNative:instance=>instance.systemMaterial(undefined),blurStyle:()=>1,fallbackFill:()=>dark?'dark-fill':'light-fill'}};
 vm.runInNewContext(ts.transpileModule(source+'\nexports.Material=RefreshNoticeMaterial;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const instance={};for(const key of ['backgroundColor','borderWidth','systemMaterial','backgroundBlurStyle','borderColor'])instance[key]=(...args)=>{calls.push([key,...args]);if(key==='systemMaterial'&&args[0]&&fail)throw Error('unsupported service');return instance;};
 new box.exports.Material(mode,dark).applyNormalAttribute(instance);return{calls,materials};
}
test('full-width refresh notice uses native noninteractive light with the selected intensity',()=>{
 for(const mode of ['weak','adaptive','strong']){
  const f=fixture(true,mode,false);assert.equal(f.materials[0].style,mode);assert.equal(f.materials[0].colorInvert,true);assert.equal(f.materials[0].interactive,false);assert.equal(f.materials[0].materialColor,'#00000000');assert.equal(f.calls.at(-1)[0],'systemMaterial');
 }
});
test('unsupported, explicitly disabled and failed native renderers always paint readable light/dark glass',()=>{
 for(const dark of [false,true])for(const[enabled,mode,fail]of [[false,'adaptive',false],[true,'off',false],[true,'strong',true]]){
  const f=fixture(enabled,mode,dark,fail);assert.equal(f.calls.filter(([key])=>key==='backgroundColor').at(-1)[1],dark?'dark-fill':'light-fill');
  assert(f.calls.some(([key,value])=>key==='systemMaterial'&&value===undefined));assert.equal(f.calls.find(([key])=>key==='backgroundBlurStyle')[2].colorMode,dark?'dark':'light');
 }
});
