import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AgcClient } from './AgcClient';
import { DeveloperAccount } from './DeveloperAccount';
import { SigningIdentityRecovery } from './SigningIdentity';

class ProfileLease {
  id: string = '';
  accountId: string = '';
  teamId: string = '';
}

/** Only creation receipts identify records that this installer owns. */
export class AgcProfileLease {
  private static path(context: common.UIAbilityContext): string {
    return context.filesDir + '/agc-profile-leases.json';
  }

  private static read(context: common.UIAbilityContext): ProfileLease[] {
    const path = AgcProfileLease.path(context);
    if (!fileIo.accessSync(path)) return [];
    // Do not silently discard damaged receipts and leak more cloud records.
    const rows = JSON.parse(fileIo.readTextSync(path)) as ProfileLease[];
    if (!Array.isArray(rows) || rows.length > 200) throw new Error('授权回收记录损坏，请重试');
    if (rows.some((row: ProfileLease) => !row || typeof row.id !== 'string' ||
      !/^[A-Za-z0-9_-]{1,32}$/.test(row.id) || typeof row.accountId !== 'string' ||
      row.accountId.length === 0 || typeof row.teamId !== 'string' || row.teamId.length === 0)) {
      throw new Error('授权回收记录损坏，请重试');
    }
    return rows;
  }

  private static save(context: common.UIAbilityContext, rows: ProfileLease[]): void {
    const path = AgcProfileLease.path(context), temporary = path + '.part';
    SigningIdentityRecovery.writeFile(temporary,
      new util.TextEncoder().encodeInto(JSON.stringify(rows)).buffer as ArrayBuffer);
    fileIo.renameSync(temporary, path);
  }

  static remember(context: common.UIAbilityContext, account: DeveloperAccount, id: string): void {
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(id) || !account.userId || !account.teamId) {
      throw new Error('授权回收记录无效，已停止申请');
    }
    const rows = AgcProfileLease.read(context);
    if (rows.some((row: ProfileLease) => row.id === id && row.accountId === account.userId &&
      row.teamId === account.teamId)) return;
    if (rows.length >= 200) throw new Error('待回收的授权记录过多，请恢复网络后重试');
    const row = new ProfileLease();
    row.id = id; row.accountId = account.userId; row.teamId = account.teamId;
    rows.push(row); AgcProfileLease.save(context, rows);
  }

  static async release(context: common.UIAbilityContext, account: DeveloperAccount,
    agc: AgcClient, id: string): Promise<boolean> {
    try {
      await agc.deleteProfile(id);
      const rows = AgcProfileLease.read(context).filter((row: ProfileLease) =>
        !(row.id === id && row.accountId === account.userId && row.teamId === account.teamId));
      AgcProfileLease.save(context, rows);
      return true;
    } catch (_) {
      console.warn('AGC temporary profile cleanup deferred');
      return false;
    }
  }

  static async recover(context: common.UIAbilityContext, account: DeveloperAccount,
    agc: AgcClient): Promise<number> {
    const rows = AgcProfileLease.read(context).filter((row: ProfileLease) =>
      row.accountId === account.userId && row.teamId === account.teamId);
    let released = 0;
    for (const row of rows) {
      if (await AgcProfileLease.release(context, account, agc, row.id)) released++;
      else break; // One unavailable service must not trigger a cleanup storm.
    }
    return released;
  }
}
