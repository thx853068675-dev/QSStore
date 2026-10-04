import { common } from '@kit.AbilityKit';
import { HapAsset } from '../data/ReleaseInfo';
import { StoreClient, RenewalCatalog } from '../data/StoreClient';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { isPending } from './RecoveryPlanner';

export class RenewalTarget {
  appId: number = 0;
  bundleName: string = '';
  versionCode: number = 0;
}

/** Fetch the installed version, independently of the user's selected release channel. */
export class StoreRenewal {
  private static flights: Map<string, Promise<InstallJob>> = new Map();
  static async source(target: RenewalTarget, jobs: InstallJob[],
    client: RenewalCatalog): Promise<HapAsset> {
    if (target.appId <= 0 || !target.bundleName || !Number.isSafeInteger(target.versionCode) ||
      target.versionCode <= 0) throw new Error('无法核对商店续签来源，请使用手动续签');
    const previous = jobs.filter((job: InstallJob) => job.stage === InstallStage.INSTALLED &&
      job.appId === target.appId && job.bundleName === target.bundleName &&
      job.versionCode === target.versionCode && /^https:\/\//.test(job.sourceUrl))
      .sort((a: InstallJob, b: InstallJob) => b.updatedAt - a.updatedAt)[0];
    if (previous) {
      // A completed journal records the inspected package identity and original variant.
      // The runtime will inspect the bytes again before requesting any signing material.
      const asset = new HapAsset();
      asset.name = previous.assetName; asset.url = previous.sourceUrl;
      asset.mirrorUrls = previous.mirrorUrls; asset.bundleName = target.bundleName;
      asset.versionCode = target.versionCode; asset.versionName = previous.versionName;
      return asset;
    }
    const candidates: HapAsset[] = [];
    let incomplete = false;
    // Existing public metadata only: never trigger collection or proxy HAP bytes.
    // Both channels must be inspected before declaring an unambiguous source.
    for (const preview of [false, true]) {
      for (let page = 1; page <= 5; page++) {
        const result = await client.listReleases(target.appId, page, 50, preview);
        for (const release of result.items) {
          for (const asset of release.assets) {
            if (asset.bundleName === target.bundleName && asset.versionCode === target.versionCode &&
              /^https:\/\//.test(asset.url) && !candidates.some((item: HapAsset) => item.url === asset.url)) {
              candidates.push(asset);
            }
          }
        }
        if (!result.hasMore) break;
        if (page === 5) incomplete = true;
      }
    }
    if (incomplete) throw new Error('历史版本过多，无法完整核对原包，请使用手动续签');
    if (candidates.length > 1) throw new Error('同版本有多个安装包，无法确认原来的类型，请使用手动续签');
    if (candidates.length === 0) throw new Error('商店没有已安装版本的原包，请选择同版本文件手动续签');
    return candidates[0];
  }

  static enqueue(context: common.UIAbilityContext, target: RenewalTarget,
    accountReady: boolean = true): Promise<InstallJob> {
    const key = target.appId + ':' + target.bundleName + ':' + target.versionCode;
    const existing = StoreRenewal.flights.get(key);
    if (existing) return existing;
    const flight = StoreRenewal.prepare(context, target, accountReady).finally(() => { StoreRenewal.flights.delete(key); });
    StoreRenewal.flights.set(key, flight);
    return flight;
  }

  private static async prepare(context: common.UIAbilityContext, target: RenewalTarget,
    accountReady: boolean): Promise<InstallJob> {
    const store = await JobStore.open(context);
    const jobs = await store.listAll();
    const pending = jobs.find((job: InstallJob) => isPending(job.stage) &&
      (job.bundleName === target.bundleName || job.catalogBundleName === target.bundleName));
    if (pending) {
      if (pending.renewalRequestedAt > 0 && pending.versionCode === target.versionCode) return pending;
      throw new Error('该应用已有安装任务，请完成或取消后再续签');
    }
    const asset = await StoreRenewal.source(target, jobs, new StoreClient(context));
    return store.enqueueRenewal(target.appId, asset.name, asset.url, asset.mirrorUrls,
      target.bundleName, target.versionCode, asset.versionName, accountReady);
  }

}
