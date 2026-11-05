import { retryDelayMs } from './RecoveryPlanner';
import { SelfInstallRecovery } from './SelfInstallRecovery';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { InstallReconnect } from './InstallReconnect';
import { InstallConfirmation } from './InstallConfirmation';
import { InstallCertificateSlots } from './InstallCertificateSlots';
import { InstallAccountRecovery } from './InstallAccountRecovery';
import { common } from '@kit.AbilityKit';
import { LocalImport } from './LocalImport';
import { AccountService } from '../data/AccountService';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { JobRunner } from './JobRunner';
import { NativeJobRuntime } from './NativeJobRuntime';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { JobScheduler } from './JobScheduler';
import { LocalBundles } from './LocalBundles';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { I18n } from '../data/I18n';

/** Process-owned FIFO per device. Different devices execute concurrently. */
export class InstallCoordinator {
  private static context: common.UIAbilityContext | undefined;

  private static requests: Map<string, Promise<InstallJob>> = new Map();
  private static submissions:number=0;
  private static submissionWaiters:Array<()=>void>=[];
  static holdQueue():()=>void {
    InstallCoordinator.submissions++;let held=true;
    return ()=>{if(!held)return;held=false;InstallCoordinator.submissions--;if(InstallCoordinator.submissions===0){const waiters=InstallCoordinator.submissionWaiters.splice(0);waiters.forEach((resolve)=>resolve());}InstallCoordinator.wake().catch(()=>{});};
  }
  private static draining: boolean = false;
  private static wakeAgain:boolean=false;
  private static ready: boolean = false;
  private static initializing: Promise<void> | undefined;

  static configure(context: common.UIAbilityContext): void {
    if (!PrivacyConsent.isBusinessAllowed()) return;
    if (!InstallCoordinator.context) {
      try { LocalImport.cleanupOldPreviews(context); } catch (_) {}
    }
    InstallCoordinator.context = context;
    JobScheduler.setQueueWakeup(() => { InstallCoordinator.wake().catch(() => {}); });
  }

  static async recovered(context: common.UIAbilityContext): Promise<void> {
    if (!PrivacyConsent.isBusinessAllowed()) return;
    InstallCoordinator.configure(context);
    if (!InstallCoordinator.ready) {
      if (!InstallCoordinator.initializing) {
        InstallCoordinator.initializing = InstallCoordinator.recoverQueued(context).then(() => {
          InstallCoordinator.ready = true;
        }).finally(() => { InstallCoordinator.initializing = undefined; });
      }
      await InstallCoordinator.initializing;
    }
    return InstallCoordinator.wake();
  }

  private static async recoverQueued(context: common.UIAbilityContext): Promise<void> {
    PrivacyConsent.assertBusinessAllowed();
    const store = await JobStore.open(context);
    await SelfInstallRecovery.reconcile(store);
    for (const job of await store.listAll(true)) {
      PrivacyConsent.assertBusinessAllowed();
      if(job.stage===InstallStage.WAITING_CONFIRMATION)InstallConfirmation.request(job.id);
      if (!JobScheduler.isRunning(job.id) && (job.stage === InstallStage.DOWNLOADING ||
        (job.stage === InstallStage.WAITING_NETWORK && Date.now() - job.updatedAt >= retryDelayMs(job.attempt)))) {
        job.stage = InstallStage.QUEUED;
        await store.save(job);
      }
    }
  }

  /** Manual retries, consent and reconnect resume through the same FIFO. */
  static run(context: common.UIAbilityContext, id: string): Promise<InstallJob> {
    if (!PrivacyConsent.isBusinessAllowed()) return Promise.reject(new Error(I18n.t('请先阅读并同意隐私声明')));
    InstallCoordinator.configure(context);
    const pending = InstallCoordinator.requests.get(id);
    if (pending !== undefined) return pending;
    const task = Promise.resolve().then(async () => {
      if(InstallCoordinator.submissions>0)await new Promise<void>((resolve)=>InstallCoordinator.submissionWaiters.push(resolve));
      PrivacyConsent.assertBusinessAllowed();
      const store = await JobStore.open(context);
      const saved = await store.get(id);
      PrivacyConsent.assertBusinessAllowed();
      if (saved?.stage === InstallStage.WAITING_CERTIFICATE) {
        InstallCertificateSlots.request(id);
        return saved;
      }
      const account = await AccountService.current(context);
      PrivacyConsent.assertBusinessAllowed();
      const result = await new JobRunner(store, new NativeJobRuntime(context, store, account,
        new HdcDeviceBridge(context, saved?.installTarget?DeviceInstallTarget.parse(saved.installTarget):undefined))).run(id);
      if (result.stage === InstallStage.INSTALLED || result.stage === InstallStage.SKIPPED) {
        try {
          if ((result.stagedTicket ?? '').length > 0 &&
            await new HdcDeviceBridge(context,result.installTarget?DeviceInstallTarget.parse(result.installTarget):undefined).discardStaged(result.stagedTicket)) {
            result.stagedTicket = ''; await store.save(result);
          }
          await store.pruneCompleted(context);
        } catch (_) {}
      }
      if (result.stage === InstallStage.WAITING_DEVICE) InstallReconnect.request(id);
      if (result.stage === InstallStage.WAITING_CONFIRMATION) InstallConfirmation.request(id);
      if (result.stage === InstallStage.WAITING_CERTIFICATE) InstallCertificateSlots.request(id,
        account ? JSON.stringify([account.userId, account.teamId]) : '');
      if (result.stage === InstallStage.WAITING_ACCOUNT && InstallAccountRecovery.requiresLogin(result.lastError)) {
        InstallAccountRecovery.request(id, account ? JSON.stringify([account.userId, account.teamId]) : '');
      }
      return result;
    });
    InstallCoordinator.requests.set(id, task);
    task.finally(() => {
      InstallCoordinator.requests.delete(id);
      InstallCoordinator.wake().catch(() => {});
    }).catch(() => {});
    return task;
  }

  static async wake(): Promise<void> {
    const context=InstallCoordinator.context;
    if(!PrivacyConsent.isBusinessAllowed()||!context||!InstallCoordinator.ready||InstallCoordinator.submissions>0)return;
    if(InstallCoordinator.draining){InstallCoordinator.wakeAgain=true;return;}
    InstallCoordinator.draining=true;
    try{
      const store=await JobStore.open(context),account=await AccountService.current(context);
      const rows=await store.listAll(true);
      if(!PrivacyConsent.isBusinessAllowed()||InstallCoordinator.submissions>0)return;
      const key=(job:InstallJob):string=>job.installTarget?DeviceInstallTarget.parse(job.installTarget).key:'local';
      const busy=new Set(rows.filter((job)=>InstallCoordinator.requests.has(job.id)||JobScheduler.isRunning(job.id)).map(key));
      const queued=rows.filter((job)=>job.stage===InstallStage.QUEUED&&!InstallCoordinator.requests.has(job.id)&&
        !JobScheduler.isRunning(job.id)&&(job.appId>0||job.sourceUrl==='local')&&
        (account!==undefined||LocalBundles.isSelfBundle(job.catalogBundleName||job.bundleName)))
        .sort((a,b)=>(a.stageHistory[0]?.at??a.updatedAt)-(b.stageHistory[0]?.at??b.updatedAt));
      const selected=new Set<string>();
      const heads=queued.filter((job)=>{const device=key(job);if(busy.has(device)||selected.has(device))return false;selected.add(device);return true;})
        .slice(0,Math.max(0,3-busy.size));
      // Every settling lane wakes the pump. A slow peer never holds the other lanes.
      for(const job of heads)InstallCoordinator.run(context,job.id).catch(()=>{});
    }finally{
      InstallCoordinator.draining=false;
      if(InstallCoordinator.wakeAgain){InstallCoordinator.wakeAgain=false;InstallCoordinator.wake().catch(()=>{});}
    }
  }

  /** Retry only conditions changed by the user, never data-loss confirmation. */
  static async conditionReady(context: common.UIAbilityContext, stage: InstallStage): Promise<void> {
    if (!PrivacyConsent.isBusinessAllowed()) return;
    if (stage === InstallStage.WAITING_COMPATIBILITY) return;
    const store = await JobStore.open(context);
    if (stage === InstallStage.WAITING_DEVICE) await store.cleanupCancelled(context);
    for (const job of await store.listAll(true)) {
      if (!PrivacyConsent.isBusinessAllowed()) return;
      if (job.stage === stage && !JobScheduler.isRunning(job.id)) {
        job.stage = InstallStage.QUEUED;
        job.lastError = '';
        await store.save(job);
      }
    }
    await InstallCoordinator.recovered(context);
  }
}
