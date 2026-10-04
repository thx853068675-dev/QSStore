import { retryDelayMs } from './RecoveryPlanner';
import { InstallReconnect } from './InstallReconnect';
import { InstallConfirmation } from './InstallConfirmation';
import { InstallCertificateSlots } from './InstallCertificateSlots';
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

/** Process-owned FIFO. Pages submit requests; navigation never owns execution. */
export class InstallCoordinator {
  private static context: common.UIAbilityContext | undefined;
  private static tail: Promise<void> = Promise.resolve();
  private static requests: Map<string, Promise<InstallJob>> = new Map();
  private static draining: boolean = false;
  private static ready: boolean = false;
  private static initializing: Promise<void> | undefined;

  static configure(context: common.UIAbilityContext): void {
    if (!InstallCoordinator.context) {
      try { LocalImport.cleanupOldPreviews(context); } catch (_) {}
    }
    InstallCoordinator.context = context;
    JobScheduler.setQueueWakeup(() => { InstallCoordinator.wake().catch(() => {}); });
  }

  static async recovered(context: common.UIAbilityContext): Promise<void> {
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
    const store = await JobStore.open(context);
    for (const job of await store.listAll()) {
      if (!JobScheduler.isRunning(job.id) && (job.stage === InstallStage.DOWNLOADING ||
        (job.stage === InstallStage.WAITING_NETWORK && Date.now() - job.updatedAt >= retryDelayMs(job.attempt)))) {
        job.stage = InstallStage.QUEUED;
        await store.save(job);
      }
    }
  }

  /** Manual retries, consent and reconnect resume through the same FIFO. */
  static run(context: common.UIAbilityContext, id: string): Promise<InstallJob> {
    InstallCoordinator.configure(context);
    const pending = InstallCoordinator.requests.get(id);
    if (pending !== undefined) return pending;
    const task = InstallCoordinator.tail.then(async () => {
      const store = await JobStore.open(context);
      const saved = await store.get(id);
      if (saved?.stage === InstallStage.WAITING_CERTIFICATE) {
        InstallCertificateSlots.request(id);
        return saved;
      }
      const account = await AccountService.current(context);
      const result = await new JobRunner(store, new NativeJobRuntime(context, store, account,
        new HdcDeviceBridge(context))).run(id);
      if (result.stage === InstallStage.INSTALLED) {
        try {
          if ((result.stagedTicket ?? '').length > 0 &&
            await new HdcDeviceBridge(context).discardStaged(result.stagedTicket)) {
            result.stagedTicket = ''; await store.save(result);
          }
          await store.pruneCompleted(context);
        } catch (_) {}
      }
      if (result.stage === InstallStage.WAITING_DEVICE) InstallReconnect.request(id);
      if (result.stage === InstallStage.WAITING_CONFIRMATION) InstallConfirmation.request(id);
      if (result.stage === InstallStage.WAITING_CERTIFICATE) InstallCertificateSlots.request(id,
        account ? JSON.stringify([account.userId, account.teamId]) : '');
      return result;
    });
    InstallCoordinator.requests.set(id, task);
    InstallCoordinator.tail = task.then(() => {}, () => {});
    task.finally(() => {
      InstallCoordinator.requests.delete(id);
      InstallCoordinator.wake().catch(() => {});
    }).catch(() => {});
    return task;
  }

  static async wake(): Promise<void> {
    const context = InstallCoordinator.context;
    if (!context || !InstallCoordinator.ready || InstallCoordinator.draining) return;
    InstallCoordinator.draining = true;
    try {
      const store = await JobStore.open(context);
      while (true) {
        if (JobScheduler.runningJobIds().length > 0 || InstallCoordinator.requests.size > 0) break;
        const account = await AccountService.current(context);
        const queued = (await store.listAll()).filter((job: InstallJob) =>
          job.stage === InstallStage.QUEUED && (job.appId > 0 || job.sourceUrl === 'local') &&
          (account !== undefined || LocalBundles.isSelfBundle(job.catalogBundleName || job.bundleName)))
          .sort((a: InstallJob, b: InstallJob) =>
            (a.stageHistory[0]?.at ?? a.updatedAt) - (b.stageHistory[0]?.at ?? b.updatedAt));
        const next = queued[0];
        if (next === undefined) break;
        try {
          const result = await InstallCoordinator.run(context, next.id);
          if (result.stage !== InstallStage.INSTALLED) break;
        } catch (_) { break; }
      }
    } finally { InstallCoordinator.draining = false; }
  }

  /** Retry only conditions changed by the user, never data-loss confirmation. */
  static async conditionReady(context: common.UIAbilityContext, stage: InstallStage): Promise<void> {
    const store = await JobStore.open(context);
    if (stage === InstallStage.WAITING_DEVICE) await store.cleanupCancelled(context);
    for (const job of await store.listAll()) {
      if (job.stage === stage && !JobScheduler.isRunning(job.id)) {
        job.stage = InstallStage.QUEUED;
        job.lastError = '';
        await store.save(job);
      }
    }
    await InstallCoordinator.recovered(context);
  }
}
