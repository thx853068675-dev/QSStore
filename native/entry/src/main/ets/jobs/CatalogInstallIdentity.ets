import { HapAsset } from '../data/ReleaseInfo';
import { InstallJob, InstallStage } from './InstallJob';

/** 目录预处理尚未补齐包名时，只采用安装成功且来源明确的实际包身份。 */
export class CatalogInstallIdentity {
  static bundle(appId: number, asset: HapAsset | undefined, jobs: InstallJob[]): string {
    if (asset !== undefined && asset.bundleName.length > 0) return asset.bundleName;
    if (appId <= 0) return '';
    const candidates = jobs.filter((job: InstallJob) => job.appId === appId &&
      job.stage === InstallStage.INSTALLED && job.versionCode > 0 && job.bundleName.length > 0 &&
      (asset === undefined || asset.name.length === 0 || job.assetName === asset.name));
    const bundles = Array.from(new Set<string>(candidates.map((job: InstallJob) => job.bundleName)));
    // 多包来源不能猜测；本地导入也不能仅凭同名关联商店条目。
    return bundles.length === 1 ? bundles[0] : '';
  }
}
