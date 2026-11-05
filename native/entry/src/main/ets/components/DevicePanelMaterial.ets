import { uiMaterial } from '@kit.ArkUI';
import { Palette } from '../theme/Palette';
import { StoreMaterial } from '../theme/StoreMaterial';

/** Decorative material stays in the capsule's overlay, never in a competing popup. */
export class DevicePanelMaterial implements AttributeModifier<CommonAttribute> {
  private material:uiMaterial.ImmersiveMaterial|undefined;
  private fill:ResourceColor;
  private blur:BlurStyle;
  private dark:boolean;
  private mode:string;
  constructor(mode:string,dark:boolean,selected:boolean){
    this.mode=mode;this.dark=dark;this.fill=selected?Palette.forMode(dark).accent:StoreMaterial.fallbackFill(dark);
    this.blur=StoreMaterial.blurStyle(mode);
    if(StoreMaterial.supported(mode)){
      try{this.material=selected?StoreMaterial.tinted(mode,Palette.forMode(dark).accent,1,false):StoreMaterial.glass(mode,dark,false);}
      catch(_){StoreMaterial.unavailable();}
    }
  }
  applyNormalAttribute(instance:CommonAttribute):void{
    if(this.mode==='off')StoreMaterial.clearNative(instance);
    if(this.material&&StoreMaterial.supported(this.mode)){
      try{instance.backgroundColor(Color.Transparent).borderWidth(0).systemMaterial(this.material);return;}
      catch(_){StoreMaterial.unavailable();}
    }
    if(this.material)try{instance.systemMaterial(undefined);}catch(_){}
    instance.backgroundBlurStyle(this.blur,{colorMode:this.dark?ThemeColorMode.DARK:ThemeColorMode.LIGHT})
      .backgroundColor(this.fill).borderWidth(.5).borderColor(Palette.forMode(this.dark).border);
  }
}
