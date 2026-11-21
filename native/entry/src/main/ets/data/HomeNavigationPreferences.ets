import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class HomeNavigationPreferences {
  static async load(context: common.UIAbilityContext): Promise<void> {
    let enabled = true;
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      enabled = await store.get('homeNavigationAutoHide', true) !== false;
    } catch (_) { /* Keep the existing navigation behavior. */ }
    AppStorage.setOrCreate('homeNavigationAutoHide', enabled);
  }

  static async save(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    await store.put('homeNavigationAutoHide', enabled);
    await store.flush();
    AppStorage.setOrCreate('homeNavigationAutoHide', enabled);
  }
}
