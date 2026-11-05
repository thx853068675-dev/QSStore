import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { DeviceNetwork } from './DeviceNetwork';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { ForegroundIdle } from './ForegroundIdle';
import { JobScheduler } from './JobScheduler';
import { InstallCoordinator } from './InstallCoordinator';
import { InstallStage } from './InstallJob';
import { I18n } from '../data/I18n';

export type FixedPortPhase = 'off' | 'waiting' | 'busy' | 'setting' | 'ready' | 'recovering' | 'failed' | 'stopping';

/** Desired configuration survives restart; "ready" always requires a verified live session. */
export class FixedDebugPort {
  private static context: common.UIAbilityContext | undefined;
  private static foreground: boolean = true;
  private static initialized: boolean = false;
  private static loading: Promise<void> | undefined;
  private static flight: Promise<void> | undefined;
  private static timer: number = -1;
  private static attempts: number = 0;
  private static budgetUntil:number=0;
  private static needsCheck: boolean = true;
  private static networkSubscription:number=-1;
  private static networkKey:string='';
  static enabled: boolean = false;
  static resetPending: boolean = false;
  static port: number = 0;
  static phase: FixedPortPhase = 'off';
  static message: string = '';

  static randomPort(): number {
    const random = cryptoFramework.createRandom();
    // Rejection sampling avoids bias and privileged / out-of-range ports.
    for (let attempt = 0; attempt < 16; attempt++) {
      const bytes = random.generateRandomSync(2).data;
      const value = bytes[0] * 256 + bytes[1];
      if (value < 55536) return 10000 + value;
    }
    throw new Error(I18n.t('暂时无法生成随机端口，请重试'));
  }

  private static publish(phase: FixedPortPhase, message: string = ''): void {
    if (FixedDebugPort.phase === phase && FixedDebugPort.message === message) return;
    FixedDebugPort.phase = phase;
    FixedDebugPort.message = message;
    const revision = AppStorage.get<number>('fixedDebugPortRevision') ?? 0;
    AppStorage.setOrCreate<number>('fixedDebugPortRevision', revision + 1);
  }

  static configure(context: common.UIAbilityContext): void {
    FixedDebugPort.context = context;
    if (!FixedDebugPort.loading) {
      FixedDebugPort.loading = (async (): Promise<void> => {
        const settings = await new HdcDeviceBridge(context).fixedPortSettings();
        FixedDebugPort.enabled = settings.enabled;
        FixedDebugPort.resetPending = settings.resetPending === true;
        FixedDebugPort.port = settings.port;
        FixedDebugPort.initialized = true;
        FixedDebugPort.publish(FixedDebugPort.resetPending ? 'stopping' : settings.enabled ? 'waiting' : 'off');
        FixedDebugPort.schedule();
      })().catch(() => { FixedDebugPort.publish('failed', I18n.t('无法读取本机端口设置')); });
    }
    if(FixedDebugPort.networkSubscription<0){
      FixedDebugPort.networkKey=DeviceNetwork.signature;
      FixedDebugPort.networkSubscription=DeviceNetwork.subscribe(()=>{
        const key=DeviceNetwork.signature;
        if(key===FixedDebugPort.networkKey)return;
        FixedDebugPort.networkKey=key;
        if(DeviceNetwork.available)FixedDebugPort.wake(true);
      });
      DeviceNetwork.start().catch(()=>{});
    }
  }

  static onForeground(): void { FixedDebugPort.foreground = true; FixedDebugPort.wake(false); }
  static onBackground(): void {
    FixedDebugPort.foreground = false;
    ForegroundIdle.cancel('fixed-debug-port');
    if (FixedDebugPort.timer !== -1) clearTimeout(FixedDebugPort.timer);
    FixedDebugPort.timer = -1;
  }

  /** External events may start a new bounded recovery; command completion cannot reset its budget. */
  static wake(resetBudget:boolean=true): void {
    if(!resetBudget&&FixedDebugPort.phase==='ready'&&HdcDeviceBridge.connectedPort()===FixedDebugPort.port)return;
    FixedDebugPort.needsCheck = true;
    if(resetBudget){
      FixedDebugPort.attempts=0;FixedDebugPort.budgetUntil=0;
      if(FixedDebugPort.timer!==-1)clearTimeout(FixedDebugPort.timer);
      FixedDebugPort.timer=-1;
    }
    FixedDebugPort.schedule();
  }

  static idle(): void { FixedDebugPort.schedule(); }

  static async set(enabled: boolean, port: number): Promise<void> {
    const context = FixedDebugPort.context;
    if (!context) throw new Error(I18n.t('设备连接尚未初始化'));
    await FixedDebugPort.loading;
    // A new choice waits for the current daemon restart; never start two port changes together.
    if (FixedDebugPort.flight) await FixedDebugPort.flight;
    await new HdcDeviceBridge(context).saveFixedPortSettings({ enabled: enabled, port: port });
    FixedDebugPort.enabled = enabled;
    FixedDebugPort.resetPending = false;
    FixedDebugPort.port = port;
    FixedDebugPort.publish(enabled ? 'waiting' : 'off');
    FixedDebugPort.wake();
  }

  static async deactivate(): Promise<void> {
    const context = FixedDebugPort.context;
    if (!context) throw new Error(I18n.t('设备连接尚未初始化'));
    await FixedDebugPort.loading;
    if (FixedDebugPort.flight) await FixedDebugPort.flight;
    await new HdcDeviceBridge(context).saveFixedPortSettings({ enabled: false,
      port: FixedDebugPort.port, resetPending: true });
    FixedDebugPort.enabled = false;
    FixedDebugPort.resetPending = true;
    FixedDebugPort.publish('stopping');
    FixedDebugPort.wake();
  }

  private static schedule(): void {
    if (!FixedDebugPort.initialized || (!FixedDebugPort.enabled && !FixedDebugPort.resetPending) || !FixedDebugPort.foreground ||
      FixedDebugPort.flight || FixedDebugPort.timer !== -1 || FixedDebugPort.attempts >= 3) return;
    if (!FixedDebugPort.needsCheck && FixedDebugPort.phase === 'ready' &&
      HdcDeviceBridge.connectedPort() === FixedDebugPort.port) return;
    if(FixedDebugPort.budgetUntil>0&&Date.now()>=FixedDebugPort.budgetUntil){FixedDebugPort.publish(HdcDeviceBridge.deviceLinked()?'failed':'waiting');return;}
    if (JobScheduler.runningJobIds().length > 0) { FixedDebugPort.publish('busy'); return; }
    if (HdcDeviceBridge.busy()) return;
    // Neither setting the port nor checking it belongs in the opening animation.
    ForegroundIdle.defer('fixed-debug-port', () => {
      if ((!FixedDebugPort.enabled && !FixedDebugPort.resetPending) || !FixedDebugPort.foreground || FixedDebugPort.flight ||
        JobScheduler.runningJobIds().length > 0 || HdcDeviceBridge.busy()) return;
      FixedDebugPort.restore().catch(()=>{});
    });
  }

  /** Foreground restore and port maintenance share one recovery flight and budget. */
  static restore():Promise<void>{
    if(FixedDebugPort.flight)return FixedDebugPort.flight;
    if(!FixedDebugPort.foreground||(!FixedDebugPort.enabled&&!FixedDebugPort.resetPending)||
      FixedDebugPort.attempts>=3||FixedDebugPort.timer!==-1||JobScheduler.runningJobIds().length>0||HdcDeviceBridge.busy())return Promise.resolve();
    if(!FixedDebugPort.needsCheck&&FixedDebugPort.phase==='ready'&&HdcDeviceBridge.connectedPort()===FixedDebugPort.port)return Promise.resolve();
    if(FixedDebugPort.budgetUntil>0&&Date.now()>=FixedDebugPort.budgetUntil)return Promise.resolve();
    if(FixedDebugPort.budgetUntil===0)FixedDebugPort.budgetUntil=Date.now()+15000;
    ForegroundIdle.cancel('fixed-debug-port');
    const flight=FixedDebugPort.reconcile().finally(()=>{
      if(FixedDebugPort.flight===flight)FixedDebugPort.flight=undefined;
      FixedDebugPort.schedule();
    });FixedDebugPort.flight=flight;return flight;
  }

  private static async reconcile(): Promise<void> {
    const context = FixedDebugPort.context;
    if (!context) return;
    const bridge = new HdcDeviceBridge(context);
    try {
      if (!await bridge.connected(()=>FixedDebugPort.foreground&&Date.now()<FixedDebugPort.budgetUntil)) {
        FixedDebugPort.publish('waiting', I18n.t('请先连接一次无线调试'));
        FixedDebugPort.retry();
        return;
      }
      if (!FixedDebugPort.foreground) return;
      if (FixedDebugPort.resetPending) {
        FixedDebugPort.publish('stopping');
        if (!await bridge.clearFixedPort(() => FixedDebugPort.foreground && FixedDebugPort.resetPending &&
          JobScheduler.runningJobIds().length === 0)) { FixedDebugPort.publish('busy'); return; }
        await bridge.saveFixedPortSettings({ enabled: false, port: FixedDebugPort.port });
        FixedDebugPort.resetPending = false;
        FixedDebugPort.publish('off');
        const revision = AppStorage.get<number>('wirelessLinkRevision') ?? 0;
        AppStorage.setOrCreate<number>('wirelessLinkRevision', revision + 1);
        return;
      }
      if (!FixedDebugPort.enabled) return;
      if (HdcDeviceBridge.connectedPort() !== FixedDebugPort.port) {
        FixedDebugPort.publish('setting');
        const applied = await bridge.fixPort(FixedDebugPort.port, () => FixedDebugPort.enabled &&
          FixedDebugPort.foreground && JobScheduler.runningJobIds().length === 0);
        if (!applied) { FixedDebugPort.publish('busy'); return; }
        const revision = AppStorage.get<number>('wirelessLinkRevision') ?? 0;
        AppStorage.setOrCreate<number>('wirelessLinkRevision', revision + 1);
        InstallCoordinator.conditionReady(context, InstallStage.WAITING_DEVICE).catch(() => {});
      }
      FixedDebugPort.publish('ready');
      FixedDebugPort.needsCheck = false;
      FixedDebugPort.attempts = 0;FixedDebugPort.budgetUntil=0;
    } catch (error) {
      FixedDebugPort.publish('recovering', String(error));
      FixedDebugPort.retry();
    }
  }

  private static retry(): void {
    FixedDebugPort.attempts++;
    if (FixedDebugPort.attempts >= 3) {
      FixedDebugPort.publish(HdcDeviceBridge.deviceLinked() ? 'failed' : 'waiting', FixedDebugPort.message);
      return;
    }
    if (!FixedDebugPort.foreground || (!FixedDebugPort.enabled && !FixedDebugPort.resetPending)) return;
    FixedDebugPort.timer = setTimeout(() => {
      FixedDebugPort.timer = -1;
      FixedDebugPort.schedule();
    }, FixedDebugPort.attempts * 1500);
  }

  static label(): string {
    if (FixedDebugPort.resetPending) return FixedDebugPort.phase === 'busy' ? I18n.t('安装完成后停用') :
      FixedDebugPort.phase === 'waiting' || FixedDebugPort.phase === 'failed' ? I18n.t('连接后停用') : I18n.t('正在停用…');
    if (!FixedDebugPort.enabled) return I18n.t('未启用');
    if (FixedDebugPort.phase === 'setting') return I18n.t('正在设置…');
    if (FixedDebugPort.phase === 'recovering') return I18n.t('自动恢复中…');
    if (FixedDebugPort.phase === 'busy') return I18n.t('等待安装完成');
    if (FixedDebugPort.phase === 'ready') return I18n.t('已固定 · ') + FixedDebugPort.port;
    if (FixedDebugPort.phase === 'failed') return I18n.t('待恢复 · ') + FixedDebugPort.port;
    return I18n.t('等待连接 · ') + FixedDebugPort.port;
  }
}
