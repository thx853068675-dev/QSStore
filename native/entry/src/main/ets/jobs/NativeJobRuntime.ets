import { common } from '@kit.AbilityKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { signHap, verifyHap } from 'libhap_core.so';
import { AgcProfile } from '../data/AgcProfile';
import { DeveloperAccount } from '../data/DeveloperAccount';
import { SigningIdentityRecovery } from '../data/SigningIdentity';
import { AssetDownload } from './AssetDownload';
import { FailureKind, InstallJob, InstallStage, RecoveryEvidence } from './InstallJob';
import { JobFailure, JobPaths, JobRuntime, PackageIdentity } from './JobRunner';
import { JobStore } from './JobStore';
import { inspectPackage, requestedPermissions } from './PackageInspector';

// A concrete adapter must query the device after reconnecting. Installed
// version is the final proof; a successful HDC command alone is insufficient.
export interface NativeDeviceBridge {
  connected(): Promise<boolean>;
  udid(): Promise<string>;
  installedVersion(bundleName: string): Promise<number>;
  install(signedHapPath: string): Promise<void>;
}

export class NativeJobRuntime implements JobRuntime {
  private context: common.UIAbilityContext;
  private store: JobStore;
  private account: DeveloperAccount | undefined;
  private device: NativeDeviceBridge;

  constructor(context: common.UIAbilityContext, store: JobStore,
    account: DeveloperAccount | undefined, device: NativeDeviceBridge) {
    this.context = context;
    this.store = store;
    this.account = account;
    this.device = device;
  }

  async planPaths(job: InstallJob): Promise<JobPaths> {
    new AssetDownload(this.context, this.store).planPaths(job);
    const paths = new JobPaths();
    paths.cachePath = job.cachePath;
    paths.signedPath = job.signedPath;
    return paths;
  }

  async inspectEvidence(job: InstallJob): Promise<RecoveryEvidence> {
    const evidence = new RecoveryEvidence();
    evidence.verifiedCache = await new AssetDownload(this.context, this.store)
      .verifiedFileExists(job);
    if (evidence.verifiedCache && this.account && job.profilePath.length > 0 &&
      job.deviceUdid.length > 0 &&
      fileIo.accessSync(job.profilePath)) {
      const identity = await SigningIdentityRecovery.load(this.context, this.account);
      if (identity) {
        const currentHash = (await hash.hash(job.profilePath, 'sha256')).toLowerCase();
        evidence.validProfile = currentHash === job.profileSha256 &&
          AgcProfile.valid(job.profilePath, job.bundleName, job.deviceUdid,
            identity.certificatePath,
            AgcProfile.effectiveAcls(requestedPermissions(job.cachePath)));
      }
    }
    if (evidence.validProfile && job.signedProfileSha256 === job.profileSha256 &&
      job.signedPath.length > 0 && fileIo.accessSync(job.signedPath)) {
      try {
        await verifyHap(job.signedPath);
        const signed = inspectPackage(job.signedPath);
        evidence.verifiedSignature = signed.bundleName === job.bundleName &&
          signed.versionCode === job.versionCode;
      } catch (_) {}
    }
    if (evidence.verifiedSignature || job.stage === InstallStage.INSTALLING ||
      job.stage === InstallStage.INSTALLED) {
      try {
        evidence.deviceConnected = await this.device.connected();
        if (evidence.deviceConnected && job.bundleName.length > 0) {
          evidence.installedVersionCode = await this.device.installedVersion(job.bundleName);
        }
      } catch (_) {
        evidence.deviceConnected = false;
      }
    }
    return evidence;
  }

  async downloadAndVerify(job: InstallJob): Promise<void> {
    if (job.sourceUrl === 'local') {
      if (!await new AssetDownload(this.context, this.store).verifiedFileExists(job)) {
        throw new JobFailure(FailureKind.INVALID_PACKAGE, '本地 HAP 完整性已改变');
      }
      return;
    }
    await new AssetDownload(this.context, this.store).downloadAndVerify(job);
  }

  async inspectPackage(job: InstallJob): Promise<PackageIdentity> {
    const parsed = inspectPackage(job.cachePath);
    const result = new PackageIdentity();
    result.bundleName = parsed.bundleName;
    result.versionCode = parsed.versionCode;
    result.moduleName = parsed.moduleName;
    result.mainAbility = parsed.mainAbility;
    return result;
  }

  async ensureProfile(job: InstallJob): Promise<void> {
    if (!this.account) throw new JobFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号');
    const identity = await SigningIdentityRecovery.restore(this.context, this.account);
    if (!identity) {
      throw new JobFailure(FailureKind.ACCOUNT, '账号没有可复用的调试证书');
    }
    let udid = '';
    try { udid = await this.device.udid(); }
    catch (_) { throw new JobFailure(FailureKind.DEVICE, '请重新连接无线调试后继续'); }
    if (udid.length === 0) {
      throw new JobFailure(FailureKind.DEVICE, '设备 UDID 尚未可用');
    }
    job.profilePath = await AgcProfile.ensure(this.context, this.account, identity,
      job.bundleName, udid, requestedPermissions(job.cachePath));
    job.deviceUdid = udid;
    job.profileSha256 = (await hash.hash(job.profilePath, 'sha256')).toLowerCase();
    await this.store.save(job);
  }

  async sign(job: InstallJob): Promise<void> {
    if (!this.account) throw new JobFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号');
    if (!await new AssetDownload(this.context, this.store).verifiedFileExists(job)) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE, '原始 HAP 的 SHA-256 已改变');
    }
    const identity = await SigningIdentityRecovery.load(this.context, this.account);
    if (!identity || job.profilePath.length === 0 || job.profileSha256.length === 0 ||
      (await hash.hash(job.profilePath, 'sha256')).toLowerCase() !== job.profileSha256) {
      throw new JobFailure(FailureKind.ACCOUNT, '签名材料已改变，请重新准备设备授权');
    }
    await signHap(job.cachePath, job.signedPath, identity.privateKeyPath,
      identity.certificatePath, job.profilePath);
    job.signedProfileSha256 = job.profileSha256;
    await this.store.save(job);
  }

  async verifySignature(job: InstallJob): Promise<void> {
    await verifyHap(job.signedPath);
    const signed = inspectPackage(job.signedPath);
    if (signed.bundleName !== job.bundleName || signed.versionCode !== job.versionCode ||
      job.signedProfileSha256 !== job.profileSha256) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE, '签名包与原始 HAP 或设备授权不一致');
    }
  }

  ensureDevice(): Promise<boolean> { return this.device.connected(); }

  async install(job: InstallJob): Promise<void> {
    try { await this.device.install(job.signedPath); }
    catch (error) {
      if (!await this.device.connected()) {
        throw new JobFailure(FailureKind.DEVICE, '无线调试已断开，请重新连接后继续');
      }
      throw new Error(String(error));
    }
  }

  async installedVersion(bundleName: string): Promise<number> {
    try { return await this.device.installedVersion(bundleName); }
    catch (error) {
      if (!await this.device.connected()) {
        throw new JobFailure(FailureKind.DEVICE, '无线调试已断开，请重新连接后继续');
      }
      throw new Error(String(error));
    }
  }
}
