import { util } from '@kit.ArkTS';
import { JobScheduler } from './JobScheduler';
import { common } from '@kit.AbilityKit';
import { AssetDownload } from './AssetDownload';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { DeviceInstallTarget } from './DeviceInstallTarget';

/** Each target has its own durable journal, signed file and confirmation. */
export class MultiDeviceInstall {
  static async enqueue(store: JobStore, source: InstallJob, targets: string[], context?: common.UIAbilityContext): Promise<InstallJob[]> {
    if(JobScheduler.isRunning(source.id))return [source];
    const primary = source.installTarget || '';
    const byDevice: Map<string, string> = new Map();
    for (const value of [primary, ...targets]) {
      const key=value?DeviceInstallTarget.parse(value).key:'local';
      if (!byDevice.has(key)) byDevice.set(key,value);
    }
    const unique=Array.from(byDevice.values());
    const batch=unique.length>1?util.generateRandomUUID():'';
    if(source.batchId!==batch){source.batchId=batch;await store.save(source);}
    if (context && source.sourceUrl !== 'local' && unique.length > 1 && !source.cachePath) {
      await new AssetDownload(context, store).planPaths(source); await store.save(source);
    }
    const result: InstallJob[] = [source];
    for (const target of unique) {
      if (target === primary) continue;
      let job: InstallJob;
      if (source.sourceUrl === 'local') {
        const key = target ? DeviceInstallTarget.parse(target).key : 'local';
        const extension = source.cachePath.endsWith('.app') ? '.app' : '.hap';
        const id='local:'+source.expectedSha256+(target?':device:'+key:'');
        const active=await store.get(id);
        if(active&&JobScheduler.isRunning(id)){result.push(active);continue;}
        job = await store.enqueueLocal(source.cachePath, source.cachePath + '.device-' + key + '.signed' + extension,
          source.expectedSha256, source.bundleName, source.versionCode, source.versionName,
          source.moduleName, source.mainAbility, false, target);
        job.assetName = source.assetName;
        job.editedSourceSha256 = source.editedSourceSha256;
        job.editedSourceAssetName = source.editedSourceAssetName;
        job.packageSourceSha256 = source.packageSourceSha256;
        job.releaseTag = source.releaseTag; job.releaseName = source.releaseName; job.catalogSha256 = source.catalogSha256;
      } else {
        job = await store.enqueue(source.appId, source.assetName, source.catalogSourceUrl || source.sourceUrl,
          source.catalogSha256, source.mirrorUrls, source.versionName, source.catalogBundleName,
          source.catalogVersionCode, source.releaseTag, source.releaseName, true, '', target);
      }
      if(JobScheduler.isRunning(job.id)){result.push(job);continue;}
      job.batchId=batch;
      if(source.forceInstall&&!source.approvedInstallProof)job.forceInstall=true;
      if (source.sourceUrl !== 'local' && source.cachePath && !job.cachePath) {
        const key = target ? DeviceInstallTarget.parse(target).key : 'local';
        job.cachePath = source.cachePath;
        job.signedPath = source.cachePath + '.device-' + key + '.signed' + (source.cachePath.endsWith('.app') ? '.app' : '.hap');
        job.expectedSha256 = source.expectedSha256;
      }
      if (job.stage === InstallStage.INSTALLED || job.stage === InstallStage.PACKAGE_INSPECTED) {
        job.stage = InstallStage.QUEUED; job.stageHistory = []; job.lastError = '';
        job.reinstallRequired = true; job.replacementInstallBaseline = 0;
      }
      if(source.stage===InstallStage.WAITING_ACCOUNT){job.stage=InstallStage.WAITING_ACCOUNT;job.lastError=source.lastError;}
      await store.save(job); result.push(job);
    }
    return result;
  }
}
