import { releaseDisplayVersion } from '../data/DisplayVersion';
import { HapAsset } from '../data/ReleaseInfo';
import { InstallJob, InstallStage } from './InstallJob';

/** 内部编号是安装下限；相同编号的发行更新由已确认的包记录识别。 */
export class ReleaseUpdate {
  static compare(left: string, right: string): number | undefined {
    const pattern = /^(\d+(?:\.\d+){0,5})(?:-([a-zA-Z0-9]+(?:[.\-][a-zA-Z0-9]+)*))?(?:\+[a-zA-Z0-9.\-]+)?$/;
    const a = pattern.exec(left), b = pattern.exec(right);
    if (a === null || b === null) return undefined;
    const av = a[1].split('.'), bv = b[1].split('.');
    for (let i = 0; i < Math.max(av.length, bv.length); i++) {
      const order = ReleaseUpdate.numeric(av[i] ?? '0', bv[i] ?? '0');
      if (order !== 0) return order;
    }
    if (a[2] === b[2]) return 0;
    if (!a[2]) return 1;
    if (!b[2]) return -1;
    const ap = a[2].toLowerCase().split('.'), bp = b[2].toLowerCase().split('.');
    for (let i = 0; i < Math.max(ap.length, bp.length); i++) {
      if (i >= ap.length) return -1;
      if (i >= bp.length) return 1;
      const x = ap[i], y = bp[i];
      if (x === y) continue;
      const xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
      if (xn && yn) return ReleaseUpdate.numeric(x, y);
      if (xn !== yn) return xn ? -1 : 1;
      return x < y ? -1 : 1;
    }
    return 0;
  }

  private static numeric(left: string, right: string): number {
    const a = left.replace(/^0+(?=\d)/, ''), b = right.replace(/^0+(?=\d)/, '');
    return a.length !== b.length ? (a.length < b.length ? -1 : 1) : a === b ? 0 : a < b ? -1 : 1;
  }

  static completedAt(job: InstallJob): number {
    const history = job.stageHistory ?? [];
    for (let i = history.length - 1; i >= 0; i--) {
      if (history[i].stage === InstallStage.INSTALLED) return history[i].at;
    }
    return job.updatedAt;
  }

  static record(jobs: InstallJob[], bundleName: string, version: number,
    updateTime: number = 0): InstallJob | undefined {
    let newest: InstallJob | undefined;
    for (const job of jobs) {
      if (job.stage !== InstallStage.INSTALLED || job.bundleName !== bundleName || job.versionCode !== version) continue;
      if (newest === undefined || ReleaseUpdate.completedAt(job) > ReleaseUpdate.completedAt(newest)) newest = job;
    }
    if (newest !== undefined && updateTime > 0 &&
      ((newest.installedUpdateTime > 0 && newest.installedUpdateTime !== updateTime) ||
        (newest.installedUpdateTime <= 0 && updateTime > ReleaseUpdate.completedAt(newest) + 2000))) return undefined;
    return newest;
  }

  static tag(job: InstallJob): string {
    if (job.releaseTag) return job.releaseTag;
    for (const url of [job.sourceUrl, ...(job.mirrorUrls ?? [])]) {
      const tag = HapAsset.tagFromUrl(url ?? '');
      if (tag) return tag;
    }
    return '';
  }

  static version(asset: HapAsset): string {
    return releaseDisplayVersion(asset.releaseName ?? '', asset.releaseTag ?? '', asset.versionName ?? '');
  }

  static forJob(job: InstallJob): HapAsset {
    const asset = new HapAsset();
    asset.bundleName = job.bundleName || job.catalogBundleName;
    asset.versionCode = job.versionCode || job.catalogVersionCode;
    asset.versionName = job.versionName; asset.name = job.assetName; asset.url = job.sourceUrl;
    asset.releaseTag = ReleaseUpdate.tag(job); asset.releaseName = job.releaseName ?? '';
    asset.sha256 = job.catalogSha256 || job.expectedSha256;
    return asset;
  }

  static available(asset: HapAsset, installed: number, installedName: string,
    jobs: InstallJob[], updateTime: number = 0, bundleName: string = ''): boolean {
    const bundle = asset.bundleName || bundleName;
    if (installed <= 0 || asset.versionCode <= 0 || !bundle) return false;
    if (asset.versionCode !== installed) return asset.versionCode > installed;
    const previous = ReleaseUpdate.record(jobs, bundle, installed, updateTime);
    const digest = asset.sha256?.toLowerCase() ?? '';
    const actual = previous?.expectedSha256?.toLowerCase() ?? '';
    const catalog = previous?.catalogSha256?.toLowerCase() ?? '';
    if (/^[a-f0-9]{64}$/.test(digest) && (digest === actual || digest === catalog)) return false;
    const before = previous === undefined ? installedName : releaseDisplayVersion(previous.releaseName ?? '',
      ReleaseUpdate.tag(previous), previous.versionName || installedName);
    const order = ReleaseUpdate.compare(ReleaseUpdate.version(asset), before);
    if (order !== undefined && order !== 0) return order > 0;
    // 同号替换发行附件也可更新。没有安装来源/摘要证据时不能仅凭哈希不同猜测。
    const sameRelease = previous !== undefined && (order === 0 ||
      ((asset.releaseTag ?? '').length > 0 && asset.releaseTag === ReleaseUpdate.tag(previous)) ||
      [previous.sourceUrl, ...(previous.mirrorUrls ?? [])].includes(asset.url));
    return sameRelease && /^[a-f0-9]{64}$/.test(digest) &&
      (/^[a-f0-9]{64}$/.test(actual) || /^[a-f0-9]{64}$/.test(catalog)) && digest !== actual && digest !== catalog;
  }

  static older(asset: HapAsset, installed: number, installedName: string,
    jobs: InstallJob[], updateTime: number = 0): boolean {
    if (asset.versionCode > 0 && installed > asset.versionCode) return true;
    if (installed <= 0 || asset.versionCode !== installed) return false;
    const previous = ReleaseUpdate.record(jobs, asset.bundleName, installed, updateTime);
    const before = previous === undefined ? installedName : releaseDisplayVersion(previous.releaseName ?? '',
      ReleaseUpdate.tag(previous), previous.versionName || installedName);
    return (ReleaseUpdate.compare(ReleaseUpdate.version(asset), before) ?? 0) < 0;
  }
}
