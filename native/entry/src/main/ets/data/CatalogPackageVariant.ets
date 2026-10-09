import { HapAsset } from './ReleaseInfo';

/** 版本号变化不代表包类型变化；压缩来源及平台标记仍保留在匹配键中。 */
export class CatalogPackageVariant {
  static key(name: string): string {
    return name.toLowerCase().replace(/(^|[^a-z0-9])v?\d+(?:\.\d+){1,5}(?:[-_. ](?:alpha|beta|rc|pre|preview|dev|nightly)(?:[._-]?\d+)?)?/g, '$1{version}')
      .replace(/[ _]+/g, '-').replace(/-+/g, '-').trim();
  }

  static choose(choices: HapAsset[], preferredName: string, primary?: HapAsset): HapAsset | undefined {
    if (choices.length === 0) return undefined;
    const exact = choices.find((asset: HapAsset) => asset.name === preferredName);
    if (exact !== undefined) return exact;
    if (choices.length === 1) return choices[0];
    const key = CatalogPackageVariant.key(preferredName);
    const matching = choices.filter((asset: HapAsset) => CatalogPackageVariant.key(asset.name) === key);
    if (matching.length === 1) return matching[0];
    // 设备清单的显示名和早期本地任务的包名.hap 都没有记录原包类型。
    const unknownVariant = !/\.(hap|app|zip|7z|rar)(?:$|\s*\/)/i.test(preferredName) ||
      choices.some((asset: HapAsset) => preferredName === asset.bundleName + '.hap');
    if (!unknownVariant) return undefined;
    return choices.find((asset: HapAsset) => asset.url === primary?.url && asset.name === primary?.name) ?? choices[0];
  }
}
