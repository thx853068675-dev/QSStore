import { InstallReconnect } from './InstallReconnect';
import { InstallJob, InstallStage } from './InstallJob';

/** 进程内的任务视图：阶段来自已落盘记录，进度来自下载器，执行状态来自调度器。 */
export class InstallTaskSnapshot {
  job: InstallJob = new InstallJob();
  running: boolean = false;
  finishing: boolean = false;
  percent: number = 0;
  phase: string = '';
  received: number = 0;
  total: number = 0;
}

export class InstallTaskState {
  private static tasks: Map<string, InstallTaskSnapshot> = new Map();
  private static running: Set<string> = new Set();
  private static finishing: Set<string> = new Set();
  private static removed: Set<string> = new Set();
  private static listeners: Map<number, (rows: InstallTaskSnapshot[]) => void> = new Map();
  private static nextListener: number = 0;
  private static pulseTimer: number = -1;

  static snapshot(): InstallTaskSnapshot[] {
    return Array.from(InstallTaskState.tasks.values()).sort((a, b) => b.job.updatedAt - a.job.updatedAt);
  }

  static subscribe(listener: (rows: InstallTaskSnapshot[]) => void): number {
    const id = ++InstallTaskState.nextListener;
    InstallTaskState.listeners.set(id, listener);
    listener(InstallTaskState.snapshot());
    InstallTaskState.syncPulse();
    return id;
  }

  static unsubscribe(id: number): void {
    InstallTaskState.listeners.delete(id);
    InstallTaskState.syncPulse();
  }

  private static emit(): void {
    const rows = InstallTaskState.snapshot();
    InstallTaskState.listeners.forEach((listener: (rows: InstallTaskSnapshot[]) => void) => {
      // 页面被销毁或渲染失败不能中断任务流水线。
      try { listener(rows); } catch (_) {}
    });
    InstallTaskState.syncPulse();
  }

  /** 无数字反馈的阶段每秒重绘用时；无订阅者或没有活动任务即停止。 */
  private static syncPulse(): void {
    const active = InstallTaskState.listeners.size > 0 &&
      InstallTaskState.snapshot().some((row: InstallTaskSnapshot) =>
        row.running && row.job.stage !== InstallStage.INSTALLED && !InstallTaskState.determinate(row));
    if (active && InstallTaskState.pulseTimer === -1) {
      InstallTaskState.pulseTimer = setInterval(() => InstallTaskState.emit(), 1000);
    } else if (!active && InstallTaskState.pulseTimer !== -1) {
      clearInterval(InstallTaskState.pulseTimer);
      InstallTaskState.pulseTimer = -1;
    }
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
    if (old !== undefined && job.stage === old.job.stage) InstallTaskState.copyProgress(old, row);
    InstallTaskState.removed.delete(job.id);
    InstallTaskState.tasks.set(job.id, row);
    if (job.stage === InstallStage.WAITING_DEVICE && row.running) InstallReconnect.request(job.id);
    else if (job.stage !== InstallStage.WAITING_DEVICE) InstallReconnect.clear(job.id);
    InstallTaskState.emit();
  }

  static remove(id: string): void {
    InstallReconnect.clear(id);
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
      InstallTaskState.copyProgress(old, row);
      InstallTaskState.tasks.set(id, row);
    }
    InstallTaskState.emit();
  }

  private static copyProgress(old: InstallTaskSnapshot, row: InstallTaskSnapshot): void {
    row.percent = old.percent;
    row.phase = old.phase;
    row.received = old.received;
    row.total = old.total;
  }

  static downloadProgress(id: string, received: number, total: number): void {
    const old = InstallTaskState.tasks.get(id);
    if (old === undefined || old.job.stage !== InstallStage.DOWNLOADING ||
      !Number.isFinite(received) || !Number.isFinite(total) || total <= 0) return;
    const bytes = Math.min(total, Math.max(0, received));
    const percent = Math.floor(bytes * 100 / total);
    if (percent === old.percent && bytes === old.received && total === old.total) return;
    const row = InstallTaskState.make(old.job);
    row.phase = 'download'; row.received = bytes; row.total = total; row.percent = percent;
    InstallTaskState.tasks.set(id, row);
    InstallTaskState.emit();
  }

  /** 传包按真实字节计数；包管理器只给最终结果，不能伪造总百分比。 */
  static installProgress(id: string, phase: string, received: number, total: number): void {
    const old = InstallTaskState.tasks.get(id);
    if (old === undefined || !old.running || old.job.stage !== InstallStage.INSTALLING ||
      !['waiting', 'transfer', 'installing', 'verifying'].includes(phase)) return;
    const size = Number.isFinite(total) && total > 0 ? total : 0;
    const bytes = Number.isFinite(received) ? Math.min(size, Math.max(0, received)) : 0;
    const percent = phase === 'transfer' && size > 0 ? Math.floor(bytes * 100 / size) : 0;
    if (phase === old.phase && bytes === old.received && size === old.total) return;
    const row = InstallTaskState.make(old.job);
    row.phase = phase; row.received = bytes; row.total = size; row.percent = percent;
    InstallTaskState.tasks.set(id, row);
    InstallTaskState.emit();
  }

  static determinate(row: InstallTaskSnapshot): boolean {
    return row.total > 0 && (row.job.stage === InstallStage.DOWNLOADING ||
      (row.job.stage === InstallStage.INSTALLING && row.phase === 'transfer'));
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
    return stage === InstallStage.INSTALLED ? 100 : 0;
  }

  /** 安装处理没有分母，显示阶段和耗时，不将里程碑冒充精确百分比。 */
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
      case InstallStage.DOWNLOADING: return row.running ? '下载中' +
        (row.total > 0 ? ' ' + row.percent + '%' : '') : '等待继续下载';
      case InstallStage.VERIFIED: return '读取安装包';
      case InstallStage.PACKAGE_INSPECTED: return '准备授权';
      case InstallStage.PROFILE_READY: return '签名中';
      case InstallStage.SIGNED:
      case InstallStage.SIGNATURE_VERIFIED: return '准备安装';
      case InstallStage.INSTALLING: {
        if (!row.running) return '等待确认安装';
        if (row.phase === 'transfer' && row.total > 0) return '传送中 ' + row.percent + '%';
        const currentPhase = row.phase ?? '';
        const phase = currentPhase === 'verifying' ? '确认安装结果' :
          (currentPhase === 'waiting' || currentPhase.length === 0 ? '等待设备接收' : '系统安装中');
        const elapsed = InstallTaskState.stageElapsedMs(row, now);
        return elapsed >= 1000 ? phase + ' · ' + Math.floor(elapsed / 1000) + ' 秒' : phase;
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
