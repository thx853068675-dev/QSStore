export class HapAsset {
  name: string = '';
  url: string = '';
  sha256: string = '';
  size: number = 0;
  bundleName: string = '';
  versionCode: number = 0;
  /** 展示用版本名，如 1.1.0。设备比对用 versionCode，界面显示用这个。 */
  versionName: string = '';
  mirrorUrls: string[] = [];

  static fromJson(row: Record<string, Object>): HapAsset {
    const asset = new HapAsset();
    asset.name = String(row['name'] ?? '');
    asset.url = String(row['url'] ?? '');
    asset.sha256 = String(row['sha256'] ?? '').toLowerCase();
    asset.size = Number(row['size'] ?? 0);
    asset.bundleName = String(row['bundle_name'] ?? '');
    asset.versionCode = Number(row['version_code'] ?? 0);
    asset.versionName = String(row['version_name'] ?? '');
    const mirrors = row['mirror_urls'] as string[] | undefined;
    asset.mirrorUrls = mirrors ?? [];
    return asset;
  }
}

export class ReleaseInfo {
  tag: string = '';
  name: string = '';
  publishedAt: string = '';
  notes: string = '';
  assets: HapAsset[] = [];

  static fromJson(row: Record<string, Object>): ReleaseInfo {
    const release = new ReleaseInfo();
    release.tag = String(row['tag'] ?? '');
    release.name = String(row['name'] ?? '');
    release.publishedAt = String(row['published_at'] ?? '');
    release.notes = String(row['body'] ?? '');
    const raw = row['assets'] as Array<Record<string, Object>> | undefined;
    release.assets = (raw ?? [])
      .map((asset: Record<string, Object>) => HapAsset.fromJson(asset))
      .filter((asset: HapAsset) => asset.name.toLowerCase().endsWith('.hap'));
    return release;
  }
}
