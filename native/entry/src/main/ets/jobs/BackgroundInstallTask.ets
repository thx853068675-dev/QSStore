import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

/** 安装任务共享一个数据传输长时任务，生命周期归执行器，不归页面。 */
export class BackgroundInstallTask {
  private static context: common.UIAbilityContext | undefined;
  private static owners: Set<string> = new Set();
  private static running: boolean = false;
  private static taskId: number = -1;
  private static observing: boolean = false;
  private static chain: Promise<void> = Promise.resolve();
  private static onCancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (info.id !== BackgroundInstallTask.taskId) return;
    BackgroundInstallTask.running = false;
    BackgroundInstallTask.taskId = -1;
    console.warn('Install background task stopped: ' + info.reason);
    // 用户删除通知或系统收回后台资格时不循环申请；返回前台再核对。
  };

  static configure(context: common.UIAbilityContext): void {
    BackgroundInstallTask.context = context;
    if (BackgroundInstallTask.observing) return;
    try {
      backgroundTaskManager.on('continuousTaskCancel', BackgroundInstallTask.onCancelled);
      BackgroundInstallTask.observing = true;
    } catch (error) {
      console.warn('Unable to observe install background task: ' + String(error));
    }
  }

  private static serialize(action: () => Promise<void>): Promise<void> {
    const next = BackgroundInstallTask.chain.then(action);
    BackgroundInstallTask.chain = next.catch(() => {});
    return next;
  }

  private static async startIfNeeded(): Promise<void> {
    const context = BackgroundInstallTask.context;
    if (context === undefined || BackgroundInstallTask.running || BackgroundInstallTask.owners.size === 0) return;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 4801,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const result = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      BackgroundInstallTask.taskId = result.continuousTaskId ?? -1;
      BackgroundInstallTask.running = true;
      console.info('Install background task started: ' + BackgroundInstallTask.taskId);
    } catch (error) {
      // 后台资格不可用时仍允许前台安装，系统托管下载也可继续；不能因此丢弃任务。
      console.warn('Unable to start install background task: ' + String(error));
    }
  }

  static acquire(jobId: string): Promise<void> {
    BackgroundInstallTask.owners.add(jobId);
    return BackgroundInstallTask.serialize(() => BackgroundInstallTask.startIfNeeded());
  }

  static release(jobId: string): Promise<void> {
    BackgroundInstallTask.owners.delete(jobId);
    return BackgroundInstallTask.serialize(async () => {
      const context = BackgroundInstallTask.context;
      if (context === undefined || !BackgroundInstallTask.running || BackgroundInstallTask.owners.size > 0) return;
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        console.info('Install background task released');
      } catch (error) {
        console.warn('Unable to release install background task: ' + String(error));
      } finally {
        BackgroundInstallTask.running = false;
        BackgroundInstallTask.taskId = -1;
      }
    });
  }

  static onForeground(): void {
    // 若系统曾取消长时任务，仅在用户回到应用且仍有真实工作时重新申请。
    BackgroundInstallTask.serialize(() => BackgroundInstallTask.startIfNeeded());
  }
}
