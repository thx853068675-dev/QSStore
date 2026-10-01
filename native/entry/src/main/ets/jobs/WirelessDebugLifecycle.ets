import { common } from '@kit.AbilityKit';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { JobStore } from './JobStore';
import { JobScheduler } from './JobScheduler';
import { InstallTaskState, InstallTaskSnapshot } from './InstallTaskState';
import { InstallJob, InstallStage } from './InstallJob';
import { isPending } from './RecoveryPlanner';
import { InstallCoordinator } from './InstallCoordinator';

/** Release an idle host in background; reuse its paired, saved port on return. */
export class WirelessDebugLifecycle {
  private static context: common.UIAbilityContext | undefined;
  private static foreground: boolean = true;
  private static epoch: number = 0;
  private static checking: Promise<void> | undefined;
  private static restoring: Promise<void> | undefined;
  private static subscription: number = -1;
  private static recheck: boolean = false;

  static configure(context: common.UIAbilityContext): void {
    WirelessDebugLifecycle.context = context;
    HdcDeviceBridge.setIdleHandler(() => { WirelessDebugLifecycle.checkIdle(); });
    if (WirelessDebugLifecycle.subscription < 0) {
      WirelessDebugLifecycle.subscription = InstallTaskState.subscribe(() => {
        WirelessDebugLifecycle.checkIdle();
      });
    }
  }

  private static hasWork(): boolean {
    return JobScheduler.runningJobIds().length > 0 || InstallTaskState.snapshot().some(
      (row: InstallTaskSnapshot) => row.running || isPending(row.job.stage));
  }

  static onBackground(): void {
    WirelessDebugLifecycle.foreground = false;
    WirelessDebugLifecycle.epoch++;
    WirelessDebugLifecycle.checkIdle();
  }

  static onForeground(): void {
    if (WirelessDebugLifecycle.foreground && WirelessDebugLifecycle.restoring) return;
    WirelessDebugLifecycle.foreground = true;
    WirelessDebugLifecycle.epoch++;
    const epoch = WirelessDebugLifecycle.epoch;
    if (!WirelessDebugLifecycle.restoring) {
      WirelessDebugLifecycle.restoring = WirelessDebugLifecycle.restore().catch(() => {})
        .finally(() => {
          WirelessDebugLifecycle.restoring = undefined;
          if (WirelessDebugLifecycle.foreground && epoch !== WirelessDebugLifecycle.epoch) {
            WirelessDebugLifecycle.onForeground();
          } else WirelessDebugLifecycle.checkIdle();
        });
    }
  }

  private static checkIdle(): void {
    const context = WirelessDebugLifecycle.context;
    if (!context || WirelessDebugLifecycle.foreground ||
      WirelessDebugLifecycle.hasWork() || HdcDeviceBridge.busy() || !HdcDeviceBridge.deviceLinked()) return;
    if (WirelessDebugLifecycle.checking) { WirelessDebugLifecycle.recheck = true; return; }
    const epoch = WirelessDebugLifecycle.epoch;
    WirelessDebugLifecycle.checking = (async (): Promise<void> => {
      const store = await JobStore.open(context);
      if ((await store.listAll()).some((job: InstallJob) => isPending(job.stage))) return;
      await HdcDeviceBridge.releaseWhenIdle(() => !WirelessDebugLifecycle.foreground &&
        epoch === WirelessDebugLifecycle.epoch && !WirelessDebugLifecycle.hasWork());
    })().catch(() => {}).finally(() => {
      WirelessDebugLifecycle.checking = undefined;
      const again = WirelessDebugLifecycle.recheck || epoch !== WirelessDebugLifecycle.epoch;
      WirelessDebugLifecycle.recheck = false;
      if (again) WirelessDebugLifecycle.checkIdle();
    });
  }

  private static async restore(): Promise<void> {
    const context = WirelessDebugLifecycle.context;
    const epoch = WirelessDebugLifecycle.epoch;
    if (!context || JobScheduler.runningJobIds().length > 0) return;
    AppStorage.setOrCreate<boolean>('wirelessDebugRestoring', true);
    try {
      const connected = await new HdcDeviceBridge(context).restoreSavedLink(() =>
        WirelessDebugLifecycle.foreground && epoch === WirelessDebugLifecycle.epoch &&
        JobScheduler.runningJobIds().length === 0);
      if (!connected || !WirelessDebugLifecycle.foreground || epoch !== WirelessDebugLifecycle.epoch) return;
      const revision = AppStorage.get<number>('wirelessLinkRevision') ?? 0;
      AppStorage.setOrCreate<number>('wirelessLinkRevision', revision + 1);
      InstallCoordinator.conditionReady(context, InstallStage.WAITING_DEVICE).catch(() => {});
    } finally {
      AppStorage.setOrCreate<boolean>('wirelessDebugRestoring', false);
    }
  }
}
