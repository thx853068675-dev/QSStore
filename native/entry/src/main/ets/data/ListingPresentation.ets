import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { I18n } from './I18n';

export class ListingPresentation {
  display_name?: string;
  description?: string;
  screenshots?: string[];
}

@Observed
export class ListingPresentationDraft {
  name: string = '';
  description: string = '';
  screenshots: string[] = [];
  processing: boolean = false;
  private initialName: string = '';
  private initialDescription: string = '';
  private initialScreenshots: string[] = [];

  static create(name: string, description: string, screenshots: string[] = []): ListingPresentationDraft {
    const draft = new ListingPresentationDraft();
    draft.name = draft.initialName = name;
    draft.description = draft.initialDescription = description;
    draft.screenshots = draft.initialScreenshots = screenshots.slice();
    return draft;
  }

  edits(): ListingPresentation | undefined {
    const output = new ListingPresentation();
    if (this.name.trim() !== this.initialName.trim()) output.display_name = this.name.trim();
    if (this.description.trim() !== this.initialDescription.trim()) output.description = this.description.trim();
    if (this.screenshots.join(',') !== this.initialScreenshots.join(',')) output.screenshots = this.screenshots;
    return output.display_name !== undefined || output.description !== undefined || output.screenshots !== undefined ?
      output : undefined;
  }
}

export class ListingScreenshot {
  static readonly LIMIT: number = 6;

  static key(source: string): string {
    if (source.length < 40) return source;
    const step = Math.max(1, Math.floor(source.length / 128));
    let hash = 0;
    for (let offset = 12; offset < source.length; offset += step) {
      hash = Math.imul(hash, 31) + source.charCodeAt(offset) | 0;
    }
    return source.length + ':' + hash;
  }

  static async pick(context: common.UIAbilityContext, count: number): Promise<string[]> {
    const selected = await new picker.DocumentViewPicker(context).select({
      fileSuffixFilters: [I18n.t('图片|.png,.jpg,.jpeg,.webp')], maxSelectNumber: count
    });
    const screenshots: string[] = [];
    for (const uri of selected.slice(0, count)) screenshots.push(await ListingScreenshot.encode(uri));
    return screenshots;
  }

  private static async encode(uri: string): Promise<string> {
    const document = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined;
    let pixels: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    try {
      const stat = await fileIo.stat(document.fd);
      if (stat.size > 32 * 1024 * 1024) throw new Error(I18n.t('界面截图无效或过大，请重新选择'));
      source = image.createImageSource(document.fd);
      const info = await source.getImageInfo();
      const width = info.size.width, height = info.size.height;
      if (width < 1 || height < 1 || width * height > 40000000) {
        throw new Error(I18n.t('界面截图无效或过大，请重新选择'));
      }
      const ratio = Math.min(1, 1440 / Math.max(width, height));
      pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(width * ratio)), height: Math.max(1, Math.round(height * ratio))
      } });
      packer = image.createImagePacker();
      for (const quality of [85, 76, 65, 54]) {
        const data = await packer.packToData(pixels, { format: 'image/jpeg', quality, bufferSize: 2 * 1024 * 1024 });
        if (data.byteLength <= 160 * 1024) {
          return new util.Base64Helper().encodeToStringSync(new Uint8Array(data));
        }
      }
      await pixels.scale(0.75, 0.75);
      const reduced = await packer.packToData(pixels, { format: 'image/jpeg', quality: 68, bufferSize: 1024 * 1024 });
      if (reduced.byteLength <= 160 * 1024) {
        return new util.Base64Helper().encodeToStringSync(new Uint8Array(reduced));
      }
      throw new Error(I18n.t('界面截图无效或过大，请重新选择'));
    } finally {
      await packer?.release().catch(() => {});
      await pixels?.release().catch(() => {});
      await source?.release().catch(() => {});
      await fileIo.close(document).catch(() => {});
    }
  }
}
