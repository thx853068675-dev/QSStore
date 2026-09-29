import { common } from '@kit.AbilityKit';
import { DownloadJobs } from './DownloadJobs';
import { InstallJob } from './InstallJob';
import { JobStore } from './JobStore';

/**
 * 同一安装任务的唯一互斥点。
 *
 * 页面上的 activeJobId / activeInstallId 只是「本页正在忙」的显示状态：详情页和
 * 发现页各有一份，各自都能通过自己的检查，于是同一个任务会被两个页面（或同一页面
 * 的两次点击）同时跑一遍——授权准备、签名、安装各做两次。
 *
 * 因此互斥放在这里：进程内按任务 ID 去重，覆盖「下载」「签名+安装」以及它们的组合，
 * 页面只负责调用，不再自己充当锁。
 */
export class JobScheduler {
  private static inFlight: Set<string> = new Set<string>();

  static isRunning(jobId: string): boolean {
    return JobScheduler.inFlight.has(jobId);
  }

  /** 正在执行的任务 ID，供界面显示（同一时刻通常只有一个）。 */
  static runningJobIds(): string[] {
    return Array.from(JobScheduler.inFlight);
  }

  /**
   * 独占执行 body。已有同 ID 任务在跑时直接抛错，不排队：排队会让第二次调用在第一次
   * 结束后重跑整条流水线，等于重复安装。
   */
  static async runExclusive<T>(jobId: string, body: () => Promise<T>): Promise<T> {
    if (JobScheduler.inFlight.has(jobId)) {
      throw new Error('该安装任务正在执行，未重复启动');
    }
    JobScheduler.inFlight.add(jobId);
    try {
      return await body();
    } finally {
      JobScheduler.inFlight.delete(jobId);
    }
  }

  /** 只跑下载与包解析这一段流水线，供已有的独立下载入口使用。 */
  static runDownload(context: common.UIAbilityContext, store: JobStore, job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    return JobScheduler.runExclusive(job.id, () =>
      DownloadJobs.runLocked(context, store, job, onProgress));
  }
}
