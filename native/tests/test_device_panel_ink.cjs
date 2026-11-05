const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {Palette}=loadEts('theme/Palette');
function fixture(supported){
 return loadEts('components/DevicePanelInk',{'../theme/Palette':{Palette},'../theme/StoreMaterial':{StoreMaterial:{supported:mode=>supported&&mode!=='off',
  foreground:(dark,secondary)=>supported?{id:secondary?'secondary':'primary'}:secondary?Palette.forMode(dark).textSecondary:Palette.forMode(dark).text,
  icon:dark=>supported?{id:'icon'}:Palette.forMode(dark).text}}},{$r:id=>({id})}).DevicePanelInk;
}
function luminance(hex){const v=hex.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4);return .2126*v[0]+.7152*v[1]+.0722*v[2];}
function contrast(a,b){const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
test('unsupported dark overlays retain readable foreground and action colors',()=>{
 const Ink=fixture(false),colors=Palette.forMode(true);
  for(const secondary of [true,false])assert(contrast(Ink.foreground(true,secondary),colors.surface)>4.5);
  assert(contrast(Ink.icon(true),colors.surface)>4.5);
  assert(contrast(Ink.action(true),colors.surface)>4.5);
});
test('both native themes keep semantic resource identity for system inversion',()=>{
 const native=fixture(true);for(const dark of [false,true]){
  assert.equal(native.foreground(dark).id,'sys.color.ohos_id_color_text_primary');assert.equal(native.foreground(dark,true).id,'sys.color.ohos_id_color_text_secondary');
  assert.equal(native.icon(dark).id,'sys.color.ohos_id_color_text_primary');assert.equal(native.action(dark).id,'sys.color.ohos_id_color_emphasize');
 }
 const fallback=fixture(false),colors=Palette.forMode(false);assert.equal(fallback.foreground(false),colors.text);assert.equal(fallback.foreground(false,true),colors.textSecondary);
 assert(contrast(fallback.foreground(false,true),colors.surface)>4.5);
});
test('off selects readable theme colors instead of native inversion on capable devices',()=>{
 const Ink=fixture(true);
 for(const dark of [false,true]){
  const colors=Palette.forMode(dark);assert.equal(Ink.foreground(dark,false,'off'),colors.text);
  assert.equal(Ink.foreground(dark,true,'off'),colors.textSecondary);assert.equal(Ink.icon(dark,'off'),colors.text);
  assert.equal(Ink.action(dark,false,'off'),colors.accent);
 }
});
