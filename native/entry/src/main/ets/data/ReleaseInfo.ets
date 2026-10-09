export class HapAsset {
  name: string = '';
  url: string = '';
  sha256: string = '';
  size: number = 0;
  bundleName: string = '';
  versionCode: number = 0;
  /** 包内版本名，如 1.1.0；设备比对使用 versionCode。 */
  versionName: string = '';
  /** 所属发行记录，仅用于展示；不能替换包内 versionName/versionCode。 */
  releaseName: string = '';
  releaseTag: string = '';
  mirrorUrls: string[] = [];

  static tagFromUrl(url: string): string {
    const match = /\/releases\/download\/([^/]+)\//.exec(url);
    if (match === null) return '';
    try { return decodeURIComponent(match[1]); } catch (_) { return ''; }
  }

  static fromJson(row: Record<string, Object>): HapAsset {
    const asset = new HapAsset();
    asset.name = String(row['name'] ?? '');
    asset.url = String(row['url'] ?? '');
    asset.sha256 = String(row['sha256'] ?? '').toLowerCase();
    asset.size = Number(row['size'] ?? 0);
    asset.bundleName = String(row['bundle_name'] ?? '');
    asset.versionCode = Number(row['version_code'] ?? 0);
    asset.versionName = String(row['version_name'] ?? '');
    asset.releaseName = String(row['release_name'] ?? '');
    asset.releaseTag = String(row['release_tag'] ?? '') || HapAsset.tagFromUrl(asset.url);
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
  prerelease: boolean = false;
  sourceKind: string = 'primary';
  sourceRepo: string = '';
  assets: HapAsset[] = [];

  identity(): string { return this.sourceRepo + ':' + this.tag; }

  sourceLabel(): string { return this.sourceKind === 'secondary' ? '子仓' : '主仓'; }

  static fromJson(row: Record<string, Object>): ReleaseInfo {
    const release = new ReleaseInfo();
    release.tag = String(row['tag'] ?? '');
    release.name = String(row['name'] ?? '');
    release.publishedAt = String(row['published_at'] ?? '');
    release.notes = String(row['body'] ?? '');
    release.prerelease = row['prerelease'] === true;
    release.sourceKind = row['source_kind'] === 'secondary' ? 'secondary' : 'primary';
    release.sourceRepo = String(row['source_repo'] ?? '');
    const raw = row['assets'] as Array<Record<string, Object>> | undefined;
    release.assets = (raw ?? [])
      .map((row: Record<string, Object>) => {
        const asset = HapAsset.fromJson(row);
        asset.releaseName = release.name;
        asset.releaseTag = release.tag;
        return asset;
      })
      .filter((asset: HapAsset) => /\.(hap|app)$/i.test(asset.name));
    return release;
  }
}
