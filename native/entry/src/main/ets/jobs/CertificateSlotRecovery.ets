import { common } from '@kit.AbilityKit';
import { AccountService } from '../data/AccountService';
import { DeveloperAccount } from '../data/DeveloperAccount';
import { AgcClient } from '../data/AgcClient';
import { SigningIdentityRecovery } from '../data/SigningIdentity';
import { InstallCoordinator } from './InstallCoordinator';
import { InstallCertificateSlots } from './InstallCertificateSlots';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';

export class CertificateSlotRow {
  id: string = '';
  name: string = '';
  expiresAt: number = 0;
  inUse: boolean = false;
}

/** No enrollment is needed to list/delete: first-time users have no identity yet. */
export class CertificateSlotRecovery {
  private static operations: Map<string, Promise<InstallJob>> = new Map();
  private static async account(context: common.UIAbilityContext, userId: string,
    teamId: string): Promise<DeveloperAccount> {
    const account = await AccountService.current(context);
    if (!account || account.userId !== userId || account.teamId !== teamId) {
      throw new Error('开发者账号已改变，请关闭窗口后重新安装');
    }
    return account;
  }

  private static async waiting(context: common.UIAbilityContext, id: string): Promise<InstallJob> {
    const job = await (await JobStore.open(context)).get(id);
    if (!job || job.stage !== InstallStage.WAITING_CERTIFICATE) {
      throw new Error('原安装任务已取消或状态已改变');
    }
    return job;
  }

  static async list(context: common.UIAbilityContext, userId: string,
    teamId: string): Promise<CertificateSlotRow[]> {
    const account = await CertificateSlotRecovery.account(context, userId, teamId);
    const records = await new AgcClient(account).certificates();
    const current = await SigningIdentityRecovery.load(context, account, true);
    await CertificateSlotRecovery.account(context, userId, teamId);
    return records.filter((row: Record<string, Object>) => Number(row['certType']) === 1 &&
      String(row['id'] ?? '').length > 0).map((row: Record<string, Object>) => {
      const result = new CertificateSlotRow();
      result.id = String(row['id']);
      result.name = String(row['certName'] ?? '') || result.id;
      result.expiresAt = SigningIdentityRecovery.expirySeconds(row['expireTime']);
      result.inUse = result.id === current?.certId;
      return result;
    });
  }

  static async resume(context: common.UIAbilityContext, id: string, userId: string,
    teamId: string): Promise<InstallJob> {
    if (CertificateSlotRecovery.operations.has(context.filesDir + ':' + id)) {
      throw new Error('证书操作正在处理中，请稍候');
    }
    return CertificateSlotRecovery.resumeLocked(context, id, userId, teamId);
  }

  private static async resumeLocked(context: common.UIAbilityContext, id: string, userId: string,
    teamId: string): Promise<InstallJob> {
    await CertificateSlotRecovery.account(context, userId, teamId);
    const job = await CertificateSlotRecovery.waiting(context, id);
    // Recovery validates retained files. No source path, key, Profile or consent is cleared.
    job.stage = InstallStage.QUEUED;
    job.lastError = '';
    await (await JobStore.open(context)).save(job);
    InstallCertificateSlots.clear(id);
    return InstallCoordinator.run(context, id);
  }

  static async deleteAndResume(context: common.UIAbilityContext, id: string, userId: string,
    teamId: string, certId: string): Promise<InstallJob> {
    const key = context.filesDir + ':' + id;
    if (CertificateSlotRecovery.operations.has(key)) throw new Error('证书操作正在处理中，请稍候');
    const task = CertificateSlotRecovery.deleteLocked(context, id, userId, teamId, certId);
    CertificateSlotRecovery.operations.set(key, task);
    try { return await task; }
    finally { CertificateSlotRecovery.operations.delete(key); }
  }

  private static async deleteLocked(context: common.UIAbilityContext, id: string, userId: string,
    teamId: string, certId: string): Promise<InstallJob> {
    const account = await CertificateSlotRecovery.account(context, userId, teamId);
    await CertificateSlotRecovery.waiting(context, id);
    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const selected = rows.find((row: Record<string, Object>) => String(row['id'] ?? '') === certId &&
      Number(row['certType']) === 1);
    if (selected !== undefined) {
      await SigningIdentityRecovery.prepareCertificateDeletion(context, account, certId);
      await CertificateSlotRecovery.account(context, userId, teamId);
      await CertificateSlotRecovery.waiting(context, id);
      await SigningIdentityRecovery.beginCertificateDeletion(context, account, certId);
      try { await agc.deleteCertificates([certId]); }
      catch (error) {
        // A lost response is not proof of rejection. Keep the tombstone until AGC confirms.
        let remaining: Array<Record<string, Object>>;
        try { remaining = await agc.certificates(); }
        catch (_) { throw new Error('证书删除结果暂时无法确认，请刷新核对后继续安装'); }
        if (remaining.some((row: Record<string, Object>) => String(row['id'] ?? '') === certId)) {
          await SigningIdentityRecovery.cancelCertificateDeletion(context, account, certId);
          throw error as Error;
        }
      }
      await SigningIdentityRecovery.finishCertificateDeletion(context, account, certId);
    }
    return CertificateSlotRecovery.resumeLocked(context, id, userId, teamId);
  }
}
