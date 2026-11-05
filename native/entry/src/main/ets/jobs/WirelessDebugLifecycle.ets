import { common } from '@kit.AbilityKit';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { JobScheduler } from './JobScheduler';
import { InstallTaskState, InstallTaskSnapshot } from './InstallTaskState';
import { InstallStage } from './InstallJob';
import { InstallCoordinator } from './InstallCoordinator';
import { ForegroundIdle } from './ForegroundIdle';
import { FixedDebugPort } from './FixedDebugPort';
import { DeviceNetwork } from './DeviceNetwork';

/** Release an idle host in background; reuse its paired, saved port on return. */
export class WirelessDebugLifecycle {
  private static context: common.UIAbilityContext | undefined;
  private static foreground: boolean = true;
  private static epoch: number = 0;
  private static checking: Promise<void> | undefined;
  private static restoring: Promise<void> | undefined;
  private static subscription: number = -1;
  private static recheck: boolean = false;
  private static releaseTimer:number=-1;
  private static releaseAttempts:number=0;
  private static releasedEpoch:number=-1;
  private static automaticKey:string='';
  private static automaticAttempts:number=0;
  private static networkSubscription:number=-1;

  static configure(context: common.UIAbilityContext): void {
    WirelessDebugLifecycle.context = context;
    FixedDebugPort.configure(context);
    if(WirelessDebugLifecycle.networkSubscription<0)WirelessDebugLifecycle.networkSubscription=DeviceNetwork.subscribe(()=>{
      if(WirelessDebugLifecycle.foreground)ForegroundIdle.defer('wireless-restore',()=>{if(WirelessDebugLifecycle.foreground)WirelessDebugLifecycle.startRestore();});
    });
    HdcDeviceBridge.setIdleHandler(() => { WirelessDebugLifecycle.checkIdle(); FixedDebugPort.idle(); });
    if (WirelessDebugLifecycle.subscription < 0) {
      WirelessDebugLifecycle.subscription = InstallTaskState.subscribe(() => {
        WirelessDebugLifecycle.checkIdle();
        FixedDebugPort.idle();
      });
    }
  }

  private static hasWork(): boolean {
    return JobScheduler.runningJobIds().length > 0 || InstallTaskState.snapshot().some(
      (row: InstallTaskSnapshot) => row.running);
  }

  static onBackground(): void {
    FixedDebugPort.onBackground();
    if(WirelessDebugLifecycle.context&&!WirelessDebugLifecycle.hasWork())HdcDeviceBridge.cancelDiscovery(WirelessDebugLifecycle.context);
    ForegroundIdle.cancel('wireless-restore');
    WirelessDebugLifecycle.foreground = false;
    WirelessDebugLifecycle.epoch++;
    WirelessDebugLifecycle.releaseAttempts=0;
    WirelessDebugLifecycle.checkIdle();
  }

  static onForeground(): void {
    FixedDebugPort.onForeground();
    if(WirelessDebugLifecycle.releaseTimer!==-1)clearTimeout(WirelessDebugLifecycle.releaseTimer);
    WirelessDebugLifecycle.releaseTimer=-1;
    if (WirelessDebugLifecycle.foreground && WirelessDebugLifecycle.restoring) return;
    WirelessDebugLifecycle.foreground = true;
    WirelessDebugLifecycle.epoch++;
    // Active work remains urgent; idle browsing waits for the opening/scroll animation.
    if (WirelessDebugLifecycle.hasWork()) WirelessDebugLifecycle.startRestore();
    else ForegroundIdle.defer('wireless-restore', () => {
      if (WirelessDebugLifecycle.foreground) WirelessDebugLifecycle.startRestore();
    });
  }

  private static startRestore(): void {
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
      WirelessDebugLifecycle.hasWork() || HdcDeviceBridge.busy() || WirelessDebugLifecycle.releaseTimer!==-1) return;
    if(WirelessDebugLifecycle.releasedEpoch===WirelessDebugLifecycle.epoch&&!HdcDeviceBridge.hasSessions()&&!HdcDeviceBridge.releasePending)return;
    if (WirelessDebugLifecycle.checking) { WirelessDebugLifecycle.recheck = true; return; }
    const epoch = WirelessDebugLifecycle.epoch;
    WirelessDebugLifecycle.checking = (async (): Promise<void> => {
      await HdcDeviceBridge.releaseWhenIdle(() => !WirelessDebugLifecycle.foreground &&
        epoch === WirelessDebugLifecycle.epoch && !WirelessDebugLifecycle.hasWork());
      if(epoch!==WirelessDebugLifecycle.epoch||WirelessDebugLifecycle.foreground)return;
      if(!HdcDeviceBridge.releasePending){WirelessDebugLifecycle.releasedEpoch=epoch;WirelessDebugLifecycle.releaseAttempts=0;}
      else if(WirelessDebugLifecycle.releaseAttempts<5){
        const delay=Math.min(4000,250*Math.pow(2,WirelessDebugLifecycle.releaseAttempts++));
        WirelessDebugLifecycle.releaseTimer=setTimeout(()=>{WirelessDebugLifecycle.releaseTimer=-1;WirelessDebugLifecycle.checkIdle();},delay);
      }
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
      let connected:boolean=false;
      if(FixedDebugPort.enabled||FixedDebugPort.resetPending){
        await FixedDebugPort.restore();connected=HdcDeviceBridge.deviceLinked();
      }else{
        const bridge=new HdcDeviceBridge(context),key=DeviceNetwork.signature+'|'+await bridge.savedPort();
        if(key!==WirelessDebugLifecycle.automaticKey){WirelessDebugLifecycle.automaticKey=key;WirelessDebugLifecycle.automaticAttempts=0;}
        if(WirelessDebugLifecycle.automaticAttempts>=3&&!HdcDeviceBridge.deviceLinked())return;
        WirelessDebugLifecycle.automaticAttempts++;
        connected=await bridge.restoreSavedLink(() =>WirelessDebugLifecycle.foreground&&epoch===WirelessDebugLifecycle.epoch&&JobScheduler.runningJobIds().length===0);
        if(connected)WirelessDebugLifecycle.automaticAttempts=0;
      }
      if (!connected || !WirelessDebugLifecycle.foreground || epoch !== WirelessDebugLifecycle.epoch) return;
      const revision = AppStorage.get<number>('wirelessLinkRevision') ?? 0;
      AppStorage.setOrCreate<number>('wirelessLinkRevision', revision + 1);
      InstallCoordinator.conditionReady(context, InstallStage.WAITING_DEVICE).catch(() => {});
    } finally {
      AppStorage.setOrCreate<boolean>('wirelessDebugRestoring', false);
    }
  }
}
