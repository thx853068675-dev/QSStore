import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { cert } from '@kit.DeviceCertificateKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { readSignedProfile } from 'libhap_core.so';
import { AgcProfile } from '../data/AgcProfile';
import { LocalProfileStore } from '../data/LocalProfileStore';
import { InstallJob, InstallStage } from './InstallJob';
import { InstalledAppRegistry, InstalledSigningIdentity } from './InstalledAppRegistry';
import { ForegroundIdle } from './ForegroundIdle';

/** A retained Profile is a display estimate until tied to an installed build. */
export class SigningExpiryMaterial {
  bundleName: string = '';
  fingerprint: string = '';
  appIdentifier: string = '';
  notBefore: number = 0;
  expiresAt: number = 0;
  certificateExpiresAt: number = 0;
  durationSeconds: number = 0;
}

/** Expiry belongs to an installed build, not to the account's default certificate. */
export class InstalledSigningExpiry {
  private static readonly DEFAULT_DURATION_SECONDS: number = 365 * 86400;
  private static profiles: Map<string, Promise<number>> = new Map();
  private static materials: Map<string, Promise<SigningExpiryMaterial | undefined>> = new Map();
  private static inspectedBundles: Set<string> = new Set();

  static asn1Seconds(value: string): number {
    const match = /^(\d{2}|\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(value);
    if (!match) return 0;
    let year = Number(match[1]);
    if (match[1].length === 2) year += year >= 50 ? 1900 : 2000;
    const milliseconds = Date.UTC(year, Number(match[2]) - 1, Number(match[3]),
      Number(match[4]), Number(match[5]), Number(match[6]));
    const date = new Date(milliseconds);
    if (date.getUTCFullYear() !== year || date.getUTCMonth() !== Number(match[2]) - 1 ||
      date.getUTCDate() !== Number(match[3]) || date.getUTCHours() !== Number(match[4]) ||
      date.getUTCMinutes() !== Number(match[5]) || date.getUTCSeconds() !== Number(match[6])) return 0;
    return Math.floor(milliseconds / 1000);
  }

  static async profileExpiry(job: InstallJob): Promise<number> {
    const digest = job.signedProfileSha256 || job.profileSha256;
    if (!job.profilePath || !/^[a-f0-9]{64}$/i.test(digest)) return 0;
    const key = job.profilePath + ':' + digest;
    const existing = InstalledSigningExpiry.profiles.get(key);
    if (existing) return existing;
    const flight = InstalledSigningExpiry.inspectProfile(job, digest).catch(() => 0);
    InstalledSigningExpiry.profiles.set(key, flight);
    // Keep only small decoded results, not HAP bytes or certificate contents.
    if (InstalledSigningExpiry.profiles.size > 200) {
      const oldest: string = Array.from(InstalledSigningExpiry.profiles.keys())[0];
      if (oldest !== undefined) InstalledSigningExpiry.profiles.delete(oldest);
    }
    const expiry = await flight;
    if (expiry === 0) InstalledSigningExpiry.profiles.delete(key);
    return expiry;
  }

  private static async inspectProfile(job: InstallJob, digest: string): Promise<number> {
    if ((await hash.hash(job.profilePath, 'sha256')).toLowerCase() !== digest.toLowerCase()) return 0;
    const profile = JSON.parse(readSignedProfile(job.profilePath)) as Record<string, Object>;
    const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
    if (bundle?.['bundle-name'] !== job.bundleName) return 0;
    const validity = profile['validity'] as Record<string, Object> | undefined;
    const end = Number(validity?.['not-after'] ?? 0);
    const pem = String(bundle?.['development-certificate'] ?? '');
    if (!Number.isFinite(end) || end <= 0) return 0;
    const certEnd = await InstalledSigningExpiry.certificateExpiry(pem);
    return certEnd > 0 ? Math.floor(Math.min(end, certEnd)) : 0;
  }

  private static async certificateExpiry(pem: string): Promise<number> {
    const match = /-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----/.exec(pem);
    if (!match) return 0;
    const certificate = await cert.createX509Cert({ data: new util.Base64Helper().decodeSync(
      match[1].replace(/\s/g, '')), encodingFormat: cert.EncodingFormat.FORMAT_DER });
    return InstalledSigningExpiry.asn1Seconds(certificate.getNotAfterTime());
  }

  static async capture(job: InstallJob, installed: InstalledSigningIdentity): Promise<void> {
    if (installed.versionCode !== job.versionCode || installed.updateTime <= 0 ||
      !job.profilePath || installed.fingerprint !== await AgcProfile.signingFingerprint(job.profilePath)) return;
    const expiry = await InstalledSigningExpiry.profileExpiry(job);
    if (expiry <= 0) return;
    job.authorizationExpiresAt = expiry;
    job.installedUpdateTime = installed.updateTime;
    job.installedFingerprint = installed.fingerprint;
  }

  static current(bundleName: string): InstalledSigningIdentity | undefined {
    try {
      const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO;
      const own = bundleManager.getBundleInfoForSelfSync(flags);
      const info = own.name === bundleName ? own : bundleManager.getBundleInfoSync(bundleName, flags);
      if (info.name !== bundleName) return undefined;
      const current = new InstalledSigningIdentity();
      if (!InstalledSigningExpiry.inspectedBundles.has(bundleName)) {
        InstalledSigningExpiry.inspectedBundles.add(bundleName);
        const material = String(info.signatureInfo?.certificate ?? '');
        console.info('Installed signing metadata: bundle=' + bundleName + ' certificateLength=' + material.length +
          ' certificatePem=' + material.includes('-----BEGIN CERTIFICATE-----'));
      }
      current.versionCode = info.versionCode; current.updateTime = info.updateTime;
      current.fingerprint = String(info.signatureInfo?.fingerprint ?? '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();
      current.appIdentifier = String(info.signatureInfo?.appIdentifier ?? '');
      if (current.versionCode > 0 && (current.updateTime <= 0 || current.fingerprint.length !== 64)) return undefined;
      return current;
    } catch (error) {
      // A confirmed uninstall must not fall back to an older scanned signature.
      if ((error as BusinessError).code === 17700001) return new InstalledSigningIdentity();
      return undefined;
    }
  }

  static async read(bundleName: string, versionCode: number, jobs: InstallJob[]): Promise<number> {
    const current = InstalledSigningExpiry.current(bundleName) ?? InstalledAppRegistry.signingIdentity(bundleName);
    if (current === undefined) return 0;
    if (current.versionCode !== versionCode || current.updateTime <= 0 || current.fingerprint.length !== 64) return 0;
    for (const job of jobs.filter((item: InstallJob) => item.stage === InstallStage.INSTALLED &&
      item.bundleName === bundleName && item.versionCode === versionCode).sort((a: InstallJob, b: InstallJob) => b.updatedAt - a.updatedAt)) {
      if (job.installedUpdateTime > 0) {
        if (job.installedUpdateTime === current.updateTime && job.installedFingerprint === current.fingerprint &&
          Number.isFinite(job.authorizationExpiresAt) && job.authorizationExpiresAt > 0) return job.authorizationExpiresAt;
        continue;
      }
      // Legacy journals recorded the installation's immutable stage mark. Only
      // migrate a matching completion, never another tool's later reinstall.
      const completedAt = job.stageHistory.find((mark) => mark.stage === InstallStage.INSTALLED)?.at ?? 0;
      if (completedAt < current.updateTime || completedAt - current.updateTime > 60000 || !job.profilePath) continue;
      try {
        if (await AgcProfile.signingFingerprint(job.profilePath) !== current.fingerprint) continue;
        const expiry = await InstalledSigningExpiry.profileExpiry(job);
        if (expiry > 0) return expiry;
      } catch (_) {}
    }
    return 0;
  }

  static dueSoon(expiry: number, now: number = Date.now() / 1000): boolean {
    return Number.isFinite(expiry) && expiry > 0 && expiry <= now + 7 * 24 * 3600;
  }

  /** Read each retained file once per UI refresh, only decoding certificates for requested bundles. */
  static async estimateMaterials(context: common.UIAbilityContext, bundleNames: string[],
    active: () => boolean = (): boolean => true): Promise<SigningExpiryMaterial[]> {
    const result: SigningExpiryMaterial[] = [];
    if (!bundleNames.length) return result;
    const wanted = new Set<string>(bundleNames);
    const fingerprints = new Set<string>();
    for (const name of bundleNames) {
      // Display-only certificate probes must yield between synchronous system IPCs.
      await ForegroundIdle.wait();
      if (!active()) return [];
      const current = InstalledSigningExpiry.current(name) ?? InstalledAppRegistry.signingIdentity(name);
      if (current?.fingerprint) fingerprints.add(current.fingerprint);
    }
    let paths: string[] = [];
    try { paths = LocalProfileStore.retainedFiles(context); } catch (_) { return result; }
    const retained = new Set<string>(paths);
    for (const key of InstalledSigningExpiry.materials.keys()) {
      if (!retained.has(key.substring(0, key.lastIndexOf('|')))) InstalledSigningExpiry.materials.delete(key);
    }
    for (const path of paths) {
      await ForegroundIdle.wait();
      if (!active()) return [];
      try {
        // A file replacement, write or deletion invalidates display metadata.
        // This cache is never used to authorize a signature or installation.
        const stamp = await InstalledSigningExpiry.materialStamp(path);
        const key = path + '|' + stamp;
        let flight = InstalledSigningExpiry.materials.get(key);
        if (flight === undefined) {
          for (const old of InstalledSigningExpiry.materials.keys()) {
            if (old.startsWith(path + '|')) InstalledSigningExpiry.materials.delete(old);
          }
          flight = InstalledSigningExpiry.inspectMaterial(path, stamp).catch(() => undefined);
          InstalledSigningExpiry.materials.set(key, flight);
          if (InstalledSigningExpiry.materials.size > 200) {
            InstalledSigningExpiry.materials.delete(Array.from(InstalledSigningExpiry.materials.keys())[0]);
          }
        }
        const material = await flight;
        if (!active()) return [];
        if (material === undefined) { InstalledSigningExpiry.materials.delete(key); continue; }
        if (wanted.has(material.bundleName) || fingerprints.has(material.fingerprint)) result.push(material);
      } catch (_) {
        // Missing/unreadable files cannot supply an estimated deadline.
        for (const key of InstalledSigningExpiry.materials.keys()) {
          if (key.startsWith(path + '|')) InstalledSigningExpiry.materials.delete(key);
        }
      }
    }
    return result;
  }

  private static async materialStamp(path: string): Promise<string> {
    const stat = await fileIo.lstat(path);
    if (!stat.isFile() || stat.size <= 0 || stat.size > 4 * 1024 * 1024) throw new Error('Invalid Profile');
    return String(stat.ino) + ':' + stat.size + ':' + String(stat.mtimeNs ?? stat.mtime) + ':' +
      String(stat.ctimeNs ?? stat.ctime);
  }

  private static async inspectMaterial(path: string, stamp: string): Promise<SigningExpiryMaterial | undefined> {
    const digest = (await hash.hash(path, 'sha256')).toLowerCase();
    const data = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const bundle = data['bundle-info'] as Record<string, Object> | undefined;
    const validity = data['validity'] as Record<string, Object> | undefined;
    const before = Number(validity?.['not-before'] ?? 0), end = Number(validity?.['not-after'] ?? 0);
    const name = String(bundle?.['bundle-name'] ?? '');
    if (!name || !Number.isFinite(before) || before <= 0 || !Number.isFinite(end) || end <= before) return undefined;
    const fingerprint = await AgcProfile.signingFingerprint(path);
    const certificateExpiry = await InstalledSigningExpiry.certificateExpiry(String(bundle?.['development-certificate'] ?? ''));
    const expiry = Math.floor(Math.min(end, certificateExpiry));
    // Protect asynchronous reads from mixing two different file revisions.
    if (expiry <= before || !/^[A-Fa-f0-9]{64}$/.test(fingerprint) ||
      await InstalledSigningExpiry.materialStamp(path) !== stamp ||
      (await hash.hash(path, 'sha256')).toLowerCase() !== digest) return undefined;
    const material = new SigningExpiryMaterial();
    material.bundleName = name; material.fingerprint = fingerprint.toUpperCase();
    material.appIdentifier = String(bundle?.['app-identifier'] ?? '');
    material.notBefore = before; material.expiresAt = expiry;
    material.certificateExpiresAt = certificateExpiry; material.durationSeconds = end - before;
    return material;
  }

  static estimate(bundleName: string, versionCode: number, materials: SigningExpiryMaterial[], fallbackAt: number = 0): number {
    const current = InstalledSigningExpiry.current(bundleName) ?? InstalledAppRegistry.signingIdentity(bundleName);
    if (current && current.versionCode !== versionCode) return 0;
    let baseline = current?.updateTime ?? 0;
    if (baseline <= 0) {
      try {
        const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
        const own = bundleManager.getBundleInfoForSelfSync(flags);
        const info = own.name === bundleName ? own : bundleManager.getBundleInfoSync(bundleName, flags);
        if (info.name !== bundleName || info.versionCode !== versionCode) return 0;
        baseline = info.updateTime || info.installTime;
      } catch (_) {}
    }
    if (baseline <= 0) baseline = InstalledAppRegistry.installationTime(bundleName, versionCode) || fallbackAt;
    if (!Number.isFinite(baseline) || baseline <= 0 || versionCode <= 0) return 0;
    const installedAt = baseline / 1000;
    const fingerprint = current?.fingerprint ?? '';
    const candidates = materials.filter((item: SigningExpiryMaterial) => item.bundleName === bundleName &&
      fingerprint.length === 64 && item.fingerprint === fingerprint && item.notBefore <= installedAt && item.expiresAt > installedAt &&
      (!(item.appIdentifier && current?.appIdentifier) || item.appIdentifier === current?.appIdentifier));
    // Different Profiles can use the same signing certificate. This remains an
    // estimate, never a verified expiry or a reason to schedule automatic renewal.
    if (candidates.length) {
      const closest = Math.max(...candidates.map((item: SigningExpiryMaterial) => item.notBefore));
      return Math.min(...candidates.filter((item: SigningExpiryMaterial) => item.notBefore === closest)
        .map((item: SigningExpiryMaterial) => item.expiresAt));
    }
    const sameCertificate = materials.filter((item: SigningExpiryMaterial) => fingerprint.length === 64 &&
      item.fingerprint === fingerprint && item.notBefore <= installedAt && item.certificateExpiresAt > installedAt);
    // Most common observed authorization length for this exact signing key;
    // ties choose the shorter interval. Never borrow a different account's cert.
    const durations = new Map<number, number>();
    for (const item of sameCertificate) {
      if (Number.isFinite(item.durationSeconds) && item.durationSeconds > 0)
        durations.set(item.durationSeconds, (durations.get(item.durationSeconds) ?? 0) + 1);
    }
    const duration = Array.from(durations.keys()).sort((a: number, b: number) =>
      (durations.get(b) ?? 0) - (durations.get(a) ?? 0) || a - b)[0] ?? InstalledSigningExpiry.DEFAULT_DURATION_SECONDS;
    const deadline = installedAt + duration;
    return Math.floor(sameCertificate.length ? Math.min(deadline,
      ...sameCertificate.map((item: SigningExpiryMaterial) => item.certificateExpiresAt)) : deadline);
  }

  /** The display deadline is shared by labels and ordering; it is not verified authorization. */
  static displayExpiry(expiry: number, estimate: number = 0, fallbackAt: number = 0): number {
    if (Number.isFinite(expiry) && expiry > 0) return expiry;
    if (Number.isFinite(estimate) && estimate > 0) return estimate;
    const baseline = Number.isFinite(fallbackAt) && fallbackAt > 0 ? fallbackAt : Date.now();
    return Math.floor(baseline / 1000) + InstalledSigningExpiry.DEFAULT_DURATION_SECONDS;
  }

  static label(expiry: number, estimate: number = 0, fallbackAt: number = 0): string {
    const exact = Number.isFinite(expiry) && expiry > 0;
    const date = new Date(InstalledSigningExpiry.displayExpiry(expiry, estimate, fallbackAt) * 1000);
    return (exact ? '到期 ' : '预计到期 ') + date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') +
      '-' + String(date.getDate()).padStart(2, '0');
  }
}
