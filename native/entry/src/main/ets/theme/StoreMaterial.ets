import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { MaterialPreferences } from '../data/MaterialPreferences';
import { Palette } from './Palette';
import { I18n } from '../data/I18n';

/** Shared native material policy. Keep system foreground resources intact for native inversion. */
export class StoreMaterial {
  private static immersiveSupported: boolean | undefined;
  private static dockMaterials: Map<string, uiMaterial.ImmersiveMaterial> = new Map();
  static supported(mode: string = 'adaptive'): boolean {
    // Preference is not capability: turning it back on must reuse the device result.
    if (mode === 'off') return false;
    if (StoreMaterial.immersiveSupported === undefined) {
      try {
        StoreMaterial.immersiveSupported = deviceInfo.sdkApiVersion >= 26 &&
          uiMaterial.isImmersiveMaterialSupported() === true && MaterialPreferences.supported();
        if(StoreMaterial.immersiveSupported){
          // Some API 26 builds expose the API while the material service cannot
          // initialize. Check once before any control switches to transparent.
          new uiMaterial.ImmersiveMaterial({style:MaterialPreferences.style('adaptive'),
            materialColor:'#00000000',colorInvert:true,applyShadow:false,interactive:false});
        }
      } catch (_) { StoreMaterial.immersiveSupported = false; }
    }
    return StoreMaterial.immersiveSupported;
  }
  static unavailable():void{StoreMaterial.immersiveSupported=false;}
  static clearNative(instance:CommonAttribute):void{
    if(deviceInfo.sdkApiVersion>=26)try{instance.systemMaterial(undefined);}catch(_){}
  }
  static fallbackFill(dark:boolean):string{return '#E6'+Palette.forMode(dark).surface.substring(1);}
  static glass(mode: string, dark: boolean, shadow: boolean = true,
    lightColor: string = Palette.forMode(dark).surface): uiMaterial.ImmersiveMaterial {
    if (mode === 'off') throw new Error(I18n.t('沉浸光感已关闭'));
    return new uiMaterial.ImmersiveMaterial({ style: MaterialPreferences.style(mode),
      materialColor: '#00000000', colorInvert: true, applyShadow: shadow, interactive: true,
      lightEffect: { color: MaterialPreferences.lightColor(mode, lightColor) } });
  }
  /** Floating navigation and its adjacent action share identical native material options. */
  static dock(mode: string, dark: boolean): uiMaterial.ImmersiveMaterial {
    const key = mode + ':' + dark;
    const existing = StoreMaterial.dockMaterials.get(key);
    if (existing) return existing;
    const material = StoreMaterial.glass(mode, dark, true);
    StoreMaterial.dockMaterials.set(key, material);
    return material;
  }
  static tinted(mode: string, tint: string, strength: number = 1,
    shadow: boolean = true): uiMaterial.ImmersiveMaterial {
    if (mode === 'off') throw new Error(I18n.t('沉浸光感已关闭'));
    const opacity = Number.isFinite(strength) ? Math.min(1, Math.max(0, strength)) : 1;
    const alpha = Math.round(153 * opacity).toString(16).padStart(2, '0');
    return new uiMaterial.ImmersiveMaterial({ style: MaterialPreferences.style(mode),
      materialColor: '#' + alpha + tint.substring(1), colorInvert: false,
      applyShadow: shadow, interactive: true,
      lightEffect: { color: MaterialPreferences.lightColor(mode, tint) } });
  }
  static foreground(dark: boolean, secondary: boolean = false, mode: string = 'adaptive'): ResourceColor {
    if (StoreMaterial.supported(mode)) return secondary ? $r('sys.color.font_secondary') : $r('sys.color.font_primary');
    return secondary ? Palette.forMode(dark).textSecondary : Palette.forMode(dark).text;
  }
  static icon(dark: boolean, mode: string = 'adaptive'): ResourceColor {
    return StoreMaterial.supported(mode) ? $r('sys.color.icon_primary') : Palette.forMode(dark).text;
  }
  static navigationColor(selected: boolean, icon: boolean = false): ResourceColor {
    if (icon) return selected ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_primary');
    return selected ? $r('sys.color.font_emphasize') : $r('sys.color.font_primary');
  }
  static blurStyle(mode: string): BlurStyle {
    const value = MaterialPreferences.normalize(mode);
    return value === 'strong' ? BlurStyle.COMPONENT_ULTRA_THIN : value === 'weak' ?
      BlurStyle.COMPONENT_REGULAR : BlurStyle.COMPONENT_THIN;
  }
}
