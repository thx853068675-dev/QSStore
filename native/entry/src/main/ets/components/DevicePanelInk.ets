import { Palette } from '../theme/Palette';
import { StoreMaterial } from '../theme/StoreMaterial';

/** SymbolGlyph ignores foregroundColor(INVERT); use the system compositor, without sampling or timers. */
export class DevicePanelSymbol implements AttributeModifier<SymbolGlyphAttribute>{
  private dark:boolean;
  private mode:string;
  constructor(dark:boolean,mode:string='adaptive'){this.dark=dark;this.mode=mode;}
  applyNormalAttribute(instance:SymbolGlyphAttribute):void{
    if(StoreMaterial.supported(this.mode))instance.fontColor([Color.White]).blendMode(BlendMode.DIFFERENCE,BlendApplyType.FAST);
    else instance.fontColor([Palette.forMode(this.dark).text]).blendMode(BlendMode.SRC_OVER,BlendApplyType.FAST);
  }
}

/** Native render strategies adapt to the pixels behind the glass, independently of the app theme. */
export class DevicePanelInk {
  static contrast(dark:boolean,secondary:boolean=false,mode:string='adaptive'):ResourceColor|ColoringStrategy{
    return StoreMaterial.supported(mode)?ColoringStrategy.INVERT:DevicePanelInk.foreground(dark,secondary,mode);
  }
  private static lightSymbol:DevicePanelSymbol=new DevicePanelSymbol(false);
  private static darkSymbol:DevicePanelSymbol=new DevicePanelSymbol(true);
  private static lightFallbackSymbol:DevicePanelSymbol=new DevicePanelSymbol(false,'off');
  private static darkFallbackSymbol:DevicePanelSymbol=new DevicePanelSymbol(true,'off');
  static symbol(dark:boolean,mode:string='adaptive'):DevicePanelSymbol{
    return mode==='off'?(dark?DevicePanelInk.darkFallbackSymbol:DevicePanelInk.lightFallbackSymbol):dark?DevicePanelInk.darkSymbol:DevicePanelInk.lightSymbol;
  }
  static foreground(dark:boolean,secondary:boolean=false,mode:string='adaptive'):ResourceColor{
    if(StoreMaterial.supported(mode))return secondary?$r('sys.color.ohos_id_color_text_secondary'):$r('sys.color.ohos_id_color_text_primary');
    return secondary?Palette.forMode(dark).textSecondary:Palette.forMode(dark).text;
  }
  static icon(dark:boolean,mode:string='adaptive'):ResourceColor{return StoreMaterial.supported(mode)?$r('sys.color.ohos_id_color_text_primary'):Palette.forMode(dark).text;}
  static action(dark:boolean,connected:boolean=false,mode:string='adaptive'):ResourceColor{
    const colors=Palette.forMode(dark);
    return StoreMaterial.supported(mode)?$r('sys.color.ohos_id_color_emphasize'):connected?colors.success:colors.accent;
  }
}
