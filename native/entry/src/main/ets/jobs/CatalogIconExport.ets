import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { CatalogApp } from '../data/CatalogApp';
import { StoreClient } from '../data/StoreClient';
import { I18n } from '../data/I18n';

/** Save the catalog source bytes, never the resized/rounded presentation PixelMap. */
export class CatalogIconExport {
  private static suffix(bytes: ArrayBuffer): string {
    const data = new Uint8Array(bytes);
    if (data.length > 1024 * 1024) throw new Error(I18n.t('图标过大'));
    if (data.length >= 8 && data[0] === 137 && data[1] === 80 && data[2] === 78 && data[3] === 71 &&
      data[4] === 13 && data[5] === 10 && data[6] === 26 && data[7] === 10) return 'png';
    if (data.length >= 3 && data[0] === 255 && data[1] === 216 && data[2] === 255) return 'jpg';
    if (data.length >= 12 && data[0] === 82 && data[1] === 73 && data[2] === 70 && data[3] === 70 &&
      data[8] === 87 && data[9] === 69 && data[10] === 66 && data[11] === 80) return 'webp';
    throw new Error(I18n.t('暂时无法读取图标原图'));
  }

  static async save(context: common.UIAbilityContext, app: CatalogApp, title: string,
    current: () => boolean): Promise<boolean> {
    const bytes = await new StoreClient(context).originalIconBytes(app);
    if (!current()) return false;
    if (!bytes) throw new Error(I18n.t('暂时无法读取图标原图'));
    const suffix = CatalogIconExport.suffix(bytes);
    const name = title.replace(/[\u0000-\u001f\u007f/\\:*?"<>|]/g, '_').trim().slice(0, 80)
      .replace(/[. ]+$/g, '') || I18n.t('应用');
    const paths = await new picker.DocumentViewPicker(context).save({ newFileNames: [name + '_icon.' + suffix] });
    if (!paths.length || !current()) return false;
    if (paths.length !== 1) throw new Error(I18n.t('保存位置无效'));
    const output = await fileIo.open(paths[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      let at = 0;
      while (at < bytes.byteLength) {
        const count = await fileIo.write(output.fd, bytes.slice(at));
        if (count <= 0 || count > bytes.byteLength - at) throw new Error(I18n.t('图标保存不完整，请重试'));
        at += count;
      }
      await fileIo.fsync(output.fd);
      if ((await fileIo.stat(output.fd)).size !== bytes.byteLength) throw new Error(I18n.t('图标保存不完整，请重试'));
      return true;
    } finally {
      await fileIo.close(output);
    }
  }
}
