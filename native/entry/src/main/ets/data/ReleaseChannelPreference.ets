import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 每个商店应用独立记住版本频道，未选择过的应用默认使用正式版。 */
export class ReleaseChannelPreference {
  private static readonly STORE_NAME: string = 'release-channels';

  static async load(context: common.UIAbilityContext, appId: number): Promise<boolean> {
    if (!Number.isInteger(appId) || appId <= 0) return false;
    try {
      const store = await preferences.getPreferences(context, ReleaseChannelPreference.STORE_NAME);
      return await store.get('app-' + appId, false) === true;
    } catch (_) {
      return false;
    }
  }

  static async save(context: common.UIAbilityContext, appId: number, preview: boolean): Promise<void> {
    if (!Number.isInteger(appId) || appId <= 0) return;
    try {
      const store = await preferences.getPreferences(context, ReleaseChannelPreference.STORE_NAME);
      await store.put('app-' + appId, preview);
      await store.flush();
    } catch (_) {
      // 偏好写入失败不能把已经获取成功的版本列表当成网络失败。
      console.warn('Release channel preference could not be saved');
    }
  }
}
