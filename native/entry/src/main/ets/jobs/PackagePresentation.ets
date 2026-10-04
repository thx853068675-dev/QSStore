import { readArchiveFile, readModuleJson, readHapIcon } from 'libhap_core.so';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { ResourceIndex } from './ResourceIndex';

export class PackagePresentation {
  static manifest(path: string): Record<string, Object> { return JSON.parse(readModuleJson(path)) as Record<string, Object>; }
  static label(path: string): string {
    try {
      const app = PackagePresentation.manifest(path)['app'] as Record<string, Object>;
      const label = String(app['label'] ?? '');
      if (label && !label.startsWith('$')) return label;
      return new ResourceIndex(readArchiveFile(path, 'resources.index')).value(Number(app['labelId'] ?? 0));
    } catch (_) { return ''; }
  }
  private static resolve(path: string, value: string): string {
    const numeric=value.replace(/^\$(media|string):/, '');
    if (/^\d+$/.test(numeric)) return new ResourceIndex(readArchiveFile(path, 'resources.index')).value(Number(numeric));
    return value;
  }
  static async icon(path: string): Promise<ArrayBuffer | undefined> {
    try {
      const root = PackagePresentation.manifest(path), app = root['app'] as Record<string, Object>, module = root['module'] as Record<string, Object>;
      const abilities = (module['abilities'] ?? []) as Record<string, Object>[];
      const main = abilities.find((ability: Record<string, Object>) => ability['name'] === module['mainElement']);
      const reference = PackagePresentation.resolve(path, String(main?.['iconId'] || app['iconId'] || main?.['icon'] || app['icon'] || ''));
      const ref = reference.replace(/^[^/]+\/(resources\/)/, '$1');
      const bytes = ref.startsWith('resources/') ? readArchiveFile(path, ref) : readHapIcon(path, ref);
      if (!bytes.length) return undefined;
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      if (!reference.toLowerCase().endsWith('.json')) return buffer;
      const layers = (JSON.parse(util.TextDecoder.create('utf-8').decodeToString(bytes)) as Record<string, Object>)['layered-image'] as Record<string, Object>;
      const background = await PackagePresentation.layer(path, String(layers['background'] ?? ''));
      let foreground: image.PixelMap | undefined;
      try {
        foreground = await PackagePresentation.layer(path, String(layers['foreground'] ?? ''));
        const fgInfo=await foreground.getImageInfo();
        const bgInfo = await background.getImageInfo();
        if (bgInfo.size.width > 1024 || bgInfo.size.height > 1024) return undefined;
        await foreground.scale(bgInfo.size.width / (await foreground.getImageInfo()).size.width, bgInfo.size.height / (await foreground.getImageInfo()).size.height);
        const bg = new Uint8Array(bgInfo.size.width * bgInfo.size.height * 4), fg = new Uint8Array(bg.length);
        await background.readPixelsToBuffer(bg.buffer); await foreground.readPixelsToBuffer(fg.buffer);
        for (let n = 0; n < bg.length; n += 4) {
          const fa = fg[n + 3] / 255, ba = bg[n + 3] / 255, alpha = fa + ba * (1 - fa);
          for (let c = 0; c < 3; c++) bg[n + c] = alpha > 0 ? Math.round((fg[n + c] * (fgInfo.alphaType===image.AlphaType.PREMUL ? 1 : fa) + bg[n + c] * (bgInfo.alphaType===image.AlphaType.PREMUL ? 1 : ba) * (1 - fa)) / alpha) : 0;
          bg[n + 3] = Math.round(alpha * 255);
        }
        const pixels = await image.createPixelMap(bg.buffer, { size: bgInfo.size, pixelFormat: image.PixelMapFormat.RGBA_8888, srcPixelFormat: image.PixelMapFormat.RGBA_8888, alphaType: image.AlphaType.UNPREMUL });
        const packer = image.createImagePacker();
        try { return await packer.packing(pixels, { format: 'image/png', quality: 100 }); }
        finally { packer.release(); pixels.release(); }
      } finally { background.release(); foreground?.release(); }
    } catch (_) { return undefined; }
  }
  private static async layer(path: string, reference: string): Promise<image.PixelMap> {
    const ref = PackagePresentation.resolve(path, reference).replace(/^[^/]+\/(resources\/)/, '$1');
    const bytes = ref.startsWith('resources/') ? readArchiveFile(path, ref) : readHapIcon(path, ref);
    const source = image.createImageSource(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
    try { const info=await source.getImageInfo();
      if(info.size.width<=0 || info.size.height<=0 || info.size.width*info.size.height>16777216)throw new Error('图标尺寸过大');
      return await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888, desiredSize:{width:512,height:512} }); }
    finally { source.release(); }
  }
}
