import { uiMaterial } from '@kit.ArkUI';
import { MaterialPreferences } from '../data/MaterialPreferences';
import { Palette } from '../theme/Palette';
import { StoreMaterial } from '../theme/StoreMaterial';

/** Native Toggle surface with the adaptive foreground kept inside its subtree. */
export class DeviceOrbMaterial implements AttributeModifier<ToggleAttribute> {
  private material:uiMaterial.ImmersiveMaterial|undefined;
  private fill:string;
  private borderColor:string;
  private borderWidth:number;
  private shadow:ShadowOptions;
  private mode:string;
  constructor(mode:string,dark:boolean){
    this.mode=mode;
    const colors=Palette.forMode(dark);
    this.fill=colors.surface;
    this.borderColor=colors.border;this.borderWidth=.5;
    this.shadow={radius:24,color:dark?'#70000000':'#2815274A',offsetX:0,offsetY:8};
    if(StoreMaterial.supported(mode)){
      try{
      this.material=new uiMaterial.ImmersiveMaterial({style:MaterialPreferences.style(mode),
        materialColor:colors.devicePanelTint,colorInvert:true,applyShadow:true,
        // The shared spring owns geometry; this decorative host must never
        // add a whole-panel touch light when a child list or input is touched.
        interactive:false,lightEffect:null});
      }catch(_){StoreMaterial.unavailable();}
    }
  }
  applyNormalAttribute(instance:ToggleAttribute):void{
    if(this.mode==='off')StoreMaterial.clearNative(instance);
    if(this.material&&StoreMaterial.supported(this.mode)){
      // Native material is last: later background/border setters would override it.
      try{
        instance.backgroundColor(Color.Transparent).borderWidth(0);
        instance.systemMaterial(this.material);return;
      }
      catch(_){StoreMaterial.unavailable();}
    }
    if(this.material)try{instance.systemMaterial(undefined);}catch(_){}
    // Shadow the rounded, painted control itself, never its rectangular layout container.
    instance.backgroundColor(this.fill).borderWidth(this.borderWidth).borderColor(this.borderColor).shadow(this.shadow);
  }
  applyPressedAttribute(instance:ToggleAttribute):void{this.applyNormalAttribute(instance);}
  applySelectedAttribute(instance:ToggleAttribute):void{this.applyNormalAttribute(instance);}
}
