import { common } from '@kit.AbilityKit';
import { AssetDownload } from './AssetDownload';
import { FailureKind, InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { inspectPackage, PackageInspectError } from './PackageInspector';

export class DownloadJobs {
  private static active: Set<string> = new Set<string>();

  static async run(context: common.UIAbilityContext, store: JobStore, job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    if (DownloadJobs.active.has(job.id)) throw new Error('该附件正在下载');
    DownloadJobs.active.add(job.id);
    try {
      job.stage = InstallStage.DOWNLOADING;
      job.lastError = '';
      await store.save(job);
      await new AssetDownload(context, store).downloadAndVerify(job, onProgress);
      job.stage = InstallStage.VERIFIED;
      await store.save(job);
      const identity = inspectPackage(job.cachePath);
      job.bundleName = identity.bundleName;
      job.versionCode = identity.versionCode;
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
    } finally {
      DownloadJobs.active.delete(job.id);
    }
  }
}
