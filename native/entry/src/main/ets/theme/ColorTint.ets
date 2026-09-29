import { image } from '@kit.ImageKit';
import { Palette } from './Palette';

/**
 * 从应用图标取主色调，用做详情页头部的底色。
 *
 * 取色的目的是让卡片带一点这个应用自己的颜色，所以要求是「稳」而不是「准」：
 *   · 跳过接近纯白/纯黑的像素 —— 大多数图标都是白底加一个彩色图形，白底如果
 *     参与统计，每个图标都会被算成白色，等于没有取色
 *   · 按色相分桶而不是按 RGB 精确值统计，抗压缩噪点
 *   · 最终颜色按主题重新定亮度与饱和度，保证叠在上面的文字仍然可读
 */
export class ColorTint {
  /** 采样步长：图标很小，隔点取样足够，还能省掉大半计算。 */
  private static readonly STRIDE: number = 2;

  /**
   * 取主色调，返回 0xAARRGGBB；取不到返回 undefined，调用方回退到默认底色。
   */
  static async dominantColor(pixels: image.PixelMap | null): Promise<number | undefined> {
    if (pixels === null) return undefined;
    try {
      const info = await pixels.getImageInfo();
      const width = info.size.width;
      const height = info.size.height;
      if (width <= 0 || height <= 0) return undefined;
      const buffer = new ArrayBuffer(width * height * 4);
      await pixels.readPixelsToBuffer(buffer);
      return ColorTint.dominantFromRgba(new Uint8Array(buffer));
    } catch (_) {
      return undefined;
    }
  }

  /**
   * RGBA 缓冲里出现最多的「有彩色」。权重按饱和度累加：越鲜艳的像素越能代表
   * 这个图标的颜色，浅灰的边角不会把结果拉平。
   */
  private static dominantFromRgba(rgba: Uint8Array): number | undefined {
    const bins = new Map<number, number>();
    const stride = ColorTint.STRIDE;
    for (let y = 0; y < rgba.length / 4; y += stride) {
      const offset = y * 4;
      if (offset + 3 >= rgba.length) break;
      const alpha = rgba[offset + 3];
      if (alpha < 200) continue;
      const r = rgba[offset];
      const g = rgba[offset + 1];
      const b = rgba[offset + 2];
      const max = Math.max(r, Math.max(g, b));
      const min = Math.min(r, Math.min(g, b));
      const chroma = max - min;
      // 近黑/近白/近灰都不代表图标的主色。阈值放到 30：否则大片淡色底纹
      // 会把结果拉成接近中性色，取色就白做了。
      if (chroma < 30 || max < 40 || min > 232) continue;
      // 每 10 度一个色相桶，减少压缩噪点造成的碎片
      const hue = ColorTint.hue(r, g, b);
      const bin = Math.floor(hue / 10);
      bins.set(bin, (bins.get(bin) ?? 0) + chroma);
    }
    if (bins.size === 0) return undefined;
    let bestBin = -1;
    let bestWeight = 0;
    bins.forEach((weight: number, bin: number) => {
      if (weight > bestWeight) {
        bestWeight = weight;
        bestBin = bin;
      }
    });
    if (bestBin < 0) return undefined;
    // 桶中心作为代表色相
    return ColorTint.fromHue(bestBin * 10 + 5);
  }

  /** 色相角 0-360。 */
  private static hue(r: number, g: number, b: number): number {
    const max = Math.max(r, Math.max(g, b));
    const min = Math.min(r, Math.min(g, b));
    const chroma = max - min;
    if (chroma === 0) return 0;
    let hue = 0;
    if (max === r) hue = ((g - b) / chroma) % 6;
    else if (max === g) hue = (b - r) / chroma + 2;
    else hue = (r - g) / chroma + 4;
    hue *= 60;
    return hue < 0 ? hue + 360 : hue;
  }

  /**
   * 由一个色相算出适合做卡片底色的不透明色。
   *
   * 这两个数值是照着实机图标调出来的：彩色完全按图标走会出现两种失败 ——
   * 要么淡到和默认底色分不出来（饱和度太低），要么深到压住上面的深色文字
   * （亮度太低）。浅色取「高亮 + 中高饱和」，深色取「低亮 + 中饱和」。
   */
  private static fromHue(hue: number): number {
    return Palette.dark ?
      ColorTint.hsl(hue, 0.45, 0.20) :
      ColorTint.hsl(hue, 0.78, 0.92);
  }

  /** HSL → 0xAARRGGBB。 */
  private static hsl(hue: number, saturation: number, lightness: number): number {
    const c = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
    const m = lightness - c / 2;
    let r = 0;
    let g = 0;
    let b = 0;
    if (hue < 60) { r = c; g = x; }
    else if (hue < 120) { r = x; g = c; }
    else if (hue < 180) { g = c; b = x; }
    else if (hue < 240) { g = x; b = c; }
    else if (hue < 300) { r = x; b = c; }
    else { r = c; b = x; }
    const to255 = (value: number): number =>
      Math.max(0, Math.min(255, Math.round((value + m) * 255)));
    return 0xFF000000 + (to255(r) << 16) + (to255(g) << 8) + to255(b);
  }

  /** 供界面使用：取不到就回退到主题默认的头部底色。 */
  static async heroBackground(pixels: image.PixelMap | null): Promise<string> {
    const color = await ColorTint.dominantColor(pixels);
    if (color === undefined) return Palette.hero;
    return '#' + (color & 0xFFFFFF).toString(16).padStart(6, '0');
  }
}
