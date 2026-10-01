import { common } from '@kit.AbilityKit';
import { PackageArchive } from './PackageArchive';
import { AssetDownload } from './AssetDownload';
import { FailureKind, InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { checkCatalogIdentity, inspectPackage, PackageInspectError, PackageIdentity } from './PackageInspector';

export class DownloadJobs {
  /**
   * 调用方必须已经通过 JobScheduler 取得该任务 ID 的独占权；本方法自己不加锁。
   * 直接调用它会绕过任务互斥，请改用 JobScheduler.runDownload。
   */
  static async runLocked(context: common.UIAbilityContext, store: JobStore, job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    job.stage = InstallStage.DOWNLOADING;
    job.lastError = '';
    await store.save(job);
    try {
      let identity = undefined as PackageIdentity | undefined;
      await new AssetDownload(context, store).downloadAndVerify(job, onProgress, async () => {
        let path = job.cachePath;
        if (job.sourceUrl.includes('#qingqi-package=')) {
          const entry = PackageArchive.selectedEntry(job.sourceUrl);
          path = await PackageArchive.extractSelected(path, entry,
            path + '.package' + PackageArchive.extension(entry));
        }
        identity = path.endsWith('.app') ? await PackageArchive.inspect(path) : inspectPackage(path);
        checkCatalogIdentity(job.catalogBundleName, job.catalogVersionCode, identity);
      });
      if (identity === undefined) throw new PackageInspectError('下载包尚未核对身份');
      job.stage = InstallStage.VERIFIED;
      await store.save(job);
      job.bundleName = identity.bundleName;
      job.versionCode = identity.versionCode;
      if ((identity.versionName ?? '').length > 0) job.versionName = identity.versionName;
      job.moduleName = identity.moduleName;
      job.mainAbility = identity.mainAbility;
      job.stage = InstallStage.PACKAGE_INSPECTED;
      job.lastError = '';
      await store.save(job);
    } catch (error) {
      const message = String(error);
      if (message.includes('仍在后台下载')) {
        // The agent keeps downloading. A later foreground run reattaches.
        await store.save(job);
      } else {
        const kind = error instanceof PackageInspectError || message.includes('SHA-256') ?
          FailureKind.INVALID_PACKAGE :
          FailureKind.NETWORK;
        await store.recordFailure(job, kind, message);
      }
      throw new Error(message);
    }
  }
}
