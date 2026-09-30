import { InstallJob, InstallStage } from './InstallJob';

/** 进程内的任务视图：阶段来自已落盘记录，进度来自下载器，执行状态来自调度器。 */
export class InstallTaskSnapshot {
  job: InstallJob = new InstallJob();
  running: boolean = false;
  finishing: boolean = false;
  percent: number = 0;
}

export class InstallTaskState {
  private static tasks: Map<string, InstallTaskSnapshot> = new Map();
  private static running: Set<string> = new Set();
  private static finishing: Set<string> = new Set();
  private static removed: Set<string> = new Set();
  private static listeners: Map<number, (rows: InstallTaskSnapshot[]) => void> = new Map();
  private static nextListener: number = 0;

  static snapshot(): InstallTaskSnapshot[] {
    return Array.from(InstallTaskState.tasks.values()).sort((a, b) => b.job.updatedAt - a.job.updatedAt);
  }

  static subscribe(listener: (rows: InstallTaskSnapshot[]) => void): number {
    const id = ++InstallTaskState.nextListener;
    InstallTaskState.listeners.set(id, listener);
    listener(InstallTaskState.snapshot());
    return id;
  }

  static unsubscribe(id: number): void {
    InstallTaskState.listeners.delete(id);
  }

  private static emit(): void {
    const rows = InstallTaskState.snapshot();
    InstallTaskState.listeners.forEach((listener: (rows: InstallTaskSnapshot[]) => void) => {
      // 页面被销毁或渲染失败不能中断任务流水线。
      try { listener(rows); } catch (_) {}
    });
  }

  /** 启动时恢复快照，慢查询不能覆盖期间的进度、阶段或删除。 */
  static seed(jobs: InstallJob[]): void {
    for (const job of jobs) {
      if (!InstallTaskState.tasks.has(job.id) && !InstallTaskState.removed.has(job.id)) {
        InstallTaskState.tasks.set(job.id, InstallTaskState.make(job));
      }
    }
    InstallTaskState.emit();
  }

  private static make(job: InstallJob): InstallTaskSnapshot {
    const row = new InstallTaskSnapshot();
    // 与运行器持有的可变对象隔离；页面拿到的阶段只会在 save 成功后改变。
    row.job = JSON.parse(JSON.stringify(job)) as InstallJob;
    row.running = InstallTaskState.running.has(job.id);
    row.finishing = InstallTaskState.finishing.has(job.id);
    row.percent = InstallTaskState.stagePercent(job.stage);
    return row;
  }

  static publish(job: InstallJob): void {
    const old = InstallTaskState.tasks.get(job.id);
    const row = InstallTaskState.make(job);
    if (old !== undefined && job.stage === old.job.stage) row.percent = old.percent;
    InstallTaskState.removed.delete(job.id);
    InstallTaskState.tasks.set(job.id, row);
    InstallTaskState.emit();
  }

  static remove(id: string): void {
    InstallTaskState.removed.add(id);
    InstallTaskState.tasks.delete(id);
    InstallTaskState.emit();
  }

  static setRunning(id: string, running: boolean, finishing: boolean = false): void {
    if (running) InstallTaskState.running.add(id);
    else InstallTaskState.running.delete(id);
    if (finishing) InstallTaskState.finishing.add(id);
    else InstallTaskState.finishing.delete(id);
    const old = InstallTaskState.tasks.get(id);
    if (old !== undefined) {
      const row = InstallTaskState.make(old.job);
      row.percent = old.percent;
      InstallTaskState.tasks.set(id, row);
    }
    InstallTaskState.emit();
  }

  static downloadProgress(id: string, received: number, total: number): void {
    const old = InstallTaskState.tasks.get(id);
    if (old === undefined || old.job.stage !== InstallStage.DOWNLOADING || total <= 0) return;
    const percent = Math.min(68, Math.max(0, Math.floor(received * 68 / total)));
    if (percent === old.percent) return;
    const row = InstallTaskState.make(old.job);
    row.percent = percent;
    InstallTaskState.tasks.set(id, row);
    InstallTaskState.emit();
  }

  static forApp(rows: InstallTaskSnapshot[], appId: number, bundleName: string = ''):
    InstallTaskSnapshot | undefined {
    const matches = rows.filter((row: InstallTaskSnapshot) =>
      (appId > 0 && row.job.appId === appId) ||
      (bundleName.length > 0 && row.job.bundleName === bundleName));
    return matches.find((row: InstallTaskSnapshot) => row.running) ?? matches[0];
  }

  /** 当前选中的 Release 附件；旧版本或被重新上传的失败任务不能劫持新按钮。 */
  static forAsset(rows: InstallTaskSnapshot[], appId: number, bundleName: string,
    assetName: string, sha256: string, versionCode: number): InstallTaskSnapshot | undefined {
    if (assetName.length === 0) return undefined;
    const matches = rows.filter((row: InstallTaskSnapshot) => {
      const job = row.job;
      if (appId > 0 ? job.appId !== appId : job.bundleName !== bundleName) return false;
      if (job.assetName !== assetName) return false;
      if (versionCode > 0 && job.catalogVersionCode > 0 &&
        job.catalogVersionCode !== versionCode) return false;
      if (/^[0-9a-fA-F]{64}$/.test(sha256) &&
        job.expectedSha256.toLowerCase() !== sha256.toLowerCase() &&
        !job.id.endsWith(':' + sha256.toLowerCase())) return false;
      return true;
    });
    return matches.find((row: InstallTaskSnapshot) => row.running) ?? matches[0];
  }

  static stagePercent(stage: InstallStage): number {
    switch (stage) {
      case InstallStage.VERIFIED: return 70;
      case InstallStage.PACKAGE_INSPECTED: return 75;
      case InstallStage.PROFILE_READY: return 80;
      case InstallStage.SIGNED: return 90;
      case InstallStage.SIGNATURE_VERIFIED: return 92;
      case InstallStage.INSTALLING: return 95;
      case InstallStage.INSTALLED: return 100;
      default: return 0;
    }
  }

  /**
   * 当前阶段已经过去多久（毫秒）。
   *
   * 用 `stageHistory` 里最后一条的时间戳，不需要额外字段。**安装那一段没有任何
   * 中间进度**（设备只在结束时回结果），界面就是一个不动的「95%」——看起来和
   * 卡死完全一样。有了它就能显示「已用 47 秒」，让用户知道还在走。
   */
  static stageElapsedMs(row: InstallTaskSnapshot, now: number = Date.now()): number {
    const marks = row.job.stageHistory;
    for (let i = marks.length - 1; i >= 0; i--) {
      if (marks[i].stage === row.job.stage) {
        const started = Number(marks[i].at);
        return started > 0 && now > started ? now - started : 0;
      }
    }
    return 0;
  }

  static label(row: InstallTaskSnapshot, now: number = Date.now()): string {
    if (row.finishing) return '正在收尾';
    switch (row.job.stage) {
      case InstallStage.QUEUED: return '排队中';
      case InstallStage.DOWNLOADING: return row.running ? '下载中 ' + row.percent + '%' : '等待继续下载';
      case InstallStage.VERIFIED: return '读取安装包 ' + row.percent + '%';
      case InstallStage.PACKAGE_INSPECTED: return '准备授权 ' + row.percent + '%';
      case InstallStage.PROFILE_READY: return '签名中 ' + row.percent + '%';
      case InstallStage.SIGNED:
      case InstallStage.SIGNATURE_VERIFIED: return '准备安装 ' + row.percent + '%';
      case InstallStage.INSTALLING: {
        if (!row.running) return '等待确认安装';
        // 这一段可能是几分钟（设备要先停掉正在运行的旧版本，自更新时更慢）。
        // 只有百分比的话界面完全静止，所以补上已用时间。
        const elapsed = InstallTaskState.stageElapsedMs(row, now);
        return elapsed >= 1000 ?
          '安装中 ' + row.percent + '% · 已用 ' + Math.floor(elapsed / 1000) + ' 秒' :
          '安装中 ' + row.percent + '%';
      }
      case InstallStage.INSTALLED: return '安装完成';
      case InstallStage.WAITING_DEVICE: return '等待连接';
      case InstallStage.WAITING_ACCOUNT: return '等待登录';
      case InstallStage.WAITING_CONFIRMATION: return '等待确认数据清除';
      case InstallStage.WAITING_NETWORK: return '等待网络';
      case InstallStage.RETRYABLE_ERROR: return '安装暂停';
      case InstallStage.TERMINAL_ERROR: return '安装失败';
      default: return '准备中';
    }
  }
}
