import { FailureKind, InstallJob, InstallStage, RecoveryEvidence } from './InstallJob';
import { JobScheduler } from './JobScheduler';
import { JobStore } from './JobStore';
import { recoveryStage } from './RecoveryPlanner';

export class PackageIdentity {
  bundleName: string = '';
  versionCode: number = 0;
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

/// Platform implementations must verify each result before resolving. The
/// runner never treats a return from the signer or HDC as installation proof.
export interface JobRuntime {
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
    return JobScheduler.runExclusive(id, () => this.runLocked(id));
  }

  private async runLocked(id: string): Promise<InstallJob> {
    const job = await this.store.get(id);
    if (!job) throw new Error('安装任务不存在');
    try {
      if (job.cachePath.length === 0 || job.signedPath.length === 0) {
        const paths = await this.runtime.planPaths(job);
        if (paths.cachePath.length === 0 || paths.signedPath.length === 0 ||
          paths.cachePath === paths.signedPath) {
          throw new JobFailure(FailureKind.INTERNAL, '安装工作目录无效');
        }
        job.cachePath = paths.cachePath;
        job.signedPath = paths.signedPath;
        await this.store.save(job);
      }
      const evidence = await this.runtime.inspectEvidence(job);
      job.stage = recoveryStage(job, evidence);
      await this.store.save(job);
      if (job.stage === InstallStage.INSTALLED || job.stage === InstallStage.TERMINAL_ERROR) {
        return job;
      }

      if (job.stage === InstallStage.QUEUED) {
        await this.advance(job, InstallStage.DOWNLOADING);
        await this.runtime.downloadAndVerify(job);
        await this.advance(job, InstallStage.VERIFIED);
      }
      if (job.stage === InstallStage.VERIFIED) {
        const identity = await this.runtime.inspectPackage(job);
        if (identity.bundleName.length === 0 || identity.versionCode <= 0) {
          throw new JobFailure(FailureKind.INVALID_PACKAGE, '安装包缺少可用的应用身份');
        }
        job.bundleName = identity.bundleName;
        job.versionCode = identity.versionCode;
        job.moduleName = identity.moduleName;
        job.mainAbility = identity.mainAbility;
        await this.advance(job, InstallStage.PACKAGE_INSPECTED);
      }
      if (job.stage === InstallStage.PACKAGE_INSPECTED) {
        await this.runtime.ensureProfile(job);
        await this.advance(job, InstallStage.PROFILE_READY);
      }
      if (job.stage === InstallStage.PROFILE_READY) {
        await this.runtime.sign(job);
        await this.advance(job, InstallStage.SIGNED);
      }
      if (job.stage === InstallStage.SIGNED) {
        await this.runtime.verifySignature(job);
        await this.advance(job, InstallStage.SIGNATURE_VERIFIED);
      }
      if (job.stage === InstallStage.SIGNATURE_VERIFIED ||
        job.stage === InstallStage.WAITING_DEVICE) {
        if (!await this.runtime.ensureDevice()) {
          await this.advance(job, InstallStage.WAITING_DEVICE);
          return job;
        }
        await this.advance(job, InstallStage.INSTALLING);
      }
      if (job.stage === InstallStage.INSTALLING) {
        // After a timeout, inspect the real installed version before retrying.
        if (await this.runtime.installedVersion(job.bundleName) !== job.versionCode) {
          await this.runtime.install(job);
        }
        if (await this.runtime.installedVersion(job.bundleName) !== job.versionCode) {
          throw new JobFailure(FailureKind.DEVICE, '设备尚未确认安装结果');
        }
        await this.advance(job, InstallStage.INSTALLED);
      }
      return job;
    } catch (error) {
      const failure = error instanceof JobFailure ? error :
        new JobFailure(FailureKind.TRANSIENT, String(error));
      await this.store.recordFailure(job, failure.kind, failure.message);
      return job;
    }
  }

  private async advance(job: InstallJob, stage: InstallStage): Promise<void> {
    job.stage = stage;
    job.lastError = '';
    await this.store.save(job);
    this.onStage?.(stage);
  }
}
