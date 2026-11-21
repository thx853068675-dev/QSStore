import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppearanceMode, AppearancePreferences } from './AppearancePreferences';
import { I18n } from './I18n';

export class AppBackground {
  theme: string = 'default';
  fit: string = 'cover';
  photo: string = '';
  uri: string = '';
  containerOpacity: number = 100;
  photoMaskOpacity: number = 0;
}

export class AppBackgroundPreferences {
  static normalizeOpacity(value: number, fallback: number = 100): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(100, Math.round(value))) : fallback;
  }

  static choices(): string[] { return ['default', 'fog', 'fern', 'violet']; }

  static themeLabel(theme: string): string {
    if (theme === 'fog') return I18n.t('雾蓝');
    if (theme === 'fern') return I18n.t('青岚');
    if (theme === 'violet') return I18n.t('暮紫');
    if (theme === 'photo') return I18n.t('自定义图片');
    return I18n.t('默认');
  }

  static fitLabel(fit: string): string {
    return I18n.t(fit === 'fill' ? '铺满' : fit === 'contain' ? '适应' : '裁剪');
  }

  static current(): AppBackground {
    return AppStorage.get<AppBackground>('appBackground') ?? new AppBackground();
  }

  static photoUri(context: common.UIAbilityContext, name: string): string {
    return /^app-background-[a-f0-9-]{36}\.jpg$/.test(name) ?
      fileUri.getUriFromPath(context.filesDir + '/' + name) : '';
  }

  static async load(context: common.UIAbilityContext): Promise<void> {
    const value = new AppBackground();
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      const theme = String(await store.get('appBackgroundTheme', 'default'));
      const fit = String(await store.get('appBackgroundFit', 'cover'));
      const name = String(await store.get('appBackgroundPhoto', ''));
      value.containerOpacity = AppBackgroundPreferences.normalizeOpacity(Number(await store.get('appContainerOpacity', 100)));
      value.photoMaskOpacity = AppBackgroundPreferences.normalizeOpacity(Number(await store.get('appBackgroundPhotoMask', 0)), 0);
      const uri = AppBackgroundPreferences.photoUri(context, name);
      if (uri && await fileIo.access(context.filesDir + '/' + name).catch(() => false)) {
        value.photo = name; value.uri = uri;
      }
      value.fit = fit === 'fill' || fit === 'contain' ? fit : 'cover';
      value.theme = AppBackgroundPreferences.choices().includes(theme) || theme === 'photo' && !!value.photo ?
        theme : 'default';
    } catch (_) { /* Restore the default if local preferences are inaccessible. */ }
    AppStorage.setOrCreate('appBackground', value);
  }

  static async save(context: common.UIAbilityContext, theme: string, fit: string, photo: string,
    appearance: AppearanceMode, opacity: number, photoMaskOpacity: number = 0): Promise<void> {
    const previous = AppBackgroundPreferences.current();
    const value = new AppBackground();
    value.containerOpacity = AppBackgroundPreferences.normalizeOpacity(opacity);
    value.photoMaskOpacity = AppBackgroundPreferences.normalizeOpacity(photoMaskOpacity, 0);
    value.theme = theme;
    value.fit = fit === 'fill' || fit === 'contain' ? fit : 'cover';
    value.photo = theme === 'photo' ? photo : previous.photo;
    value.uri = AppBackgroundPreferences.photoUri(context, value.photo);
    if (theme === 'photo' && (!value.uri || !await fileIo.access(context.filesDir + '/' + value.photo))) {
      throw new Error(I18n.t('无法读取所选图片'));
    }
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    await store.put('appBackgroundTheme', value.theme);
    await store.put('appBackgroundFit', value.fit);
    await store.put('appBackgroundPhoto', value.photo);
    await store.put('appContainerOpacity', value.containerOpacity);
    await store.put('appBackgroundPhotoMask', value.photoMaskOpacity);
    // Persist the appearance and background together before applying either one.
    await AppearancePreferences.save(context, appearance, store);
    AppStorage.setOrCreate('appBackground', value);
    if (previous.photo !== value.photo) await AppBackgroundPreferences.discard(context, previous.photo);
  }

  static async discard(context: common.UIAbilityContext, name: string): Promise<void> {
    if (name !== AppBackgroundPreferences.current().photo && AppBackgroundPreferences.photoUri(context, name)) {
      await fileIo.unlink(context.filesDir + '/' + name).catch(() => {});
    }
  }

  static async pickPhoto(context: common.UIAbilityContext): Promise<string> {
    const list = await new picker.DocumentViewPicker(context).select({
      fileSuffixFilters: [I18n.t('图片|.png,.jpg,.jpeg,.webp')], maxSelectNumber: 1
    });
    if (list.length === 0) return '';
    const input = await fileIo.open(list[0], fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined;
    let pixels: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    let name = '';
    try {
      if ((await fileIo.stat(input.fd)).size > 32 * 1024 * 1024) throw new Error(I18n.t('图片文件过大'));
      source = image.createImageSource(input.fd);
      const size = (await source.getImageInfo()).size;
      if (size.width < 1 || size.height < 1 || size.width * size.height > 60000000) {
        throw new Error(I18n.t('图片文件过大'));
      }
      const ratio = Math.min(1, 1440 / Math.max(size.width, size.height));
      pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(size.width * ratio)), height: Math.max(1, Math.round(size.height * ratio))
      } });
      packer = image.createImagePacker();
      const data = await packer.packToData(pixels, { format: 'image/jpeg', quality: 83, bufferSize: 2 * 1024 * 1024 });
      if (!data.byteLength || data.byteLength > 2 * 1024 * 1024) throw new Error(I18n.t('图片文件过大'));
      name = 'app-background-' + util.generateRandomUUID().toLowerCase() + '.jpg';
      const output = await fileIo.open(context.filesDir + '/' + name,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        if (await fileIo.write(output.fd, data) !== data.byteLength) throw new Error(I18n.t('无法保存图片'));
      } finally { await fileIo.close(output); }
      return name;
    } catch (error) {
      await AppBackgroundPreferences.discard(context, name);
      throw error as Error;
    } finally {
      try { await packer?.release(); } catch (_) {}
      try { await pixels?.release(); } catch (_) {}
      try { await source?.release(); } catch (_) {}
      await fileIo.close(input).catch(() => {});
    }
  }
}
