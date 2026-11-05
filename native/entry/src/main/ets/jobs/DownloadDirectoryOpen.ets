import { common } from '@kit.AbilityKit';
import { DownloadLibrary } from './DownloadLibrary';
import { I18n } from '../data/I18n';

export class DownloadDirectoryOpen {
  /** Pass the system-issued public directory URI to Huawei's file manager. */
  static async open(context: common.UIAbilityContext, isCurrent: () => boolean): Promise<boolean> {
    if (!isCurrent()) return false;
    const location = await DownloadLibrary.getLocation(context);
    if (!isCurrent()) return false;
    if (!location.uri) throw new Error(I18n.t('下载目录不可用'));
    await context.startAbility({
      bundleName: 'com.huawei.hmos.filemanager',
      abilityName: 'MainAbility',
      parameters: { fileUri: location.uri }
    });
    return true;
  }
}
