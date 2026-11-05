import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DeveloperAccount } from './DeveloperAccount';
import { PrivacyConsent } from './PrivacyConsent';
import { I18n } from './I18n';

/** Invited users choose cloud recovery separately from the managed privacy agreement. */
export class CloudBackupConsent {
  private static decisions: Map<string, boolean> = new Map();
  private static revisions: Map<string, number> = new Map();
  private static writes: Map<string, Promise<void>> = new Map();

  private static scope(context: common.UIAbilityContext, account: DeveloperAccount): string {
    return context.filesDir + ':' + account.userId;
  }

  static async selected(context: common.UIAbilityContext, account: DeveloperAccount): Promise<boolean> {
    if (!PrivacyConsent.isManaged()) return true;
    if (account.userId.length === 0) return false;
    const scope = CloudBackupConsent.scope(context, account);
    const cached = CloudBackupConsent.decisions.get(scope);
    if (cached !== undefined) return cached;
    const revision = CloudBackupConsent.revisions.get(scope) ?? 0;
    try {
      const store = await preferences.getPreferences(context, 'cloud-backup-consent');
      const enabled = await store.get('account:' + account.userId, false) as boolean;
      // A slow initial read must not restore a choice that was just disabled.
      if ((CloudBackupConsent.revisions.get(scope) ?? 0) !== revision) {
        return CloudBackupConsent.decisions.get(scope) ?? false;
      }
      CloudBackupConsent.decisions.set(scope, enabled === true);
      return enabled === true;
    } catch (_) { return false; }
  }

  static async allowed(context: common.UIAbilityContext, account: DeveloperAccount): Promise<boolean> {
    if (!PrivacyConsent.isBusinessAllowed()) return false;
    const selected = await CloudBackupConsent.selected(context, account);
    return selected && CloudBackupConsent.isAllowedNow(context, account);
  }

  /** Recheck immediately before sending; no await may separate this from request(). */
  static isAllowedNow(context: common.UIAbilityContext, account: DeveloperAccount): boolean {
    return PrivacyConsent.isBusinessAllowed() && (!PrivacyConsent.isManaged() ||
      CloudBackupConsent.decisions.get(CloudBackupConsent.scope(context, account)) === true);
  }

  static async setEnabled(context: common.UIAbilityContext, account: DeveloperAccount,
    enabled: boolean): Promise<void> {
    if (!PrivacyConsent.isManaged()) return;
    if (account.userId.length === 0) throw new Error(I18n.t('请先登录华为开发者账号'));
    if (enabled) PrivacyConsent.assertBusinessAllowed();
    const scope = CloudBackupConsent.scope(context, account);
    const revision = (CloudBackupConsent.revisions.get(scope) ?? 0) + 1;
    CloudBackupConsent.revisions.set(scope, revision);
    // Revoke synchronously. Enabling is effective only after durable storage.
    CloudBackupConsent.decisions.set(scope, false);
    const previous = CloudBackupConsent.writes.get(scope);
    const save = (async (): Promise<void> => {
      if (previous) { try { await previous; } catch (_) {} }
      if (enabled) PrivacyConsent.assertBusinessAllowed();
      const store = await preferences.getPreferences(context, 'cloud-backup-consent');
      await store.put('account:' + account.userId, enabled);
      await store.flush();
      if ((CloudBackupConsent.revisions.get(scope) ?? 0) === revision) {
        CloudBackupConsent.decisions.set(scope, enabled);
      }
    })();
    CloudBackupConsent.writes.set(scope, save);
    try { await save; }
    finally { if (CloudBackupConsent.writes.get(scope) === save) CloudBackupConsent.writes.delete(scope); }
  }
}
