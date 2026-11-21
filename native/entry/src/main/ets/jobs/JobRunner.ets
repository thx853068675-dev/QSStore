import { FailureKind, InstallJob, InstallStage, RecoveryEvidence } from './InstallJob';
import { ClassifiedFailure } from '../data/ServiceFailure';
import { JobScheduler } from './JobScheduler';
import { JobStore } from './JobStore';
import { recoveryStage } from './RecoveryPlanner';
import { JobCancellation } from './JobCancellation';
import { I18n } from '../data/I18n';
import { InstallScheduling } from './InstallScheduling';

export class PackageIdentity {
  bundleName: string = '';
  versionCode: number = 0;
  versionName: string = '';
  moduleName: string = '';
  mainAbility: string = '';
}

export class JobPaths {
  cachePath: string = '';
  signedPath: string = '';
}

export class JobFailure extends Error {
  kind: FailureKind;

  constructor(kind: FailureKind, message: string) {
    super(message);
    this.kind = kind;
  }
}

/** A changed device can make queued work unnecessary; this is not an install failure. */
export class JobSkip extends Error {
  reason:string;
  constructor(reason:string,message:string){super(message);this.reason=reason;}
}

/// Platform implementations must verify each result before resolving. The
/// runner never treats a return from the signer or HDC as installation proof.
export interface JobRuntime {
  authorizationLane?(): string;
  planPaths(job: InstallJob): Promise<JobPaths>;
  inspectEvidence(job: InstallJob): Promise<RecoveryEvidence>;
  downloadAndVerify(job: InstallJob): Promise<void>;
  inspectPackage(job: InstallJob): Promise<PackageIdentity>;
  ensureProfile(job: InstallJob): Promise<void>;
  sign(job: InstallJob): Promise<void>;
  verifySignature(job: InstallJob): Promise<void>;
  ensureDevice(): Promise<boolean>;
  install(job: InstallJob): Promise<void>;
  installedVersion(bundleName: string): Promise<number>;
  confirmRenewal(job: InstallJob): Promise<boolean>;
  confirmReplacement?(job: InstallJob): Promise<boolean>;
  rememberInstalledAuthorization?(job: InstallJob): Promise<void>;
  preflight?(job:InstallJob,verified:boolean):Promise<string>;
}

export class JobRunner {
  private store: JobStore;
  private runtime: JobRuntime;
  private onStage?: (stage: InstallStage) => void;

  constructor(store: JobStore, runtime: JobRuntime,
    onStage?: (stage: InstallStage) => void) {
    this.store = store;
    this.runtime = runtime;
    this.onStage = onStage;
  }

  async run(id: string): Promise<InstallJob> {
    // 一个任务同一时刻只能有一条流水线在跑：页面自己的忙标记挡不住另一个页面。
    // Keep job ownership through all phases, without owning the target during download.
    const job = await this.store.get(id);
    if (!job) throw new Error(I18n.t('安装任务不存在'));
    return JobScheduler.runPipeline(job, () => this.runLocked(id));
  }

  private async runLocked(id: string): Promise<InstallJob> {
    const job = await this.store.get(id);
    if (!job) throw new Error(I18n.t('安装任务不存在'));
    try {
      if(job.stage===InstallStage.SKIPPED||job.stage===InstallStage.TERMINAL_ERROR)return job;
      // Only a confirmed same-package receipt can skip before bytes are inspected.
      if(job.stage===InstallStage.QUEUED&&await this.skipIfUnneeded(job,false))return job;
      if (job.cachePath.length === 0 || job.signedPath.length === 0) {
        const paths = await this.runtime.planPaths(job);
        if (paths.cachePath.length === 0 || paths.signedPath.length === 0 ||
          paths.cachePath === paths.signedPath) {
          throw new JobFailure(FailureKind.INTERNAL, I18n.t('安装工作目录无效'));
        }
        job.cachePath = paths.cachePath;
        job.signedPath = paths.signedPath;
        await this.store.save(job);
      }
      const evidence = await JobScheduler.resource(job, 'inspect', 2,
        () => this.runtime.inspectEvidence(job), I18n.t('等待安装包检查'));
      job.stage = recoveryStage(job, evidence);
      if (job.stage === InstallStage.INSTALLED) {
        this.clearDataLossApproval(job);
        job.reinstallRequired = false;
      }
      await this.store.save(job);
      if (job.stage === InstallStage.INSTALLED || job.stage === InstallStage.TERMINAL_ERROR) {
        return job;
      }

      if (job.stage === InstallStage.QUEUED) {
        await this.advance(job, InstallStage.DOWNLOADING);
        await JobScheduler.resource(job, InstallScheduling.local(job) ? 'inspect' : 'download', 2,
          () => this.runtime.downloadAndVerify(job), I18n.t('等待下载资源'));
        await this.advance(job, InstallStage.VERIFIED);
      }
      if (job.stage === InstallStage.VERIFIED) {
        const identity = await JobScheduler.resource(job, 'inspect', 2,
          () => this.runtime.inspectPackage(job), I18n.t('等待安装包检查'));
        if (identity.bundleName.length === 0 || identity.versionCode <= 0) {
          throw new JobFailure(FailureKind.INVALID_PACKAGE, I18n.t('安装包缺少可用的应用身份'));
        }
        job.bundleName = identity.bundleName;
        job.versionCode = identity.versionCode;
        if ((identity.versionName ?? '').length > 0) job.versionName = identity.versionName;
        job.moduleName = identity.moduleName;
        job.mainAbility = identity.mainAbility;
        await this.advance(job, InstallStage.PACKAGE_INSPECTED);
      }
      if(job.bundleName&&job.versionCode>0&&await this.skipIfUnneeded(job,true))return job;
      if (job.stage === InstallStage.PACKAGE_INSPECTED) {
        await JobScheduler.resource(job, 'authorization:' + (this.runtime.authorizationLane?.() ?? 'default'), 1,
          () => this.runtime.ensureProfile(job), I18n.t('等待账号授权'));
        await this.advance(job, InstallStage.PROFILE_READY);
      }
      if (job.stage === InstallStage.PROFILE_READY) {
        await JobScheduler.resource(job, 'signing', 1, () => this.runtime.sign(job), I18n.t('等待签名'));
        await this.advance(job, InstallStage.SIGNED);
      }
      if (job.stage === InstallStage.SIGNED) {
        await JobScheduler.resource(job, 'inspect', 2,
          () => this.runtime.verifySignature(job), I18n.t('等待安装包检查'));
        await this.advance(job, InstallStage.SIGNATURE_VERIFIED);
      }
      if ([InstallStage.SIGNATURE_VERIFIED, InstallStage.WAITING_DEVICE, InstallStage.INSTALLING].includes(job.stage)) {
        await JobScheduler.resource(job, 'device:' + InstallScheduling.device(job), 1,
          () => JobScheduler.resource(job, 'installing', 3,
            () => this.installReady(job), I18n.t('等待安装资源')), I18n.t('等待设备空闲'));
      }
      return job;
    } catch (error) {
      if (JobCancellation.isCancelled(id)) throw new Error('安装任务已取消');
      if(error instanceof JobSkip){
        job.skipReason=error.reason;this.clearDataLossApproval(job);
        await this.advance(job,InstallStage.SKIPPED);return job;
      }
      const failure = error instanceof JobFailure ? error :
        new JobFailure((error as ClassifiedFailure).failureKind ?? FailureKind.TRANSIENT, String(error));
      await this.store.recordFailure(job, failure.kind, failure.message);
      return job;
    }
  }

  private async installReady(job: InstallJob): Promise<void> {
    // The device can have changed while another origin used the install slot.
    if (await this.skipIfUnneeded(job, true)) return;
    if (job.stage === InstallStage.SIGNATURE_VERIFIED ||
      job.stage === InstallStage.WAITING_DEVICE) {
      if (!await this.runtime.ensureDevice()) {
        await this.advance(job, InstallStage.WAITING_DEVICE);
        return;
      }
      await this.advance(job, InstallStage.INSTALLING);
    }
    if (job.stage === InstallStage.INSTALLING) {
      // After a timeout, inspect the real installed version before retrying.
      let needsInstall = job.reinstallRequired;
      if (!needsInstall) {
        const current = await this.runtime.installedVersion(job.bundleName);
        needsInstall = current !== job.versionCode;
        if (!needsInstall && job.appId > 0 && !(job.catalogVersionCode > 0)) {
          // 未预处理的在线包到这里才知道内部编号，用户提交的安装仍必须执行。
          job.reinstallRequired = true;
          await this.store.save(job);
          needsInstall = true;
        }
      }
      if (needsInstall) {
        if(await this.skipIfUnneeded(job,true))return;
        JobCancellation.assertActive(job.id);
        await this.runtime.install(job);
      }
      // **等设备把新版本反映出来，而不是立刻重装。**
      // `hdc install` 返回后，设备的包管理器还要一点时间才更新版本信息；
      // 自己更新自己时（安装器更新安装器）旧进程还在跑，窗口更长。立刻查一次
      // 会读到旧版本号 → 判失败 → 再装一遍 → 还是旧版本 → 报「设备尚未确认
      // 安装结果」。用户看到的就是「卡在 95%，然后还得再点一次」。
      if (!await this.confirmInstalledVersion(job)) {
        // 版本仍旧并不等于无线调试断了。尤其安装器更新自己时，包管理器
        // 可能先完成安装、随后才结束旧进程；这时要求用户反复配对只会重装。
        throw new JobFailure(FailureKind.TRANSIENT,
          job.renewalRequestedAt > 0 ?
            (job.allowDataLoss ? I18n.t('重装续签已提交，但尚未确认新授权，请连接无线调试后继续核对') :
              I18n.t('续签已提交，但尚未确认授权替换结果。旧应用数据已保留，请连接无线调试后继续核对')) :
            I18n.t('安装已提交，但新版本尚未生效。请重新打开应用确认；若版本仍旧，再点继续安装'));
      }
      // Auxiliary expiry metadata must never turn a confirmed install into a retry.
      try { await this.runtime.rememberInstalledAuthorization?.(job); } catch (_) {}
      job.reinstallRequired = false;
      await this.advance(job, InstallStage.INSTALLED);
    }
  }

  private async skipIfUnneeded(job:InstallJob,verified:boolean):Promise<boolean>{
    const reason=await this.runtime.preflight?.(job,verified)??'';
    if(!reason)return false;
    job.skipReason=reason;this.clearDataLossApproval(job);
    await this.advance(job,InstallStage.SKIPPED);
    return true;
  }

  private async advance(job: InstallJob, stage: InstallStage): Promise<void> {
    job.stage = stage;
    if (stage === InstallStage.INSTALLED) this.clearDataLossApproval(job);
    job.lastError = '';
    await this.store.save(job);
    this.onStage?.(stage);
  }

  private clearDataLossApproval(job: InstallJob): void {
    job.allowDataLoss = false;
    job.approvedInstalledVersion = 0;
    job.approvedInstalledFingerprint = '';
    job.approvedInstalledAppIdentifier = '';
    job.approvedInstallProof = '';job.approvedInstalledUpdateTime = 0;
    job.forceInstall=false;job.conflictKind='';job.conflictState='';
  }

  /**
   * 轮询等待设备把新版本反映出来。
   *
   * `hdc install` 返回「安装成功」之后，设备的包管理器仍可能短暂返回旧版本号：
   * 安装是异步落盘的，自己更新自己时旧进程还在跑，窗口更长。只查一次就判定
   * 失败会导致「明明装好了却报没确认」，用户要再点一次。
   *
   * 先按 250/500/1000ms 检查，再退避到 [PROBE_INTERVAL_MS]，最多等
   * [PROBE_TOTAL_MS]；链路查询失败时保留原始失败类型，不把查询错误
   * 误报成「设备尚未确认」或盲目重新安装。
   */
  private static readonly PROBE_INTERVAL_MS: number = 1500;
  private static readonly PROBE_TOTAL_MS: number = 15000;

  private async confirmInstalledVersion(job: InstallJob): Promise<boolean> {
    const deadline = Date.now() + JobRunner.PROBE_TOTAL_MS;
    let interval = 250;
    let queryFailures = 0;
    for (;;) {
      JobCancellation.assertActive(job.id);
      let current = -1;
      let queryFailure: JobFailure | undefined;
      try {
        current = await this.runtime.installedVersion(job.bundleName);
      } catch (error) {
        queryFailure = error instanceof JobFailure ? error :
          new JobFailure(FailureKind.TRANSIENT, I18n.t('安装结果暂时无法核实：') + String(error));
        // 已提交后的短暂查询故障只重查结果，不重签、不重新传包。
        // 明确断连、身份或权限失败仍立即交给现有恢复入口。
        if (![FailureKind.TRANSIENT, FailureKind.NETWORK].includes(queryFailure.kind) ||
          ++queryFailures > 2 || Date.now() >= deadline) throw queryFailure;
      }
      if (current === job.versionCode) {
        const confirmed = job.renewalRequestedAt > 0 ? await this.runtime.confirmRenewal(job) :
          (job.appId > 0 && job.reinstallRequired ? await this.runtime.confirmReplacement?.(job) ?? false : true);
        if (confirmed) return true;
      }
      if (Date.now() >= deadline) {
        if (queryFailure !== undefined) throw queryFailure;
        return false;
      }
      await new Promise<void>((resolve) =>
        setTimeout(resolve, Math.min(interval, Math.max(0, deadline - Date.now()))));
      interval = Math.min(interval * 2, JobRunner.PROBE_INTERVAL_MS);
    }
  }
}
