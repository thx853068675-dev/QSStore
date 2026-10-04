import { InstallTaskState } from './InstallTaskState';
import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { InstallJob } from './InstallJob';
import { JobCancellation } from './JobCancellation';
import { DownloadRoutes } from './DownloadRoutes';

// A stalled source is abandoned and the next mirror takes over. New transfers
// with alternatives also have a short startup budget. Once meaningful data has
// arrived, a large package on a slow link keeps running without a total-time cap.
const STALL_TIMEOUT_MS = 60000;
const POLL_INTERVAL_MS = 1000;
const INITIAL_CONNECTION_MS = 12000;
const INITIAL_SPEED_WINDOW_MS = 15000;
const INITIAL_MIN_BYTES = 512 * 1024;

export interface DownloadJournal {
  save(job: InstallJob): Promise<void>;
}

// The system transfer agent owns the partial download. Its task ID is stored
// before start(), so a process restart can reattach instead of starting over.
export class AssetDownload {
  private context: common.UIAbilityContext;
  private store: DownloadJournal;

  constructor(context: common.UIAbilityContext, store: DownloadJournal) {
    this.context = context;
    this.store = store;
  }

  planPaths(job: InstallJob): void {
    const dir = this.context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    // 没有商店摘要时使用一次性的短路径；任务记录会持久化该路径。
    const stem = job.appId + '-' + (job.expectedSha256.length > 0 ? job.expectedSha256 :
      'download-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 1000000));
    const extension = (job.assetName.toLowerCase().endsWith('.app') ? '.app' : '.hap');
    job.cachePath = dir + '/' + stem + extension;
    job.signedPath = dir + '/' + stem + '.signed' + extension;
  }

  async verifiedFileExists(job: InstallJob): Promise<boolean> {
    if (job.cachePath.length === 0 || !fileIo.accessSync(job.cachePath)) {
      return false;
    }
    if (!/^[0-9a-f]{64}$/.test(job.expectedSha256)) return false;
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
    onProgress?: (received: number, total: number) => void,
    validate?: () => Promise<void>): Promise<void> {
    if (!/^https:\/\//.test(job.sourceUrl)) {
      throw new Error('下载地址不是 HTTPS');
    }
    if (job.cachePath.length === 0) {
      this.planPaths(job);
      await this.store.save(job);
    }
    if (await this.verifiedFileExists(job)) {
      try { if (validate) await validate(); return; }
      catch (_) { await this.discardInvalidPackage(job); }
    }

    // 只调整新任务。已存在的系统任务继续接管，保留断点，不为重新排序整包重下。
    const vpn = job.transferTaskId.length === 0 && job.mirrorUrls.length > 0 &&
      await DownloadRoutes.vpnEnabled();
    const candidates = DownloadRoutes.order(job.sourceUrl, job.mirrorUrls, vpn);
    console.info('AssetDownload VPN: enabled=' + vpn + ' candidates=' + candidates.length);
    JobCancellation.assertActive(job.id);
    if (candidates.length > 0 && job.sourceUrl !== candidates[0]) {
      job.sourceUrl = candidates[0];
      job.mirrorUrls = candidates.slice(1);
      await this.store.save(job);
    }
    let lastError: Error = new Error('没有可用下载地址');
    for (let i = 0; i < candidates.length; i++) {
      JobCancellation.assertActive(job.id);
      let downloaded = false;
      try {
        await this.downloadCurrentSource(job, (received: number, total: number) => {
          InstallTaskState.downloadProgress(job.id, received, total);
          onProgress?.(received, total);
        }, i + 1 < candidates.length);
        downloaded = true;
        if (validate) await validate();
        return;
      } catch (error) {
        JobCancellation.assertActive(job.id);
        lastError = error as Error;
        if (downloaded) await this.discardInvalidPackage(job);
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
    throw lastError;
  }

  private async discardInvalidPackage(job: InstallJob): Promise<void> {
    await this.discardTransfer(job);
    for (const suffix of ['', '.part', '.package.hap', '.package.app']) {
      const path = job.cachePath + suffix;
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
    }
    // Actual digest belongs to this response, never to the next mirror.
    job.expectedSha256 = '';
    await this.store.save(job);
  }

  private async downloadCurrentSource(job: InstallJob,
    onProgress?: (received: number, total: number) => void,
    hasAlternative: boolean = false): Promise<void> {
    const partPath = job.cachePath + '.part';
    const startedAt = Date.now();
    let task: request.agent.Task | undefined;
    let resumed = false;
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
      resumed = task !== undefined;
    }
    if (!task) {
      // 没有系统任务 ID 就无法证明断点文件已完整，只在它与已知本机摘要
      // 完全相符时直接使用；否则从头下载，不把不完整文件交给签名器。
      if (fileIo.accessSync(partPath)) {
        const partialHash = (await hash.hash(partPath, 'sha256')).toLowerCase();
        if (job.expectedSha256.length > 0 && partialHash === job.expectedSha256) {
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
        metered: true,
        title: job.assetName,
        description: '下载应用安装包',
        gauge: true,
        saveas: partPath,
        overwrite: false,
        retry: true,
        redirect: true,
        // Only an idle connection is cut off; the transfer itself may take as
        // long as the link needs.
        timeout: { connectionTimeout: (hasAlternative ? INITIAL_CONNECTION_MS : STALL_TIMEOUT_MS) / 1000 }
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
    // Keep the full stall budget for established/resumed transfers. Fresh
    // connections can try another source sooner, without throwing away a
    // substantial partial package.
    let lastProcessed = 0;
    let lastGrowthAt = Date.now();
    let lastPollAt = lastGrowthAt;
    let speedWindowAt = lastGrowthAt;
    console.info('AssetDownload route: host=' + job.sourceUrl.split('/')[2] + ' resumed=' + resumed);
    let carriedBytes = 0;
    let carriedTotal = info.progress.sizes.length > 0 ? info.progress.sizes[0] : 0;
    for (;;) {
      JobCancellation.assertActive(job.id);
      info = await request.agent.show(task.tid);
      const now = Date.now();
      // 先读取系统任务再判断超时。进程被挂起时下载代理仍在工作，完成结果优先。
      if (now - lastPollAt >= STALL_TIMEOUT_MS) { lastGrowthAt = now; speedWindowAt = now; }
      lastPollAt = now;
      if (info.progress.processed > lastProcessed) {
        lastProcessed = info.progress.processed;
        lastGrowthAt = now;
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
      // 新连接没有收到数据时快速换源；已有断点和最后一条线路仍保留完整容错时间。
      if (hasAlternative && !resumed && (info.progress.state === request.agent.State.RUNNING ||
        info.progress.state === request.agent.State.RETRYING)) {
        if (lastProcessed === 0 && now - lastGrowthAt >= INITIAL_CONNECTION_MS) {
          throw new Error('下载线路连接超时，切换备用线路');
        }
        // 只放弃首段仍极慢的下载，避免已下载的大文件因短暂降速被从头重下。
        // 已下载至少四分之一的小包继续完成；大包首段低于约 32 KiB/s 时试下一条线路。
        const startupBytes = carriedTotal > 0 ? Math.min(INITIAL_MIN_BYTES, carriedTotal / 4) : INITIAL_MIN_BYTES;
        if (now - speedWindowAt >= INITIAL_SPEED_WINDOW_MS && lastProcessed < startupBytes) {
          throw new Error('下载线路初始速度过低，切换备用线路');
        }
      }
      if (now - lastGrowthAt >= STALL_TIMEOUT_MS) break;
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, POLL_INTERVAL_MS));
    }
    if (info.progress.state !== request.agent.State.COMPLETED) {
      // Leave the partial file in place for the next mirror, but stop the agent
      // from competing with it for bandwidth.
      await this.discardTransfer(job);
      throw new Error('下载连接停滞，可稍后继续');
    }
    if (!fileIo.accessSync(partPath)) throw new Error('下载完成但附件不存在');
    console.info('AssetDownload complete: host=' + job.sourceUrl.split('/')[2] +
      ' bytes=' + info.progress.processed + ' elapsedMs=' + (Date.now() - startedAt));
    // 商店元数据的 SHA-256 不参与安装准入；只记录实际下载内容的摘要，
    // 之后恢复任务时仍能发现本机缓存被替换或损坏。
    const actual = (await hash.hash(partPath, 'sha256')).toLowerCase();
    if (fileIo.accessSync(job.cachePath)) fileIo.unlinkSync(job.cachePath);
    fileIo.renameSync(partPath, job.cachePath);
    job.expectedSha256 = actual;
    await request.agent.remove(task.tid);
    job.transferTaskId = '';
    await this.store.save(job);
  }
}
