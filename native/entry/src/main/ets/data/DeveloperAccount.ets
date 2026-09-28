import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';

export class DeveloperAccount {
  accessToken: string = '';
  jwtToken: string = '';
  userId: string = '';
  teamId: string = '';
  displayName: string = '';
  avatarUrl: string = '';

  get label(): string {
    return this.displayName.length > 0 && !this.displayName.includes('*') &&
      !this.displayName.includes('＊') ? this.displayName : this.userId;
  }

  static fromJson(row: Record<string, Object>): DeveloperAccount {
    const account = new DeveloperAccount();
    account.accessToken = String(row['accessToken'] ?? '');
    account.jwtToken = String(row['jwtToken'] ?? '');
    account.userId = String(row['userId'] ?? '');
    account.teamId = String(row['teamId'] ?? account.userId);
    account.displayName = String(row['displayName'] ?? row['nickName'] ?? '');
    const avatar = String(row['avatarUrl'] ?? '');
    account.avatarUrl = /^https:\/\//.test(avatar) ? avatar : '';
    return account;
  }

  toJson(): string {
    return JSON.stringify({
      accessToken: this.accessToken,
      jwtToken: this.jwtToken,
      userId: this.userId,
      teamId: this.teamId,
      displayName: this.displayName,
      avatarUrl: this.avatarUrl
    });
  }
}

// The preview has its own sandbox. Once a formally signed build uses the old
// bundle name, it can read this legacy file without requesting a new login or
// AGC certificate. Keep the source file intact until the migration is proven.
export class AccountSession {
  private static readonly STORE_NAME = 'developer-account';

  static async load(context: common.UIAbilityContext): Promise<DeveloperAccount | undefined> {
    const store = await preferences.getPreferences(context, AccountSession.STORE_NAME);
    const text = await store.get('session', '') as string;
    if (text.length > 0) {
      try {
        const account = DeveloperAccount.fromJson(JSON.parse(text) as Record<string, Object>);
        if (account.userId.length > 0 && account.jwtToken.length > 0) return account;
      } catch (_) {}
    }
    const legacyHandled = await store.get('legacyHandled', false) as boolean;
    if (legacyHandled) return undefined;
    const legacyPath = context.filesDir + '/agc_auth.json';
    if (!fileIo.accessSync(legacyPath)) return undefined;
    try {
      const account = DeveloperAccount.fromJson(
        JSON.parse(fileIo.readTextSync(legacyPath)) as Record<string, Object>);
      if (account.userId.length === 0 || account.jwtToken.length === 0 ||
        account.accessToken.length === 0) return undefined;
      await AccountSession.save(context, account);
      return account;
    } catch (_) {
      return undefined;
    }
  }

  static async save(context: common.UIAbilityContext, account: DeveloperAccount): Promise<void> {
    const store = await preferences.getPreferences(context, AccountSession.STORE_NAME);
    await store.put('session', account.toJson());
    await store.put('legacyHandled', true);
    await store.flush();
  }

  static async clear(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, AccountSession.STORE_NAME);
    await store.delete('session');
    await store.put('legacyHandled', true);
    await store.flush();
  }
}
