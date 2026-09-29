import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { InstallJob } from './InstallJob';
import { JobStore } from './JobStore';

// A stalled source is abandoned and the next mirror takes over. This is the
// only bound on a single source: a large package on a slow link must be allowed
// to run as long as bytes keep arriving, so there is deliberately no cap on the
// total transfer time.
const STALL_TIMEOUT_MS = 60000;
const POLL_INTERVAL_MS = 1000;

// The system transfer agent owns the partial download. Its task ID is stored
// before start(), so a process restart can reattach instead of starting over.
export class AssetDownload {
  private context: common.UIAbilityContext;
  private store: JobStore;

  constructor(context: common.UIAbilityContext, store: JobStore) {
    this.context = context;
    this.store = store;
  }

  planPaths(job: InstallJob): void {
    const dir = this.context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const stem = job.appId + '-' + job.expectedSha256;
    job.cachePath = dir + '/' + stem + '.hap';
    job.signedPath = dir + '/' + stem + '.signed.hap';
  }

  async verifiedFileExists(job: InstallJob): Promise<boolean> {
    if (job.cachePath.length === 0 || !fileIo.accessSync(job.cachePath)) {
      return false;
    }
    return (await hash.hash(job.cachePath, 'sha256')).toLowerCase() === job.expectedSha256;
  }

  // Abandons this job's transfer agent task and drops the stale ID. A task that
  // is still live has to be paused before the agent will let it go.
  async discardTransfer(job: InstallJob): Promise<void> {
    const tid = job.transferTaskId;
    job.transferTaskId = '';
    if (tid.length === 0) return;
    try {
      const stale = await request.agent.getTask(this.context, tid);
      const state = (await request.agent.show(tid)).progress.state;
      if (state === request.agent.State.RUNNING || state === request.agent.State.WAITING ||
        state === request.agent.State.RETRYING || state === request.agent.State.INITIALIZED) {
        await stale.pause();
      }
    } catch (_) {}
    try { await request.agent.remove(tid); } catch (_) {}
    await this.store.save(job);
  }

  async downloadAndVerify(job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    if (!/^https:\/\//.test(job.sourceUrl) || !/^[0-9a-f]{64}$/.test(job.expectedSha256)) {
      throw new Error('下载地址或可信摘要无效');
    }
    if (job.cachePath.length === 0) {
      this.planPaths(job);
      await this.store.save(job);
    }
    if (await this.verifiedFileExists(job)) return;

    const candidates = [job.sourceUrl, ...job.mirrorUrls].filter((url: string,
      index: number, urls: string[]) => /^https:\/\//.test(url) && urls.indexOf(url) === index);
    let lastError = '';
    for (let i = 0; i < candidates.length; i++) {
      try {
        await this.downloadCurrentSource(job, onProgress);
        return;
      } catch (error) {
        lastError = String(error);
        if (i + 1 >= candidates.length) break;
        // A background task belongs to one URL. Never append its partial file
        // to a different mirror, even when they advertise the same filename.
        await this.discardTransfer(job);
        const partPath = job.cachePath + '.part';
        if (fileIo.accessSync(partPath)) fileIo.unlinkSync(partPath);
        job.sourceUrl = candidates[i + 1];
        job.mirrorUrls = [...candidates.slice(i + 2), ...candidates.slice(0, i + 1)];
        await this.store.save(job);
      }
    }
    throw new Error('所有下载地址均失败：' + lastError);
  }

  private async downloadCurrentSource(job: InstallJob,
    onProgress?: (received: number, total: number) => void): Promise<void> {
    const partPath = job.cachePath + '.part';
    let task: request.agent.Task | undefined;
    if (job.transferTaskId.length > 0) {
      try {
        task = await request.agent.getTask(this.context, job.transferTaskId);
      } catch (error) {
        // The recorded task is gone (21900006) or cannot be read; either way the
        // ID is stale, so it must not be reused for a different URL later.
        await this.discardTransfer(job);
        if ((error as BusinessError).code !== 21900006) {
          throw new Error('无法重新接管后台下载：' + String(error));
        }
      }
      if (task && (task.config.url !== job.sourceUrl || task.config.saveas !== partPath)) {
        throw new Error('下载任务身份与安装任务不匹配');
      }
    }
    if (!task) {
      // A partial file without its system task cannot be trusted for append.
      // The full SHA-256 is checked before this file is ever used for signing.
      if (fileIo.accessSync(partPath)) {
        const partialHash = (await hash.hash(partPath, 'sha256')).toLowerCase();
        if (partialHash === job.expectedSha256) {
          if (fileIo.accessSync(job.cachePath)) fileIo.unlinkSync(job.cachePath);
          fileIo.renameSync(partPath, job.cachePath);
          return;
        }
        fileIo.unlinkSync(partPath);
      }
      task = await request.agent.create(this.context, {
        action: request.agent.Action.DOWNLOAD,
        url: job.sourceUrl,
        mode: request.agent.Mode.BACKGROUND,
        saveas: partPath,
        overwrite: false,
        retry: true,
        redirect: true,
        // Only an idle connection is cut off; the transfer itself may take as
        // long as the link needs.
        timeout: { connectionTimeout: STALL_TIMEOUT_MS / 1000 }
      });
      job.transferTaskId = task.tid;
      await this.store.save(job);
    }

    let info = await request.agent.show(task.tid);
    if (info.progress.state === request.agent.State.INITIALIZED ||
      info.progress.state === request.agent.State.FAILED ||
      info.progress.state === request.agent.State.PAUSED ||
      info.progress.state === request.agent.State.STOPPED) {
      await task.start();
    }
    // Direct GitHub often stalls on the device while a mirror is reachable.
    // A source is abandoned after STALL_TIMEOUT_MS without a single new byte;
    // a slow but live transfer is never interrupted for taking too long.
    let lastProcessed = 0;
    let lastGrowthAt = Date.now();
    let carriedBytes = 0;
    let carriedTotal = info.progress.sizes.length > 0 ? info.progress.sizes[0] : 0;
    while (Date.now() - lastGrowthAt < STALL_TIMEOUT_MS) {
      info = await request.agent.show(task.tid);
      if (info.progress.processed > lastProcessed) {
        lastProcessed = info.progress.processed;
        lastGrowthAt = Date.now();
      }
      if (onProgress && info.progress.sizes.length > 0) {
        carriedTotal = info.progress.sizes[0];
        onProgress(carriedBytes + info.progress.processed, carriedTotal);
      }
      if (info.progress.state === request.agent.State.COMPLETED) break;
      if (info.progress.state === request.agent.State.FAILED ||
        info.progress.state === request.agent.State.REMOVED) {
        throw new Error('附件下载失败：' + info.reason);
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, POLL_INTERVAL_MS));
    }
    if (info.progress.state !== request.agent.State.COMPLETED) {
      // Leave the partial file in place for the next mirror, but stop the agent
      // from competing with it for bandwidth.
      await this.discardTransfer(job);
      throw new Error('下载连接停滞，可稍后继续');
    }
    if (!fileIo.accessSync(partPath)) throw new Error('下载完成但附件不存在');
    const actual = (await hash.hash(partPath, 'sha256')).toLowerCase();
    if (actual !== job.expectedSha256) {
      await request.agent.remove(task.tid);
      job.transferTaskId = '';
      await this.store.save(job);
      fileIo.unlinkSync(partPath);
      throw new Error('附件 SHA-256 与商店记录不一致');
    }
    if (fileIo.accessSync(job.cachePath)) fileIo.unlinkSync(job.cachePath);
    fileIo.renameSync(partPath, job.cachePath);
    await request.agent.remove(task.tid);
    job.transferTaskId = '';
    await this.store.save(job);
  }
}
