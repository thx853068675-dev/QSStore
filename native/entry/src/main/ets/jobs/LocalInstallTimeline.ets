import { InstallStage, StageMark } from './InstallJob';
import { InstallTaskSnapshot, InstallTaskState } from './InstallTaskState';

export class LocalTimelineStep {
  key: string = '';
  label: string = '';
  timing: string = '';
  indicator: string = 'done';
}

export class LocalTimelineView {
  visible: boolean = false;
  running: boolean = false;
  title: string = '';
  version: string = '';
  status: string = '';
  tone: string = 'normal';
  message: string = '';
  steps: LocalTimelineStep[] = [];
}

/**
 * 将最新任务快照投影为时间轴；界面不持有某次安装开始时的任务对象。
 *
 * **只投影被显式选中的那一条**，不做「没选中就挑最近一条」的回退：本地页的
 * 侧载进度是「这一次安装」的过程，装完切走再回来不该继续挂着上一次的流程卡片。
 * 选中项由页面在导入新文件时设置，离开该页时清掉。
 */
export class LocalInstallTimeline {
  static present(tasks: InstallTaskSnapshot[], selectedId: string, now: number): LocalTimelineView {
    const view = new LocalTimelineView();
    if (selectedId.length === 0) return view;
    const task = tasks.find((row: InstallTaskSnapshot) => row.job.id === selectedId);
    if (task === undefined) return view;
    const job = task.job;
    const done = job.stage === InstallStage.INSTALLED;
    const waiting = LocalInstallTimeline.isWaiting(job.stage);
    view.visible = true;
    view.running = task.running && !done && !waiting;
    view.title = job.bundleName || job.assetName;
    view.version = job.versionName || (job.versionCode > 0 ? String(job.versionCode) : '');
    view.status = done ? '安装完成' : InstallTaskState.label(task, now);
    if (!task.running && !done && !waiting) view.status = '安装已暂停，可在管理页继续';
    view.tone = done ? 'success' : (waiting || !task.running ? 'warning' : 'normal');
    view.message = !task.running && !done ? job.lastError : '';
    const marks = job.stageHistory.slice();
    // 兼容没有时间轴的旧记录，以及阶段已更新但历史未补齐的记录。
    if (marks.length === 0 || marks[marks.length - 1].stage !== job.stage) {
      const mark = new StageMark();
      mark.stage = job.stage;
      mark.at = job.updatedAt;
      marks.push(mark);
    }
    view.steps = marks.map((mark: StageMark, index: number) => {
      const row = new LocalTimelineStep();
      const last = index === marks.length - 1;
      row.label = LocalInstallTimeline.label(mark.stage as InstallStage, last);
      row.indicator = LocalInstallTimeline.isWaiting(mark.stage as InstallStage) ? 'paused' : 'done';
      if (last && (mark.stage === InstallStage.DOWNLOADING || mark.stage === InstallStage.INSTALLING ||
        mark.stage === InstallStage.QUEUED)) {
        row.indicator = view.running ? 'running' : 'paused';
        if (view.running && task.finishing) row.label = '正在收尾，请稍候';
      }
      row.timing = LocalInstallTimeline.clock(mark.at);
      const nextAt = !last ? marks[index + 1].at : (view.running ? now : mark.at);
      if (!last || view.running) {
        const seconds = Math.max(0, Math.floor((nextAt - mark.at) / 1000));
        row.timing += ' · 用时 ' + (seconds < 60 ? seconds + ' 秒' :
          Math.floor(seconds / 60) + ' 分 ' + seconds % 60 + ' 秒');
      }
      // 同一个历史节点从“当前”变为“完成”时，必须更新原来的转圈和说明。
      row.key = job.id + ':' + index + ':' + mark.stage + ':' + mark.at + ':' +
        row.indicator + ':' + row.label + ':' + row.timing;
      return row;
    });
    // PACKAGE_INSPECTED 等是已完成的里程碑；转圈属于下一项实际工作。
    const operation = LocalInstallTimeline.nextOperation(job.stage);
    if (view.running && operation.length > 0) {
      const row = new LocalTimelineStep();
      row.label = task.finishing ? '正在收尾，请稍候' : operation;
      row.indicator = 'running';
      row.key = job.id + ':operation:' + row.label;
      view.steps.push(row);
    }
    return view;
  }

  private static isWaiting(stage: InstallStage): boolean {
    return stage === InstallStage.WAITING_ACCOUNT || stage === InstallStage.WAITING_DEVICE ||
      stage === InstallStage.WAITING_CONFIRMATION ||
      stage === InstallStage.WAITING_NETWORK || stage === InstallStage.RETRYABLE_ERROR ||
      stage === InstallStage.TERMINAL_ERROR;
  }

  private static nextOperation(stage: InstallStage): string {
    switch (stage) {
      case InstallStage.VERIFIED: return '正在解析应用身份';
      case InstallStage.PACKAGE_INSPECTED: return '正在准备设备授权';
      case InstallStage.PROFILE_READY: return '正在用本机证书签名';
      case InstallStage.SIGNED: return '正在校验签名';
      case InstallStage.SIGNATURE_VERIFIED: return '正在连接设备';
      default: return '';
    }
  }

  private static label(stage: InstallStage, last: boolean): string {
    switch (stage) {
      case InstallStage.QUEUED: return last ? '已读取 HAP，等待开始' : '已读取 HAP';
      case InstallStage.DOWNLOADING: return last ? '正在下载安装包' : '安装包下载结束';
      case InstallStage.VERIFIED: return '安装包已就绪';
      case InstallStage.PACKAGE_INSPECTED: return '已核对应用身份';
      case InstallStage.PROFILE_READY: return '设备授权已就绪';
      case InstallStage.SIGNED: return '已用本机证书签名';
      case InstallStage.SIGNATURE_VERIFIED: return '签名校验通过';
      case InstallStage.WAITING_NETWORK: return '网络中断，等待重试';
      case InstallStage.WAITING_ACCOUNT: return '等待登录开发者账号';
      case InstallStage.WAITING_CONFIRMATION: return '等待确认是否清除应用数据';
      case InstallStage.WAITING_DEVICE: return '等待无线调试连接';
      case InstallStage.INSTALLING: return last ? '正在安装到设备' : '已提交设备安装';
      case InstallStage.INSTALLED: return '安装完成';
      case InstallStage.RETRYABLE_ERROR: return '安装暂停，可重试';
      case InstallStage.TERMINAL_ERROR: return '无法继续';
      default: return stage;
    }
  }

  private static clock(at: number): string {
    if (at <= 0) return '';
    const date = new Date(at);
    const pad = (value: number): string => value < 10 ? '0' + value : String(value);
    return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
  }
}
