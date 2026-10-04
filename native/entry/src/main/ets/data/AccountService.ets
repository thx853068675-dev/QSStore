import { common } from '@kit.AbilityKit';
import { AccountSession, DeveloperAccount } from './DeveloperAccount';
import { DevEcoLogin, isTransientAuthError, authErrorText } from './DevEcoLogin';
import { ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';

/** One refresh per identity, shared by pages, AGC and the install executor. */
export class AccountService {
  private static context: common.UIAbilityContext | undefined;
  private static pending: Map<string, Promise<DeveloperAccount>> = new Map();
  private static refreshedAt: Map<string, number> = new Map();
  static configure(context: common.UIAbilityContext): void { AccountService.context = context; }

  static async current(context: common.UIAbilityContext): Promise<DeveloperAccount | undefined> {
    AccountService.configure(context);
    return AccountSession.load(context);
  }

  static async refresh(account: DeveloperAccount, force: boolean = false): Promise<DeveloperAccount> {
    const key = account.userId + ':' + account.jwtToken;
    if (!force && Date.now() - (AccountService.refreshedAt.get(key) ?? 0) < 300000) return account;
    let task = AccountService.pending.get(key);
    if (task === undefined) {
      task = DevEcoLogin.refresh(account).then(async (fresh: DeveloperAccount) => {
        const context = AccountService.context;
        if (context !== undefined) {
          const current = await AccountSession.load(context);
          // A late refresh must never restore a logged-out or switched account.
          if (current?.userId === account.userId && current.jwtToken === account.jwtToken) {
            await AccountSession.save(context, fresh);
          }
        }
        if (AccountService.refreshedAt.size >= 8) AccountService.refreshedAt.clear();
        AccountService.refreshedAt.set(key, Date.now());
        return fresh;
      }).catch((error: Object) => {
        throw new ServiceFailure(isTransientAuthError(error) ? FailureKind.NETWORK : FailureKind.ACCOUNT,
          authErrorText(error));
      }).finally(() => { AccountService.pending.delete(key); });
      AccountService.pending.set(key, task);
    }
    const fresh = await task;
    account.accessToken = fresh.accessToken;
    account.teamId = fresh.teamId;
    account.displayName = fresh.displayName;
    account.avatarUrl = fresh.avatarUrl;
    account.realNameVerified = fresh.realNameVerified;
    return account;
  }
}
