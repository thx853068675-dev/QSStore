import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hdsMaterial } from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { I18n } from './I18n';

export type MaterialMode = 'adaptive' | 'strong' | 'balanced' | 'weak' | 'off';

/** User preference maps to the official HDS grades, without overriding device capability. */
export class MaterialPreferences {
  private static immersiveSupported: boolean | undefined;
  static normalize(value: string): MaterialMode {
    return value === 'strong' || value === 'balanced' || value === 'weak' || value === 'off' ? value : 'adaptive';
  }
  static label(value: string): string {
    return value === 'off' ? I18n.t('关闭') : value === 'strong' ? I18n.t('强') : value === 'balanced' ? I18n.t('均衡') : value === 'weak' ? I18n.t('弱') : I18n.t('自动');
  }
  /** Component material has no writable device level; vary thickness and touch light instead. */
  static style(value: string): uiMaterial.ImmersiveStyle {
    const mode = MaterialPreferences.normalize(value);
    return mode === 'strong' ? uiMaterial.ImmersiveStyle.ULTRA_THIN : mode === 'weak' ?
      uiMaterial.ImmersiveStyle.REGULAR : uiMaterial.ImmersiveStyle.THIN;
  }
  static lightColor(value: string, color: string): string {
    const mode = MaterialPreferences.normalize(value);
    if (mode !== 'balanced' && mode !== 'weak') return color;
    const alpha = Math.round(255 * (mode === 'balanced' ? 0.7 : 0.35)).toString(16).padStart(2, '0');
    return '#' + alpha + color.substring(1);
  }
  static level(value: string): hdsMaterial.MaterialLevel {
    if (value === 'off') return hdsMaterial.MaterialLevel.SMOOTH;
    if (value === 'adaptive') return hdsMaterial.MaterialLevel.ADAPTIVE;
    if (!MaterialPreferences.supported()) return hdsMaterial.MaterialLevel.SMOOTH;
    return value === 'strong' ? hdsMaterial.MaterialLevel.EXQUISITE : value === 'balanced' ?
      hdsMaterial.MaterialLevel.GENTLE : hdsMaterial.MaterialLevel.SMOOTH;
  }
  static supported(): boolean {
    if (MaterialPreferences.immersiveSupported === undefined) {
      try { MaterialPreferences.immersiveSupported = hdsMaterial.getSystemMaterialTypes()
        .includes(hdsMaterial.MaterialType.IMMERSIVE); }
      catch (_) { MaterialPreferences.immersiveSupported = false; }
    }
    return MaterialPreferences.immersiveSupported;
  }
  static type(value: string = 'adaptive'): hdsMaterial.MaterialType {
    if (value === 'off') return hdsMaterial.MaterialType.NONE;
    return MaterialPreferences.supported()?hdsMaterial.MaterialType.IMMERSIVE:hdsMaterial.MaterialType.ADAPTIVE;
  }
  static async load(context: common.UIAbilityContext): Promise<void> {
    let mode: MaterialMode = 'adaptive';
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      mode = MaterialPreferences.normalize(String(await store.get('materialMode', 'adaptive')));
    } catch (_) {}
    AppStorage.setOrCreate<string>('materialMode', mode);
  }
  static async save(context: common.UIAbilityContext, value: MaterialMode): Promise<void> {
    const mode = MaterialPreferences.normalize(value);
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    await store.put('materialMode', mode);
    await store.flush();
    AppStorage.setOrCreate<string>('materialMode', mode);
  }
}
