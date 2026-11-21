import { common, Want } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { AccountSession, DeveloperAccount } from './DeveloperAccount';
import { PrivacyConsent } from './PrivacyConsent';
import { StoreClient } from './StoreClient';
import { I18n } from './I18n';
import { errorText } from '../jobs/ErrorText';

class GitHubReturn {
  receipt: string = '';
  state: string = '';
  code: string = '';
}

export class GitHubAssociationReturn {
  private static pending: GitHubReturn | undefined;
  private static running: boolean = false;
  private static received: string = '';
  private static waitTimer: number = -1;

  static async start(context: common.UIAbilityContext, client: StoreClient, account: DeveloperAccount): Promise<void> {
    const url = await client.startGitHubAssociation(account);
    if (!url.startsWith('https://github.com/login/oauth/authorize?')) {
      throw new Error(I18n.t('GitHub 授权地址无效'));
    }
    GitHubAssociationReturn.setPhase('browser');
    try {
      await context.startAbility({ action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: url });
    } catch (error) {
      GitHubAssociationReturn.setPhase('');
      throw error as Error;
    }
  }

  static setPhase(phase: string): void {
    if (GitHubAssociationReturn.waitTimer !== -1) clearTimeout(GitHubAssociationReturn.waitTimer);
    GitHubAssociationReturn.waitTimer = -1;
    if (phase === 'browser') {
      GitHubAssociationReturn.waitTimer = setTimeout(() => {
        GitHubAssociationReturn.setPhase('');
      }, 600000);
    }
    AppStorage.setOrCreate('githubAssociationPhase', phase);
  }

  static receive(want: Want): boolean {
    const match = /^qingqi-installer:\/\/github-link\/?\?([^#]{1,2048})$/.exec(want.uri ?? '');
    if (!match) return false;
    const params = new Map<string, string>();
    try {
      for (const pair of match[1].split('&')) {
        const index = pair.indexOf('=');
        if (index < 1) return false;
        const name = pair.substring(0, index);
        if (params.has(name)) return false;
        params.set(name, decodeURIComponent(pair.substring(index + 1)));
      }
    } catch (_) { return false; }
    const result = new GitHubReturn();
    const shortKey = /^[A-Za-z0-9_-]{43}$/;
    const receipt = params.get('receipt') ?? '';
    const state = params.get('state') ?? '';
    const code = params.get('code') ?? '';
    if (shortKey.test(receipt) && params.size === 1) result.receipt = receipt;
    else if (shortKey.test(state) && (/^[A-Za-z0-9_-]{1,1024}$/.test(code) || params.get('error') === 'access_denied')) {
      result.state = state;
      result.code = code;
    } else return false;
    const received = result.state || result.receipt;
    if (received !== GitHubAssociationReturn.received) {
      GitHubAssociationReturn.received = received;
      GitHubAssociationReturn.pending = result;
    }
    return true;
  }

  static async openPending(context: common.UIAbilityContext, ui: UIContext): Promise<void> {
    if (!GitHubAssociationReturn.pending || GitHubAssociationReturn.running || !PrivacyConsent.isBusinessAllowed()) return;
    const result = GitHubAssociationReturn.pending;
    GitHubAssociationReturn.pending = undefined;
    GitHubAssociationReturn.running = true;
    GitHubAssociationReturn.setPhase('confirming');
    try {
      const account = await AccountSession.load(context);
      if (!account) throw new Error(I18n.t('请在发起授权的安装器账号中完成关联'));
      const client = new StoreClient(context);
      try {
        if (result.state) await client.confirmGitHubNativeAssociation(result.state, result.code, account);
        else await client.confirmGitHubAssociation(result.receipt, account);
      } catch (error) {
        // GitHub codes are single use. Check the binding before asking the user to authorize again.
        const status = await client.githubAssociationStatus(account).catch(() => undefined);
        if (!status?.login) throw error as Error;
      }
      GitHubAssociationReturn.setPhase('');
      const revision = AppStorage.get<number>('githubAssociationRevision') ?? 0;
      AppStorage.setOrCreate('githubAssociationRevision', revision + 1);
      ui.getPromptAction().showToast({ message: I18n.t('GitHub 已关联') });
    } catch (error) {
      AppStorage.setOrCreate('githubAssociationFailure', errorText(error));
      GitHubAssociationReturn.setPhase('failed');
      ui.getPromptAction().showToast({ message: errorText(error) });
    } finally {
      GitHubAssociationReturn.running = false;
      if (GitHubAssociationReturn.pending) GitHubAssociationReturn.openPending(context, ui);
    }
  }
}
