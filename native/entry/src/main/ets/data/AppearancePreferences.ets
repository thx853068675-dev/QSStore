import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type AppearanceMode = 'system' | 'light' | 'dark';

export class AppearancePreferences {
  static normalize(value: string): AppearanceMode {
    return value === 'light' || value === 'dark' ? value : 'system';
  }

  private static apply(context: common.UIAbilityContext, mode: AppearanceMode): void {
    context.getApplicationContext().setColorMode(mode === 'system' ?
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET : mode === 'dark' ?
        ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    AppStorage.setOrCreate<string>('appearanceMode', mode);
    context.eventHub.emit('appearance-changed');
  }

  static async load(context: common.UIAbilityContext): Promise<void> {
    let mode: AppearanceMode = 'system';
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      mode = AppearancePreferences.normalize(String(await store.get('appearanceMode', 'system')));
    } catch (_) { /* A missing preferences file keeps the system appearance. */ }
    AppearancePreferences.apply(context, mode);
  }

  static async save(context: common.UIAbilityContext, mode: AppearanceMode): Promise<void> {
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    await store.put('appearanceMode', mode);
    await store.flush();
    AppearancePreferences.apply(context, mode);
  }
}
