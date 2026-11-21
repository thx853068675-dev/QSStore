import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';
import { HuaweiSite, parseHuaweiSite, suggestedHuaweiSite } from './HuaweiSite';

export class HuaweiLoginPreferences {
  private static readonly storeName: string = 'huawei-login';

  static async selected(context: common.UIAbilityContext): Promise<HuaweiSite | undefined> {
    const store = await preferences.getPreferences(context, HuaweiLoginPreferences.storeName);
    return parseHuaweiSite(String(await store.get('site', '')));
  }

  static async save(context: common.UIAbilityContext, site?: HuaweiSite): Promise<void> {
    const store = await preferences.getPreferences(context, HuaweiLoginPreferences.storeName);
    await store.put('site', site ?? '');
    await store.flush();
  }

  static suggested(): HuaweiSite {
    try { return suggestedHuaweiSite(i18n.System.getSystemRegion()); }
    catch (_) { return 'CN'; }
  }

  static async effective(context: common.UIAbilityContext): Promise<HuaweiSite> {
    try { return await HuaweiLoginPreferences.selected(context) ?? HuaweiLoginPreferences.suggested(); }
    catch (_) { return HuaweiLoginPreferences.suggested(); }
  }
}
