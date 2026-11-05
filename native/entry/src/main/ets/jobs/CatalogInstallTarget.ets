import { CatalogApp } from '../data/CatalogApp';
import { CatalogPackageVariant } from '../data/CatalogPackageVariant';
import { HapAsset } from '../data/ReleaseInfo';
import { InstallJob, InstallStage } from './InstallJob';
import { ReleaseUpdate } from './ReleaseUpdate';

/** Choose one package before comparing versions, rendering actions or downloading. */
export class CatalogInstallTarget {
  static choose(app: CatalogApp, jobs: InstallJob[], installed: number, updateTime: number = 0,
    bundleName: string = '', preferredName: string = ''): HapAsset | undefined {
    // Old cached catalog entries and fixtures may not contain latestAssets.
    const choices = app.latestAssets !== undefined && app.latestAssets.length > 0 ? app.latestAssets :
      (app.latestAsset === undefined ? [] : [app.latestAsset]);
    const bundle = bundleName || app.latestAsset?.bundleName || choices[0]?.bundleName || '';
    const sameBundle = bundle.length > 0 ? choices.filter((item: HapAsset) => item.bundleName === bundle) : choices;
    const primary = app.latestAsset !== undefined && (!bundle || app.latestAsset.bundleName === bundle) ?
      app.latestAsset : undefined;
    const receipt = CatalogInstallTarget.receipt(jobs ?? [], bundle, installed, updateTime);
    return CatalogInstallTarget.asset(sameBundle, primary, receipt, preferredName);
  }

  /** Unknown observations may use a completed receipt; confirmed absence never does. */
  static receipt(jobs: InstallJob[], bundleName: string, installed: number,
    updateTime: number = 0): InstallJob | undefined {
    if (!bundleName || !Number.isFinite(installed) || installed === 0) return undefined;
    if (installed > 0) return ReleaseUpdate.record(jobs, bundleName, installed, updateTime);
    let newest: InstallJob | undefined;
    for (const job of jobs) {
      if (job.stage !== InstallStage.INSTALLED || job.bundleName !== bundleName || job.versionCode <= 0) continue;
      if (newest === undefined || ReleaseUpdate.completedAt(job) > ReleaseUpdate.completedAt(newest)) newest = job;
    }
    return newest === undefined ? undefined : ReleaseUpdate.record(jobs, bundleName, newest.versionCode, updateTime);
  }

  /** Receipt must already match the current device's code and installation time. */
  static asset(choices: HapAsset[], primary: HapAsset | undefined, receipt: InstallJob | undefined,
    preferredName: string = ''): HapAsset | undefined {
    const bundle = receipt?.bundleName || primary?.bundleName || '';
    const sameBundle = bundle.length > 0 ? choices.filter((item: HapAsset) => item.bundleName === bundle) : choices;
    if (sameBundle.length === 0) return undefined;
    const currentPrimary = sameBundle.find((item: HapAsset) => item.name === primary?.name && item.url === primary?.url);
    if (receipt?.editedSourceSha256) {
      const sourceName = receipt.editedSourceAssetName ?? '';
      const canonicalMatches = sourceName ? sameBundle.filter((item: HapAsset) => item.name === sourceName ||
        CatalogPackageVariant.key(item.name) === CatalogPackageVariant.key(sourceName)) : [];
      const canonical = canonicalMatches.length === 1 ? canonicalMatches[0] : undefined;
      // A replaced ZIP must still be compared with its ZIP receipt. Its new
      // digest is the update evidence; an unchanged standalone HAP is unrelated.
      if (canonical !== undefined && /^[a-f0-9]{64}$/i.test(receipt.catalogSha256 ?? '')) return canonical;
      const exact = sameBundle.filter((item: HapAsset) => item.versionCode === receipt.versionCode &&
        item.sha256?.toLowerCase() === receipt.editedSourceSha256.toLowerCase());
      if (exact.length === 1) return exact[0];
    }
    // A matching completed APP/ZIP receipt must not be compared against the
    // unrelated HAP digest, even when both contain the same internal version.
    const receiptName = receipt?.editedSourceAssetName || receipt?.assetName || '';
    if (receiptName.length > 0) {
      return CatalogPackageVariant.choose(sameBundle, receiptName, currentPrimary);
    }
    // Invalidated/old receipts cannot impose a package variant. Keep the same
    // catalog default across Discover, Detail and Management in that case.
    if (currentPrimary !== undefined) return currentPrimary;
    const defaultName = primary?.name || preferredName;
    return defaultName.length > 0 ? CatalogPackageVariant.choose(sameBundle, defaultName) : sameBundle[0];
  }
}
