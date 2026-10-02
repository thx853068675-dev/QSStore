import { ClassifiedFailure } from '../data/ServiceFailure';
import { StorageBudget } from './StorageBudget';
import { PackageArchive } from './PackageArchive';
import { LocalBundles } from './LocalBundles';
import { common } from '@kit.AbilityKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { hasSigningBlock, signHap, verifyHap } from 'libhap_core.so';
import { AgcProfile } from '../data/AgcProfile';
import { DeveloperAccount } from '../data/DeveloperAccount';
import { StoreClient } from '../data/StoreClient';
import { LocalSigningIdentity, SigningIdentityRecovery } from '../data/SigningIdentity';
import { AssetDownload } from './AssetDownload';
import { FailureKind, InstallJob, InstallStage, RecoveryEvidence } from './InstallJob';
import { JobFailure, JobPaths, JobRuntime, PackageIdentity } from './JobRunner';
import { JobStore } from './JobStore';
import { InstalledSigningIdentity } from './InstalledAppRegistry';
import { checkCatalogIdentity, inspectPackage, PackageInspectError, PackageIdentity as InspectedIdentity, requestedPermissions } from './PackageInspector';
import { JobCancellation } from './JobCancellation';
import { InstallTaskState } from './InstallTaskState';

// A concrete adapter must query the device after reconnecting. Installed
// version is the final proof; a successful HDC command alone is insufficient.
export interface NativeDeviceBridge {
  connected(): Promise<boolean>;
  udid(): Promise<string>;
  installedVersion(bundleName: string): Promise<number>;
  installedSigningIdentity(bundleName: string): Promise<InstalledSigningIdentity | undefined>;
  install(signedHapPath: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void>;
  uninstall(bundleName: string): Promise<void>;
  stageInstall(path: string, onProgress?: (phase: string, sent: number, total: number) => void): Promise<string>;
  installStaged(ticket: string, bundleName: string,
    onProgress?: (phase: string, sent: number, total: number) => void): Promise<void>;
  discardStaged(ticket: string): Promise<boolean>;
  installSelfAfterUninstall(signedHapPath: string): Promise<void>;
}

export class NativeJobRuntime implements JobRuntime {
  private context: common.UIAbilityContext;
  private store: JobStore;
  private account: DeveloperAccount | undefined;
  private device: NativeDeviceBridge;
  // These proofs live only for this runner invocation. A resumed job must
  // recheck its files, but the same private HAP need not be read twice here.
  private selectedPackagePath: string = '';
  private verifiedCachePath: string = '';
  private verifiedCacheSha256: string = '';
  private freshlySignedPath: string = '';
  private freshlySignedProfileSha256: string = '';

  constructor(context: common.UIAbilityContext, store: JobStore,
    account: DeveloperAccount | undefined, device: NativeDeviceBridge) {
    this.context = context;
    this.store = store;
    this.account = account;
    this.device = device;
  }

  private async packagePath(job: InstallJob): Promise<string> {
    if (!job.sourceUrl.includes('#qingqi-package=')) return job.cachePath;
    const entry = PackageArchive.selectedEntry(job.sourceUrl);
    if (!entry) return job.cachePath;
    if (this.selectedPackagePath.length > 0) return this.selectedPackagePath;
    const output = job.cachePath + '.package' + PackageArchive.extension(entry);
    this.selectedPackagePath = await PackageArchive.extractSelected(job.cachePath, entry, output);
    return this.selectedPackagePath;
  }

  private async packageIdentity(path: string): Promise<InspectedIdentity> {
    return path.endsWith('.app') ? PackageArchive.inspect(path) : inspectPackage(path);
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
    // The installed bundle is stronger completion evidence than a cached HAP.
    // Reopening an already completed local job need not hash and verify two
    // whole packages before it can show "installed".
    if (job.bundleName.length > 0 && job.versionCode > 0) {
      const local = LocalBundles.liveInstalledVersion(job.bundleName);
      if (local > 0) evidence.installedVersionCode = local;
      if (local === job.versionCode && job.bundleName === 'com.tonghongxiang.quietstart' &&
        job.signedPath.length > 0 && fileIo.accessSync(job.signedPath)) {
        try { await verifyHap(job.signedPath); }
        catch (_) { job.reinstallRequired = true; }
      }
      if (local === job.versionCode && !job.reinstallRequired) return evidence;
    }
    evidence.verifiedCache = await new AssetDownload(this.context, this.store)
      .verifiedFileExists(job);
    if (evidence.verifiedCache) this.rememberVerifiedCache(job);
    if (evidence.verifiedCache && this.usesOriginalInstaller(job)) {
      // 兼容旧版已签名制品。未签名制品以及已选本机证书的任务都必须走
      // 下方的 Profile、签名和恢复校验，不能把原包当成已签名。
      try {
        const original = await this.packageIdentity(await this.packagePath(job));
        evidence.verifiedSignature = original.bundleName === job.bundleName &&
          original.versionCode === job.versionCode;
        evidence.validProfile = evidence.verifiedSignature;
      } catch (_) {}
      if (evidence.verifiedSignature) {
        try { evidence.deviceConnected = await this.device.connected(); }
        catch (_) { evidence.deviceConnected = false; }
      }
      return evidence;
    }
    if (evidence.verifiedCache && this.account && job.profilePath.length > 0 &&
      job.deviceUdid.length > 0 &&
      fileIo.accessSync(job.profilePath)) {
      const identity = await SigningIdentityRecovery.forJob(this.context, this.account,
        job.signingCertId);
      if (identity) {
        const currentHash = (await hash.hash(job.profilePath, 'sha256')).toLowerCase();
        evidence.validProfile = currentHash === job.profileSha256 &&
          AgcProfile.valid(job.profilePath, job.bundleName, job.deviceUdid,
            identity.certificatePath,
            AgcProfile.effectiveAcls(await PackageArchive.permissions(await this.packagePath(job))));
        if (evidence.validProfile && LocalBundles.isSelfBundle(job.bundleName)) {
          evidence.validProfile = await this.profileMatchesInstalledInstaller(job.profilePath);
        }
        if (evidence.validProfile) await this.assertCompatibleUpdate(job);
      }
    }
    if (evidence.validProfile && job.signedProfileSha256 === job.profileSha256 &&
      job.signedPath.length > 0 && fileIo.accessSync(job.signedPath)) {
      try {
        await verifyHap(job.signedPath);
        const signed = await this.packageIdentity(job.signedPath);
        PackageArchive.release(job.signedPath);
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
      this.rememberVerifiedCache(job);
      return;
    }
    try {
      await new AssetDownload(this.context, this.store).downloadAndVerify(job, undefined, async () => {
        this.selectedPackagePath = '';
        const identity = await this.packageIdentity(await this.packagePath(job));
        checkCatalogIdentity(job.catalogBundleName, job.catalogVersionCode, identity);
      });
    } catch (error) {
      throw new JobFailure(error instanceof PackageInspectError ? FailureKind.INVALID_PACKAGE :
        (error as ClassifiedFailure).failureKind ?? FailureKind.NETWORK, String(error));
    }
    this.rememberVerifiedCache(job);
  }

  async inspectPackage(job: InstallJob): Promise<PackageIdentity> {
    try {
      const parsed = await this.packageIdentity(await this.packagePath(job));
      checkCatalogIdentity(job.catalogBundleName, job.catalogVersionCode, parsed);
      const result = new PackageIdentity();
      result.bundleName = parsed.bundleName;
      result.versionCode = parsed.versionCode;
      result.versionName = parsed.versionName;
      result.moduleName = parsed.moduleName;
      result.mainAbility = parsed.mainAbility;
      return result;
    } catch (error) {
      if (error instanceof PackageInspectError) {
        throw new JobFailure(FailureKind.INVALID_PACKAGE, error.message);
      }
      throw new JobFailure((error as ClassifiedFailure).failureKind ?? FailureKind.INVALID_PACKAGE, String(error));
    }
  }

  async ensureProfile(job: InstallJob): Promise<void> {
    JobCancellation.assertActive(job.id);
    if (LocalBundles.isSelfBundle(job.bundleName)) {
      await this.verifyOriginalInstaller(job);
      const installed = LocalBundles.selfSigningFingerprint();
      const appIdentifier = LocalBundles.selfAppIdentifier();
      if (!installed && !appIdentifier) {
        throw new JobFailure(FailureKind.ACCOUNT, '无法读取当前安装器的签名身份，已暂停更新以避免覆盖失败');
      }
      const identity = this.account ?
        job.allowDataLoss || this.unsignedInstallerAsset(job) ?
          await SigningIdentityRecovery.ensureForInstall(this.context, this.account) :
          await SigningIdentityRecovery.restore(this.context, this.account) : undefined;
      if (identity) {
        try {
          await this.ensureAccountProfile(job, identity);
          if (job.allowDataLoss || this.unsignedInstallerAsset(job) ||
            await this.profileMatchesInstalledInstaller(job.profilePath)) return;
        } catch (error) {
          if (job.allowDataLoss || this.unsignedInstallerAsset(job)) {
            throw error instanceof Error ? error : new Error(String(error));
          }
        }
      }
      if (job.allowDataLoss || this.unsignedInstallerAsset(job)) {
        throw new JobFailure(FailureKind.ACCOUNT,
          '未找到可用的本机签名身份，无法安全地准备安装器更新包');
      }
      // 已签名的旧版制品仍可沿用原签名；系统安装器负责最终核验。
      job.profilePath = '';
      job.profileSha256 = '';
      job.signedProfileSha256 = '';
      await this.store.save(job);
      return;
    }
    if (!this.account) throw new JobFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号');
    const identity = await SigningIdentityRecovery.ensureForInstall(this.context, this.account);
    JobCancellation.assertActive(job.id);
    await this.ensureAccountProfile(job, identity);
  }

  private async ensureAccountProfile(job: InstallJob, identity: LocalSigningIdentity): Promise<void> {
    if (!this.account) throw new JobFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号');
    JobCancellation.assertActive(job.id);
    let udid = '';
    try { udid = await this.device.udid(); }
    catch (_) { throw new JobFailure(FailureKind.DEVICE, '请重新连接无线调试后继续'); }
    if (udid.length === 0) {
      throw new JobFailure(FailureKind.DEVICE, '设备 UDID 尚未可用');
    }
    let selected = identity;
    let fingerprint = LocalBundles.isSelfBundle(job.bundleName) ?
      LocalBundles.selfSigningFingerprint() : '';
    try {
      const installed = await this.device.installedSigningIdentity(job.bundleName);
      if (installed?.fingerprint.length === 64) fingerprint = installed.fingerprint;
    } catch (_) { /* 身份查询失败时由系统安装器最终裁决。 */ }
    if (fingerprint.length === 64) {
      try {
        const matched = await SigningIdentityRecovery.matchingInstalledCertificate(
          this.context, this.account, fingerprint);
        if (matched) selected = matched;
      } catch (error) {
        // AGC 列表或下载失败是“未知”，不能当成找不到匹配证书。
        throw new JobFailure((error as ClassifiedFailure).failureKind ?? FailureKind.ACCOUNT,
          '暂时无法核实可复用证书，已暂停更新以保护应用数据：' + String(error));
      }
    }
    selected = await SigningIdentityRecovery.pinForJob(this.context, selected);
    job.signingCertId = selected.certId;
    job.profilePath = await AgcProfile.ensure(this.context, this.account, selected,
      job.bundleName, udid, await PackageArchive.permissions(await this.packagePath(job)));
    job.deviceUdid = udid;
    job.profileSha256 = (await hash.hash(job.profilePath, 'sha256')).toLowerCase();
    await this.store.save(job);
    await this.assertCompatibleUpdate(job);
  }

  private async assertCompatibleUpdate(job: InstallJob): Promise<void> {
    // 对外部侧载的旧版本也一样：本机证书可覆盖的条件是 appId（同证书）或
    // appIdentifier 相同。提前发现冲突，避免重签、传包后才卡在安装阶段。
    let installed: InstalledSigningIdentity | undefined;
    try { installed = await this.device.installedSigningIdentity(job.bundleName); }
    catch (_) { /* 无法读取时仍交给系统安装器作最终校验。 */ }
    if (installed === undefined && LocalBundles.isSelfBundle(job.bundleName)) {
      installed = new InstalledSigningIdentity();
      installed.fingerprint = LocalBundles.selfSigningFingerprint();
      installed.appIdentifier = LocalBundles.selfAppIdentifier();
    }
    if (installed !== undefined) {
      const candidateFingerprint = await AgcProfile.signingFingerprint(job.profilePath);
      const candidateIdentifier = AgcProfile.appIdentifier(job.profilePath);
      const sameCertificate = installed.fingerprint.length === 64 &&
        candidateFingerprint === installed.fingerprint;
      const sameApp = installed.appIdentifier.length > 0 &&
        candidateIdentifier.length > 0 && candidateIdentifier === installed.appIdentifier;
      if (!sameCertificate && !sameApp && !job.allowDataLoss) {
        throw new JobFailure(FailureKind.CONFIRMATION,
          '未找到可保留数据的签名身份。卸载旧版再安装会清除该应用的缓存和登录状态。');
      }
    }
  }

  async sign(job: InstallJob): Promise<void> {
    if (this.usesOriginalInstaller(job)) return;
    if (!this.account) throw new JobFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号');
    if (!this.cacheVerifiedInThisRun(job) &&
      !await new AssetDownload(this.context, this.store).verifiedFileExists(job)) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE, '原始 HAP 的 SHA-256 已改变');
    }
    const identity = await SigningIdentityRecovery.forJob(this.context, this.account,
      job.signingCertId);
    if (!identity || job.profilePath.length === 0 || job.profileSha256.length === 0 ||
      (await hash.hash(job.profilePath, 'sha256')).toLowerCase() !== job.profileSha256) {
      throw new JobFailure(FailureKind.ACCOUNT, '签名材料已改变，请重新准备设备授权');
    }
    const path = await this.packagePath(job);
    await StorageBudget.require(this.context.filesDir, PackageArchive.workingBytes(path));
    try {
      await signHap(path, job.signedPath, identity.privateKeyPath, identity.certificatePath, job.profilePath);
    } finally { PackageArchive.release(path); }
    // The native signer verifies the complete pending HAP before atomically
    // moving it to signedPath. Repeating verifyHap immediately is another full
    // package read; recovery in a later invocation still verifies normally.
    this.freshlySignedPath = job.signedPath;
    this.freshlySignedProfileSha256 = job.profileSha256;
    job.signedProfileSha256 = job.profileSha256;
    await this.store.save(job);
  }

  async verifySignature(job: InstallJob): Promise<void> {
    if (this.usesOriginalInstaller(job)) {
      await this.verifyOriginalInstaller(job);
      return;
    }
    if (this.freshlySignedPath !== job.signedPath ||
      this.freshlySignedProfileSha256 !== job.profileSha256) {
      await verifyHap(job.signedPath);
    }
    const signed = await this.packageIdentity(job.signedPath);
    PackageArchive.release(job.signedPath);
    if (signed.bundleName !== job.bundleName || signed.versionCode !== job.versionCode ||
      job.signedProfileSha256 !== job.profileSha256) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE, '签名包与原始 HAP 或设备授权不一致');
    }
  }

  private async verifyOriginalInstaller(job: InstallJob): Promise<void> {
    try {
      if (!this.cacheVerifiedInThisRun(job) &&
        !await new AssetDownload(this.context, this.store).verifiedFileExists(job)) {
        throw new Error('更新包的下载摘要已改变');
      }
      const original = await this.packageIdentity(await this.packagePath(job));
      if (original.bundleName !== job.bundleName || original.versionCode !== job.versionCode) {
        throw new Error('更新包的应用身份与目录不一致');
      }
    } catch (error) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE,
        '安装器更新包的内容或应用身份无效：' + String(error));
    }
  }

  private unsignedInstallerAsset(job: InstallJob): boolean {
    return !hasSigningBlock(job.cachePath);
  }

  private usesOriginalInstaller(job: InstallJob): boolean {
    return LocalBundles.isSelfBundle(job.bundleName) &&
      !job.allowDataLoss && !this.unsignedInstallerAsset(job) && job.profilePath.length === 0;
  }

  private async profileMatchesInstalledInstaller(path: string): Promise<boolean> {
    const installed = LocalBundles.selfSigningFingerprint();
    const appIdentifier = LocalBundles.selfAppIdentifier();
    // HarmonyOS 的更新和保留数据重装规则是 appId 或 appIdentifier 任一相同。
    // 同一证书且同包名可保持 appId；AGC 的 appIdentifier 相同也允许证书轮换。
    return (installed.length === 64 &&
      await AgcProfile.signingFingerprint(path) === installed) ||
      (appIdentifier.length > 0 && AgcProfile.appIdentifier(path) === appIdentifier);
  }

  private rememberVerifiedCache(job: InstallJob): void {
    this.verifiedCachePath = job.cachePath;
    this.verifiedCacheSha256 = job.expectedSha256;
  }

  private cacheVerifiedInThisRun(job: InstallJob): boolean {
    return this.verifiedCachePath.length > 0 &&
      this.verifiedCachePath === job.cachePath &&
      this.verifiedCacheSha256 === job.expectedSha256;
  }

  ensureDevice(): Promise<boolean> { return this.device.connected(); }

  async install(job: InstallJob): Promise<void> {
    JobCancellation.assertActive(job.id);
    // 排队期间本机可能已通过其他来源升级。用解析出的内部编号复核，
    // 在线更新不能因签名不兼容而误走卸载后降级的路线。
    if (job.appId > 0 && await this.installedVersion(job.bundleName) > job.versionCode) {
      throw new JobFailure(FailureKind.INVALID_PACKAGE, '所选版本低于已安装版本，无法降级安装');
    }
    if ((job.stagedTicket ?? '').length > 0) {
      if (!await this.device.discardStaged(job.stagedTicket)) {
        throw new JobFailure(FailureKind.DEVICE, '请连接无线调试，清理上次传输后继续安装');
      }
      job.stagedTicket = '';
      await this.store.save(job);
    }
    let replacing = false;
    let staged = '';
    const path = this.usesOriginalInstaller(job) ? job.cachePath : job.signedPath;
    if (job.allowDataLoss) {
      const installed = await this.device.installedSigningIdentity(job.bundleName);
      if (installed !== undefined) {
        const sameApprovedIdentity = installed.versionCode === job.approvedInstalledVersion &&
          installed.fingerprint === job.approvedInstalledFingerprint &&
          installed.appIdentifier === job.approvedInstalledAppIdentifier;
        if (!sameApprovedIdentity) {
          job.allowDataLoss = false;
          await this.store.save(job);
          throw new JobFailure(FailureKind.CONFIRMATION,
            '已安装应用的版本或签名身份发生变化，请重新确认是否清除数据');
        }
        if (job.profilePath.length > 0) {
          const sameCertificate = installed.fingerprint.length === 64 &&
            await AgcProfile.signingFingerprint(job.profilePath) === installed.fingerprint;
          const sameApp = installed.appIdentifier.length > 0 &&
            AgcProfile.appIdentifier(job.profilePath) === installed.appIdentifier;
          if (sameCertificate || sameApp) {
            job.allowDataLoss = false;
            await this.store.save(job);
          }
        }
      } else if (await this.device.installedVersion(job.bundleName) > 0) {
        throw new JobFailure(FailureKind.DEVICE,
          '无法核对已安装应用的签名身份，已暂停以避免误卸载');
      }
    }
    if (job.allowDataLoss) {
      JobCancellation.assertActive(job.id);
      if (LocalBundles.isSelfBundle(job.bundleName)) {
        // 卸载会结束本进程，预先把完整 HAP 放到设备临时目录并校验摘要，
        // 再由与本进程分离的设备 shell 完成卸载和安装。应用数据会随卸载清除，
        // 因而新进程没有旧任务日志，只能按设备实际版本重新建立状态。
        if (!this.account) throw new JobFailure(FailureKind.ACCOUNT,
          '请先登录华为开发者账号，备份签名身份后再重装安装器');
        const current = await SigningIdentityRecovery.load(this.context, this.account);
        if (!current) throw new JobFailure(FailureKind.ACCOUNT,
          '本机签名身份不可用，已停止自更新以免丢失私钥');
        await new StoreClient(this.context).publishSigningIdentity(current.certId,
          fileIo.readTextSync(current.privateKeyPath), this.account);
        JobCancellation.assertActive(job.id);
        await this.device.installSelfAfterUninstall(path);
        return;
      }
      if (await this.device.installedVersion(job.bundleName) > 0) {
        JobCancellation.assertActive(job.id);
        InstallTaskState.installProgress(job.id, 'transfer', 0, 0);
        try {
          staged = await this.device.stageInstall(path, (phase: string, sent: number, total: number): void =>
            InstallTaskState.installProgress(job.id, phase, sent, total));
        } catch (error) {
          if (!await this.device.connected()) throw new JobFailure(FailureKind.DEVICE,
            '预传包时无线调试已断开，旧应用仍保留，重连后继续');
          throw error as Error;
        }
        job.stagedTicket = staged;
        try {
          await this.store.save(job);
          JobCancellation.assertActive(job.id);
          // Large transfers can take minutes; consent must still refer to the same installed app.
          const current = await this.device.installedSigningIdentity(job.bundleName);
          if (!current || current.versionCode !== job.approvedInstalledVersion ||
            current.fingerprint !== job.approvedInstalledFingerprint ||
            current.appIdentifier !== job.approvedInstalledAppIdentifier) {
            job.allowDataLoss = false;
            await this.store.save(job);
            throw new JobFailure(FailureKind.CONFIRMATION,
              '传输期间已安装应用发生变化，请重新确认是否清除数据');
          }
          replacing = true;
        } catch (error) {
          if (await this.device.discardStaged(staged)) {
            job.stagedTicket = '';
            try { await this.store.save(job); } catch (_) {}
          }
          throw error as Error;
        }
      }
    }
    if (!replacing) JobCancellation.assertActive(job.id);
    try {
      const progress = (phase: string, sent: number, total: number): void =>
        InstallTaskState.installProgress(job.id, phase, sent, total);
      if (replacing) await this.device.installStaged(staged, job.bundleName, progress);
      else await this.device.install(path, progress);
      InstallTaskState.installProgress(job.id, 'verifying', 0, 0);
    }
    catch (error) {
      // 自更新可能先让 HDC 宿主断开，随后才把成功响应送回来。系统版本
      // 已经是目标版本时直接让 JobRunner 完成，不再要求用户重新配对。
      if (!job.reinstallRequired &&
        LocalBundles.liveInstalledVersion(job.bundleName) === job.versionCode) return;
      const reason = String(error);
      if (!job.allowDataLoss && /9568264/.test(reason)) {
        throw new JobFailure(FailureKind.CONFIRMATION,
          '系统拒绝覆盖安装：签名身份不一致。卸载旧版再安装会清除该应用的缓存和登录状态。');
      }
      if (!await this.device.connected()) {
        throw new JobFailure(FailureKind.DEVICE,
          '无线调试已断开，安装结果尚未确认：' + String(error));
      }
      throw new Error(String(error));
    } finally {
      if (staged.length > 0 && await this.device.discardStaged(staged)) {
        job.stagedTicket = '';
        try { await this.store.save(job); } catch (_) {}
      }
    }
  }

  async installedVersion(bundleName: string): Promise<number> {
    const local = LocalBundles.liveInstalledVersion(bundleName);
    if (LocalBundles.isKnown(local)) return local;
    try { return await this.device.installedVersion(bundleName); }
    catch (error) {
      if (!await this.device.connected()) {
        throw new JobFailure(FailureKind.DEVICE, '无线调试已断开，请重新连接后继续');
      }
      throw new Error(String(error));
    }
  }
}
