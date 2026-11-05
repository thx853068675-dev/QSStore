import { deviceInfo } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { DeviceSupportDisplay } from '../data/DeviceSupportDisplay';
import { HapAsset } from '../data/ReleaseInfo';
import { Palette } from '../theme/Palette';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { InstallJob } from './InstallJob';
import { PackageArchive } from './PackageArchive';
import { I18n } from '../data/I18n';

/** A warning can be accepted only for the exact selected or verified package. */
export class InstallDeviceCompatibility {
  private static pending: Map<string, Promise<boolean>> = new Map();
  private static accepted: Map<string, string> = new Map();
  private static tail: Promise<void> = Promise.resolve();

  private static current(job?: InstallJob, target: string = ''): string {
    if(job?.installTarget || target){const type=DeviceInstallTarget.parse(job?.installTarget || target).kind;return type==='pc'?'2in1':type;}
    try { return deviceInfo.deviceType.trim().toLowerCase(); } catch (_) { return ''; }
  }

  private static canonical(types: Object | undefined): string[] {
    return DeviceSupportDisplay.normalize(types).map((type: string) => type.toLowerCase()).sort();
  }

  private static fingerprint(url: string, sha256: string, current: string, supported: string[]): string {
    const digest = sha256.toLowerCase();
    if (!url || !/^[a-f0-9]{64}$/.test(digest) ||
      DeviceSupportDisplay.matches(supported, current) !== false) return '';
    return JSON.stringify([1, url, digest, current, supported]);
  }

  private static selection(url: string): string | undefined {
    try { return PackageArchive.selectedEntry(url); } catch (_) { return undefined; }
  }

  private static packageFingerprint(job: InstallJob, current: string, supported: string[]): string {
    const url = job.catalogSourceUrl || job.sourceUrl;
    const containerDigest = (job.expectedSha256 ?? '').toLowerCase();
    const packageDigest = (job.packageSourceSha256 ?? '').toLowerCase();
    const selection = InstallDeviceCompatibility.selection(job.sourceUrl);
    if (!url || selection === undefined || !/^[a-f0-9]{64}$/.test(containerDigest) ||
      !/^[a-f0-9]{64}$/.test(packageDigest) ||
      DeviceSupportDisplay.matches(supported, current) !== false) return '';
    return JSON.stringify([2, url, containerDigest, selection, packageDigest, current, supported]);
  }

  private static assetKey(asset: HapAsset, current: string, supported: string[]): string {
    return JSON.stringify([asset.bundleName, asset.url, asset.sha256.toLowerCase(), asset.versionCode,
      current, supported]);
  }

  /** Snapshot after confirm resolves; silent success never grants approval. */
  static confirmedFingerprint(asset: HapAsset, target: string = ''): string {
    const current = InstallDeviceCompatibility.current(undefined, target);
    const supported = InstallDeviceCompatibility.canonical(asset.deviceTypes);
    const key = InstallDeviceCompatibility.assetKey(asset, current, supported);
    const fingerprint = InstallDeviceCompatibility.fingerprint(asset.url, asset.sha256, current, supported);
    return fingerprint && InstallDeviceCompatibility.accepted.get(key) === fingerprint ? fingerprint : '';
  }

  static confirm(asset: HapAsset, title: string, target: string = ''): Promise<boolean> {
    const current = InstallDeviceCompatibility.current(undefined, target);
    const supported = InstallDeviceCompatibility.canonical(asset.deviceTypes);
    if (DeviceSupportDisplay.matches(supported, current) !== false) return Promise.resolve(true);
    const key = InstallDeviceCompatibility.assetKey(asset, current, supported);
    const existing = InstallDeviceCompatibility.pending.get(key);
    if (existing !== undefined) return existing;
    // A later attempt owns a new decision; an old in-memory answer is not consent.
    InstallDeviceCompatibility.accepted.delete(key);
    const fingerprint = InstallDeviceCompatibility.fingerprint(asset.url, asset.sha256, current, supported);
    return InstallDeviceCompatibility.request(key, title.trim() || asset.name || I18n.t('此应用'), current,
      DeviceSupportDisplay.normalize(asset.deviceTypes), fingerprint);
  }

  /** Metadata consent is reused only when the verified digest and real declaration agree. */
  static pendingPackageConsent(job:InstallJob,types:string[],title:string):string{
    const current=InstallDeviceCompatibility.current(job);
    const supported=InstallDeviceCompatibility.canonical(types);
    const fingerprint=InstallDeviceCompatibility.packageFingerprint(job,current,supported);
    if(!fingerprint||job.deviceCompatibilityFingerprint===fingerprint)return '';
    const url=job.catalogSourceUrl||job.sourceUrl;
    const metadata=InstallDeviceCompatibility.fingerprint(url,(job.expectedSha256??'').toLowerCase(),current,supported);
    const selection=InstallDeviceCompatibility.selection(job.sourceUrl);
    if(metadata&&job.deviceCompatibilityFingerprint===metadata&&selection===InstallDeviceCompatibility.selection(url)&&
      (selection!==''||(job.packageSourceSha256??'').toLowerCase()===(job.expectedSha256??'').toLowerCase())){
      job.deviceCompatibilityFingerprint=fingerprint;return '';
    }
    return JSON.stringify({fingerprint:fingerprint,title:title,
      current:DeviceSupportDisplay.labels([current]).join(I18n.t('、'))||current,
      supported:DeviceSupportDisplay.labels(supported).join(I18n.t('、'))});
  }

  /** Legacy callers can still await an immediate single-device prompt. Jobs use the decision chain. */
  static async confirmPackage(job: InstallJob, types: string[], title: string): Promise<boolean> {
    const current = InstallDeviceCompatibility.current(job);
    const supported = InstallDeviceCompatibility.canonical(types);
    if (DeviceSupportDisplay.matches(supported, current) !== false) return true;
    const url = job.catalogSourceUrl || job.sourceUrl;
    const containerDigest = (job.expectedSha256 ?? '').toLowerCase();
    const packageDigest = (job.packageSourceSha256 ?? '').toLowerCase();
    const selection = InstallDeviceCompatibility.selection(job.sourceUrl);
    const fingerprint = InstallDeviceCompatibility.packageFingerprint(job, current, supported);
    if (fingerprint && job.deviceCompatibilityFingerprint === fingerprint) return true;
    const metadataFingerprint = InstallDeviceCompatibility.fingerprint(url, containerDigest, current, supported);
    // A catalog ZIP approval names one archive member. Convert it to a real
    // inner-package receipt only after the verified container and selection
    // agree; direct packages must also have the same source/container digest.
    if (fingerprint && metadataFingerprint && job.deviceCompatibilityFingerprint === metadataFingerprint &&
      selection === InstallDeviceCompatibility.selection(url) &&
      (selection !== '' || packageDigest === containerDigest)) {
      job.deviceCompatibilityFingerprint = fingerprint;
      return true;
    }
    job.deviceCompatibilityFingerprint = '';
    const accepted = await InstallDeviceCompatibility.request(
      JSON.stringify(['verified-package', job.id, url, containerDigest, selection, packageDigest, current, supported]),
      title.trim() || job.assetName || job.bundleName || I18n.t('此应用'), current, supported, '');
    // A queued prompt cannot approve a package/device selection changed while
    // another dialog was visible. The next manual attempt owns that decision.
    if (!accepted || fingerprint !== InstallDeviceCompatibility.packageFingerprint(job,
      InstallDeviceCompatibility.current(job), supported)) return false;
    job.deviceCompatibilityFingerprint = fingerprint;
    return true;
  }

  private static request(key: string, name: string, current: string,
    supported: string[], fingerprint: string): Promise<boolean> {
    const existing = InstallDeviceCompatibility.pending.get(key);
    if (existing !== undefined) return existing;
    const currentLabel = DeviceSupportDisplay.labels([current]).join('、') || current;
    const supportedLabel = DeviceSupportDisplay.labels(supported).join('、');
    // Snapshot all prompt text before the FIFO wait; pages may change selection.
    const message = I18n.t('「') + name + I18n.t('」声明的支持设备：') + supportedLabel + '。\n' +
      I18n.t('当前设备：') + currentLabel + I18n.t('。\n仍要继续安装吗？');
    const request = InstallDeviceCompatibility.tail.then(async (): Promise<boolean> => {
      try {
        let dark = false;
        try { dark = AppStorage.get<boolean>('darkMode') ?? false; } catch (_) {}
        const colors = Palette.forMode(dark);
        const result = await promptAction.showDialog({ title: I18n.t('此应用可能不适用当前设备'), message: message,
          buttons: [{ text: I18n.t('取消'), color: colors.textSecondary }, { text: I18n.t('继续安装'), color: colors.accent }] });
        const accepted = result.index === 1;
        if (accepted && fingerprint) {
          while (InstallDeviceCompatibility.accepted.size >= 64) {
            InstallDeviceCompatibility.accepted.delete(Array.from(InstallDeviceCompatibility.accepted.keys())[0]);
          }
          InstallDeviceCompatibility.accepted.set(key, fingerprint);
        }
        return accepted;
      } catch (_) { return false; }
    });
    InstallDeviceCompatibility.pending.set(key, request);
    InstallDeviceCompatibility.tail = request.then(() => {}, () => {});
    request.finally(() => {
      if (InstallDeviceCompatibility.pending.get(key) === request) InstallDeviceCompatibility.pending.delete(key);
    }).catch(() => {});
    return request;
  }
}
