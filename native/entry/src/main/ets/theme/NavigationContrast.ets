export interface NavigationForeground {
  idle: string;
  selected: string;
}

export interface NavigationSampleRegion {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** Contrast selection uses the actual glass background, independently for each native tab. */
export class NavigationContrast {
  private static channel(value: number): number {
    const c = value / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }

  private static luminance(red: number, green: number, blue: number): number {
    return 0.2126 * NavigationContrast.channel(red) + 0.7152 * NavigationContrast.channel(green) +
      0.0722 * NavigationContrast.channel(blue);
  }

  private static colorLuminance(color: string): number {
    return NavigationContrast.luminance(parseInt(color.substring(1, 3), 16),
      parseInt(color.substring(3, 5), 16), parseInt(color.substring(5, 7), 16));
  }

  private static score(color: string, background: number): number {
    const foreground = NavigationContrast.colorLuminance(color);
    return (Math.max(background, foreground) + 0.05) / (Math.min(background, foreground) + 0.05);
  }

  /** At most 32 BGRA pixels; exclude the center occupied by the icon and label. */
  static sample(bytes: Uint8Array, width: number, height: number, region: NavigationSampleRegion,
    previous?: NavigationForeground): NavigationForeground | undefined {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
      bytes.length < width * height * 4 || !Number.isFinite(region.left + region.top + region.width + region.height) ||
      region.left < 0 || region.top < 0 || region.width < 4 || region.height < 4 ||
      region.left + region.width > width + 1 || region.top + region.height > height + 1) return undefined;
    const background: number[] = [];
    const positions: number[] = [0.12, 0.22, 0.78, 0.88];
    for (let row = 0; row < 8; row++) {
      for (const column of positions) {
        const x = Math.min(width - 1, Math.floor(region.left + region.width * column));
        const y = Math.min(height - 1, Math.floor(region.top + region.height * (0.15 + row * 0.1)));
        const offset = (y * width + x) * 4;
        // A transparent/unsupported material snapshot is not a reliable backdrop.
        if (bytes[offset + 3] < 240) continue;
        background.push(NavigationContrast.luminance(bytes[offset + 2], bytes[offset + 1], bytes[offset]));
      }
    }
    if (background.length < 16) return undefined;
    // Glass has bright reflections and dark edges. Its dominant luminance, not
    // the worst few pixels, determines whether the visible region is light/dark.
    background.sort((a: number, b: number) => a - b);
    const middle = Math.floor(background.length / 2);
    const backdrop = (background[middle] + background[Math.floor((background.length - 1) / 2)]) / 2;
    const dark = '#17213A', light = '#FFFFFF';
    let idle = NavigationContrast.score(dark, backdrop) >= NavigationContrast.score(light, backdrop) ? dark : light;
    // Avoid flickering between equally readable choices near the decision boundary.
    if (previous && (previous.idle === dark || previous.idle === light) &&
      NavigationContrast.score(previous.idle, backdrop) >= 4.5 &&
      NavigationContrast.score(idle, backdrop) < NavigationContrast.score(previous.idle, backdrop) * 1.15) {
      idle = previous.idle;
    }
    const accent = idle === dark ? '#2463E9' : '#BDD3FF';
    return { idle: idle, selected: NavigationContrast.score(accent, backdrop) >= 4.5 ? accent : idle };
  }
}
