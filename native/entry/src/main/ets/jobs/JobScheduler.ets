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

  /**
   * 单个任务的墙钟上限。
   *
   * 安装链路里最慢的一步是「安装到设备」，它能挂多久不由我们决定：设备休眠、
   * 无线调试掉线、授权弹窗没人点，底层调用都可能一直不返回。没有上限时任务会
   * 永远停在「正在安装」，界面也就一直卡着。超时后按失败处理，交给用户决定是
   * 否重试 —— 不自动重跑，因为设备上可能已经装上了。
   */
  private static readonly DEFAULT_TIMEOUT_MS: number = 4 * 60 * 1000;
  /** 下载大包要更宽裕：4 分钟对慢网的大 HAP 不够。 */
  static readonly DOWNLOAD_TIMEOUT_MS: number = 12 * 60 * 1000;

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
   *
   * body 超时后调用方会收到失败，但 body 本身可能还在后台挂着（JS 里取消不掉一个
   * 已经发出去的底层调用）。那时它若再抛错就无人接收，所以先声明成已结束把它吞掉。
   */
  static async runExclusive<T>(jobId: string, body: () => Promise<T>,
    timeoutMs: number = JobScheduler.DEFAULT_TIMEOUT_MS): Promise<T> {
    if (JobScheduler.inFlight.has(jobId)) {
      throw new Error('该安装任务正在执行，未重复启动');
    }
    JobScheduler.inFlight.add(jobId);
    let finished = false;
    try {
      const work = body().then((value: T) => {
        if (!finished) return value;
        return new Promise<T>(() => {});
      }, (error: Object) => {
        // ArkTS 只允许抛 Error 实例，原始错误转成文案再抛
        if (!finished) throw new Error(String(error));
        return new Promise<T>(() => {});
      });
      const timeout = new Promise<T>((_resolve, reject) => {
        setTimeout(() => {
          if (finished) return;
          finished = true;
          reject(new Error('等待设备响应超时：请确认设备已连接无线调试，然后重试'));
        }, timeoutMs);
      });
      return await Promise.race([work, timeout]);
    } finally {
      finished = true;
      JobScheduler.inFlight.delete(jobId);
    }
  }

  /** 只跑下载与包解析这一段流水线，供已有的独立下载入口使用。 */
  static runDownload(context: common.UIAbilityContext, store: JobStore, job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    return JobScheduler.runExclusive(job.id, () =>
      DownloadJobs.runLocked(context, store, job, onProgress),
    JobScheduler.DOWNLOAD_TIMEOUT_MS);
  }
}
