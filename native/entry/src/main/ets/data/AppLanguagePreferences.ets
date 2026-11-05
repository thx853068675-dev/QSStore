import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';
import { I18n } from './I18n';

export type AppLanguage = 'zh' | 'en';

/**
 * 界面语言的唯一持久化入口。
 *
 * 语言与外观、光感一样保存在 qingqi-settings，但读取时机必须早于首页加载：
 * 首页、详情页和各类任务文案在 build 时直接读取 AppStorage['appLanguage']，
 * 晚于 loadContent 读取会让首帧闪一下中文。
 */
export class AppLanguagePreferences {
  static normalize(value: string): AppLanguage {
    return value === 'en' ? 'en' : 'zh';
  }

  /** 首次启动跟随系统语言；系统返回异常时保持中文。 */
  static systemDefault(): AppLanguage {
    try {
      return (i18n.System.getSystemLanguage() ?? '').toLowerCase().startsWith('en') ? 'en' : 'zh';
    } catch (_) {
      return 'zh';
    }
  }

  static current(): AppLanguage {
    return AppLanguagePreferences.normalize(I18n.language());
  }

  static async load(context: common.UIAbilityContext): Promise<void> {
    let language = AppLanguagePreferences.systemDefault();
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      language = AppLanguagePreferences.normalize(String(await store.get('appLanguage', language)));
    } catch (_) { /* A missing preferences file keeps the system default. */ }
    I18n.setLanguage(language);
    AppStorage.setOrCreate<string>('appLanguage', language);
  }

  static async save(context: common.UIAbilityContext, language: AppLanguage): Promise<void> {
    const normalized = AppLanguagePreferences.normalize(language);
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    await store.put('appLanguage', normalized);
    await store.flush();
    I18n.setLanguage(normalized);
    AppStorage.setOrCreate<string>('appLanguage', normalized);
  }
}
