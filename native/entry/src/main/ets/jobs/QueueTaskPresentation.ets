import { DeviceInstallGroup } from './DeviceInstallGroup';
import { InstallJob, InstallStage } from './InstallJob';
import { InstallTaskSnapshot, InstallTaskState } from './InstallTaskState';
import { I18n } from '../data/I18n';

/** A mounted queue card keeps its identity while only its live presentation changes. */
export class QueueTaskView {
  job: InstallJob = new InstallJob();
  running: boolean = false;
  determinate: boolean = false;
  percent: number = 0;
  label: string = I18n.t('准备');
  detail: string = '';
  error: boolean = false;
  warning: boolean = false;
}

export class QueueTaskPresentation {
  /** Progress, persisted stages and queue position all come from the same snapshot. */
  static present(rows: InstallTaskSnapshot[], id: string, fallback: InstallJob): QueueTaskView {
    const view = new QueueTaskView();
    const task = rows.find((row: InstallTaskSnapshot) => row.job.id === id);
    view.job = task?.job ?? fallback;
    view.running = task?.running ?? false;
    view.determinate = task !== undefined && view.running && InstallTaskState.determinate(task);
    view.percent = task?.percent ?? 0;
    view.label = task === undefined ? I18n.t('准备') : InstallTaskState.compactLabel(task);
    view.error = !view.running && view.job.lastError.length > 0 &&
      ![InstallStage.WAITING_CONFIRMATION,InstallStage.WAITING_COMPATIBILITY,InstallStage.SKIPPED].includes(view.job.stage);
    view.warning = view.running && view.job.stage === InstallStage.INSTALLING;
    if(view.job.stage===InstallStage.WAITING_CONFIRMATION){
      view.detail=I18n.t('等待确认，仅此设备暂停');
    } else if (view.job.stage === InstallStage.QUEUED && !view.running) {
      const time = QueueTaskPresentation.enqueuedAt(view.job);
      const ahead = rows.filter((row: InstallTaskSnapshot) => row.job.id !== id &&
        row.job.stage === InstallStage.QUEUED && DeviceInstallGroup.deviceKey(row.job)===DeviceInstallGroup.deviceKey(view.job) && QueueTaskPresentation.enqueuedAt(row.job) < time).length;
      view.detail = I18n.t('排队中 · 第 ') + (ahead + 1) + I18n.t(' 个');
    } else if (view.job.stage === InstallStage.WAITING_COMPATIBILITY && !view.running) {
      view.detail = I18n.t('设备适配确认已取消，左滑卡片继续安装');
    } else if (view.error) {
      view.detail = view.job.lastError.replace(I18n.t('点击继续安装'), I18n.t('左滑卡片继续安装'))
        .replace(I18n.t('长按卡片继续安装'), I18n.t('左滑卡片继续安装'));
    } else if (view.warning) {
      view.detail = I18n.t('取消后停止后续步骤，系统已接收的安装可能仍会完成');
    } else {
      view.detail = task === undefined ? '' : InstallTaskState.label(task);
    }
    return view;
  }

  private static enqueuedAt(job: InstallJob): number {
    return job.stageHistory[0]?.at ?? job.updatedAt;
  }

  /** Other tasks' byte progress must not invalidate this card's title or image. */
  static unchanged(a: QueueTaskView, b: QueueTaskView): boolean {
    return a.job === b.job && a.running === b.running && a.determinate === b.determinate &&
      a.percent === b.percent && a.label === b.label && a.detail === b.detail &&
      a.error === b.error && a.warning === b.warning;
  }
}
