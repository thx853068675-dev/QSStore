import { InstallTaskState } from './InstallTaskState';
import { InstallReconnect } from './InstallReconnect';
import { InstallConfirmation } from './InstallConfirmation';
import { common } from '@kit.AbilityKit';
import { DownloadJobs } from './DownloadJobs';
import { InstallJob } from './InstallJob';
import { JobStore } from './JobStore';
import { JobCancellation } from './JobCancellation';
import { BackgroundInstallTask } from './BackgroundInstallTask';

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
  private static serial: Promise<void> = Promise.resolve();
  private static reserved: Set<string> = new Set<string>();
  private static inFlight: Set<string> = new Set<string>();
  private static queueWakeup: (() => void) | undefined = undefined;

  static setQueueWakeup(handler: (() => void) | undefined): void {
    JobScheduler.queueWakeup = handler;
  }

  /** Detail submits to the same FIFO dispatcher as Discover and local imports. */
  static requestQueue(): boolean {
    if (JobScheduler.queueWakeup === undefined) return false;
    JobScheduler.queueWakeup();
    return true;
  }
  /** 已超时、但旧执行仍在后台收尾的任务。这些任务的锁还没放。 */
  private static timedOut: Set<string> = new Set<string>();
  private static cleanup: Map<string, () => Promise<void>> = new Map();
  private static cancelWaiters: Map<string, () => void> = new Map();

  static async cancel(context: common.UIAbilityContext, store: JobStore, job: InstallJob): Promise<void> {
    const running = JobScheduler.isRunning(job.id);
    InstallReconnect.clear(job.id);
    InstallConfirmation.clear(job.id);
    const marking = store.cancel(job);
    const clean = async (): Promise<void> => {
      await marking;
      await store.cleanupCancelled(context, job.id);
    };
    if (running) JobScheduler.cleanup.set(job.id, clean);
    await marking;
    JobScheduler.cancelWaiters.get(job.id)?.();
    await store.stopTransfer(context, job);
    if (!running) {
      await clean();
      JobCancellation.clear(job.id);
    }
  }

  /**
   * 单个任务的执行预算；进程被系统挂起的时间不算设备无响应。
   *
   * 安装链路里最慢的一步是「安装到设备」，它能挂多久不由我们决定：设备休眠、
   * 无线调试掉线、授权弹窗没人点，底层调用都可能一直不返回。没有上限时任务会
   * 永远停在「正在安装」，界面也就一直卡着。超时后按失败处理，交给用户决定是
   * 否重试 —— 不自动重跑，因为设备上可能已经装上了。
   */
  private static readonly DEFAULT_TIMEOUT_MS: number = 4 * 60 * 1000;
  /** 下载大包要更宽裕：4 分钟对慢网的大 HAP 不够。 */
  static readonly DOWNLOAD_TIMEOUT_MS: number = 12 * 60 * 1000;
  /**
   * 「签名 + 安装到设备」这一段的上限。
   *
   * **必须大于底层 `hdc install` 自己的预算（300 秒）**，否则外层先放弃：连接被
   * 丢掉之后，设备上即使装成功了也收不到结果，用户只看到超时。自己更新自己时
   * 设备要先停掉旧进程，这一步本来就更慢。
   */
  static readonly INSTALL_TIMEOUT_MS: number = 6 * 60 * 1000;

  static isRunning(jobId: string): boolean {
    return JobScheduler.inFlight.has(jobId) || JobScheduler.reserved.has(jobId);
  }

  /**
   * 任务是否已经超时但仍在收尾。
   *
   * 界面用它在超时提示上补一句「本次仍在收尾」——否则用户会以为可以立刻重试，
   * 点了却收到「正在执行」，看起来像卡住了。
   */
  static stillFinishing(jobId: string): boolean {
    return JobScheduler.timedOut.has(jobId);
  }

  /** 正在执行的任务 ID，供界面显示（同一时刻通常只有一个）。 */
  static runningJobIds(): string[] {
    return Array.from(JobScheduler.inFlight);
  }

  /** 超时结束界面等待；互斥一直保留到实际执行退出。 */
  static async runExclusive<T>(jobId: string, body: () => Promise<T>,
    timeoutMs: number = JobScheduler.DEFAULT_TIMEOUT_MS): Promise<T> {
    if (JobScheduler.reserved.has(jobId) || JobScheduler.inFlight.has(jobId)) {
      throw new Error(JobScheduler.stillFinishing(jobId) ?
        '上一次执行仍在收尾，请稍候再试' : '该安装任务正在执行，未重复启动');
    }
    const waiting = JobScheduler.inFlight.size > 0 || JobScheduler.reserved.size > 0;
    JobScheduler.reserved.add(jobId);
    const previous = JobScheduler.serial;
    let release: () => void = () => {};
    JobScheduler.serial = new Promise<void>((resolve: () => void) => { release = resolve; });
    if (waiting) await previous;
    JobScheduler.reserved.delete(jobId);
    JobScheduler.inFlight.add(jobId);
    InstallTaskState.setRunning(jobId, true);
    let timer: number = -1;
    // 放在微任务内调用，同步抛错也会经过 finally，避免留下永久锁。
    const work = Promise.resolve().then(async () => {
      JobCancellation.assertActive(jobId);
      await BackgroundInstallTask.acquire(jobId);
      JobCancellation.assertActive(jobId);
      return body();
    }).finally(async () => {
      if (timer >= 0) clearTimeout(timer);
      const clean = JobScheduler.cleanup.get(jobId);
      if (clean !== undefined) {
        try { await clean(); } catch (_) {}
        JobScheduler.cleanup.delete(jobId);
      }
      JobScheduler.inFlight.delete(jobId);
      JobScheduler.timedOut.delete(jobId);
      JobScheduler.cancelWaiters.delete(jobId);
      JobCancellation.clear(jobId);
      InstallTaskState.setRunning(jobId, false);
      // 超时或取消只结束界面等待，保活一直保留到真实执行和残留清理退出。
      try { await BackgroundInstallTask.release(jobId); }
      finally { release(); JobScheduler.requestQueue(); }
    });
    const timeout = new Promise<T>((_resolve, reject) => {
      let remaining = timeoutMs;
      let lastTick = Date.now();
      const tick = (): void => {
        if (JobCancellation.isCancelled(jobId)) return;
        const now = Date.now();
        const elapsed = Math.max(0, now - lastTick);
        lastTick = now;
        // 挂起后所有定时器会在回前台时集中触发；不能先超时再去读取已完成的下载。
        if (elapsed < 5000) remaining -= elapsed;
        if (remaining > 0) {
          timer = setTimeout(tick, Math.min(1000, remaining));
          return;
        }
        JobScheduler.timedOut.add(jobId);
        InstallTaskState.setRunning(jobId, true, true);
        reject(new Error('等待设备响应超时，本次执行仍在收尾，请勿重复安装'));
      };
      timer = setTimeout(tick, Math.min(1000, remaining));
    });
    const cancelled = new Promise<T>((_resolve, reject) => {
      JobScheduler.cancelWaiters.set(jobId, () => reject(new Error('安装任务已取消')));
    });
    return Promise.race([work, timeout, cancelled]);
  }

  /** 只跑下载与包解析这一段流水线，供已有的独立下载入口使用。 */
  static runDownload(context: common.UIAbilityContext, store: JobStore, job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    return JobScheduler.runExclusive(job.id, () =>
      DownloadJobs.runLocked(context, store, job, onProgress),
    JobScheduler.DOWNLOAD_TIMEOUT_MS);
  }

  /**
   * 跑完整的「签名 + 安装」流水线。
   *
   * 单独开一个入口是为了用 [INSTALL_TIMEOUT_MS]：默认的 4 分钟小于底层 `hdc install`
   * 自己的 5 分钟预算，会出现「外层已超时、底层还在装」的错位。
   */
  static runInstall<T>(jobId: string, body: () => Promise<T>): Promise<T> {
    return JobScheduler.runExclusive(jobId, body, JobScheduler.INSTALL_TIMEOUT_MS);
  }
}
