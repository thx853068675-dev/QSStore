import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { InstallJob } from './InstallJob';
import { JobStore } from './JobStore';

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
        if (job.transferTaskId.length > 0) {
          try { await request.agent.remove(job.transferTaskId); } catch (_) {}
          job.transferTaskId = '';
        }
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
        if ((error as BusinessError).code !== 21900006) {
          throw new Error('无法重新接管后台下载：' + String(error));
        }
        job.transferTaskId = '';
        await this.store.save(job);
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
        redirect: true
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
    // Keep each candidate bounded and let the next one take over.
    const hardDeadline = Date.now() + 120000;
    let stallDeadline = Date.now() + 25000;
    let lastProcessed = 0;
    while (Date.now() < stallDeadline && Date.now() < hardDeadline) {
      info = await request.agent.show(task.tid);
      if (info.progress.processed > lastProcessed) {
        lastProcessed = info.progress.processed;
        stallDeadline = Math.min(Date.now() + 25000, hardDeadline);
      }
      if (onProgress && info.progress.sizes.length > 0) {
        onProgress(info.progress.processed, info.progress.sizes[0]);
      }
      if (info.progress.state === request.agent.State.COMPLETED) break;
      if (info.progress.state === request.agent.State.FAILED ||
        info.progress.state === request.agent.State.REMOVED) {
        throw new Error('附件下载失败：' + info.reason);
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 1000));
    }
    if (info.progress.state !== request.agent.State.COMPLETED) {
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
