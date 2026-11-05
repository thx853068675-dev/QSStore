import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { url } from '@kit.ArkTS';
import { I18n } from './I18n';

export class GitHubMirrorSetting {
  enabled: boolean = false;
  address: string = '';
}

/** A local download route preference, loaded only when the caller needs it. */
export class GitHubMirrorPreferences {
  private static values: Map<string, GitHubMirrorSetting> = new Map();
  private static tails: Map<string, Promise<void>> = new Map();

  /** Only an HTTPS prefix is accepted; the original GitHub URL is appended to it. */
  static normalize(value: string): string {
    if (value.length === 0) return '';
    const invalid = I18n.t('请输入有效的 HTTPS 镜像地址，不含账号、空格或查询参数');
    if (!/^https:\/\//i.test(value) || /[\s\u0000-\u0020\u007f\\?#{}]/.test(value) ||
      /%(?![0-9a-f]{2})/i.test(value)) throw new Error(invalid);
    // URL parsers may silently discard an empty username or decode a host escape.
    const authority = value.substring(value.indexOf('://') + 3).split('/')[0];
    if (authority.includes('@') || authority.includes('%')) throw new Error(invalid);
    try {
      const parsed = new url.URL(value);
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash ||
        !parsed.hostname || parsed.hostname.length > 253 ||
        (parsed.port && (!/^\d+$/.test(parsed.port) || Number(parsed.port) < 1 || Number(parsed.port) > 65535))) {
        throw new Error(invalid);
      }
      if (parsed.hostname.startsWith('[')) {
        if (!/^\[[0-9a-f:.]+\]$/i.test(parsed.hostname)) throw new Error(invalid);
      } else {
        const host = parsed.hostname.endsWith('.') ? parsed.hostname.slice(0, -1) : parsed.hostname;
        if (!host.split('.').every((label: string) =>
          /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))) throw new Error(invalid);
      }
      return parsed.href.endsWith('/') ? parsed.href : parsed.href + '/';
    } catch (_) { throw new Error(invalid); }
  }

  private static copy(value: GitHubMirrorSetting): GitHubMirrorSetting {
    const result = new GitHubMirrorSetting();
    result.enabled = value.enabled;
    result.address = value.address;
    return result;
  }

  private static enqueue(context: common.UIAbilityContext,
    operation: () => Promise<GitHubMirrorSetting>): Promise<GitHubMirrorSetting> {
    const scope = context.filesDir;
    const previous = GitHubMirrorPreferences.tails.get(scope) ?? Promise.resolve();
    const work = previous.then(operation);
    const tail = work.then(() => {}, () => {});
    GitHubMirrorPreferences.tails.set(scope, tail);
    tail.then(() => {
      if (GitHubMirrorPreferences.tails.get(scope) === tail) GitHubMirrorPreferences.tails.delete(scope);
    });
    return work;
  }

  static load(context: common.UIAbilityContext): Promise<GitHubMirrorSetting> {
    return GitHubMirrorPreferences.enqueue(context, async (): Promise<GitHubMirrorSetting> => {
      const cached = GitHubMirrorPreferences.values.get(context.filesDir);
      if (cached !== undefined) return GitHubMirrorPreferences.copy(cached);
      try {
        const store = await preferences.getPreferences(context, 'qingqi-settings');
        const setting = new GitHubMirrorSetting();
        setting.enabled = (await store.get('githubMirrorEnabled', false)) === true;
        setting.address = GitHubMirrorPreferences.normalize(String(await store.get('githubMirrorAddress', '')));
        GitHubMirrorPreferences.values.set(context.filesDir, setting);
        return GitHubMirrorPreferences.copy(setting);
      } catch (_) {
        // A transient storage failure must not become a permanent cached route.
        return new GitHubMirrorSetting();
      }
    });
  }

  static async save(context: common.UIAbilityContext,
    setting: GitHubMirrorSetting): Promise<GitHubMirrorSetting> {
    // Validate and snapshot the caller's draft before enqueueing any storage work.
    const next = new GitHubMirrorSetting();
    next.enabled = setting.enabled === true;
    next.address = GitHubMirrorPreferences.normalize(setting.address);
    return GitHubMirrorPreferences.enqueue(context, async (): Promise<GitHubMirrorSetting> => {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      const previousEnabled = await store.get('githubMirrorEnabled', false);
      const previousAddress = String(await store.get('githubMirrorAddress', ''));
      let previous = GitHubMirrorPreferences.values.get(context.filesDir);
      if (previous === undefined) {
        try {
          previous = new GitHubMirrorSetting();
          previous.enabled = previousEnabled === true;
          previous.address = GitHubMirrorPreferences.normalize(previousAddress);
        } catch (_) { previous = undefined; }
      }
      try {
        await store.put('githubMirrorEnabled', next.enabled);
        await store.put('githubMirrorAddress', next.address);
        await store.flush();
      } catch (error) {
        // Preferences also holds pending writes in memory; do not leave a failed
        // choice available to a later read or an unrelated settings flush.
        try {
          await store.put('githubMirrorEnabled', previousEnabled);
          await store.put('githubMirrorAddress', previousAddress);
          await store.flush();
        } catch (_) {}
        if (previous !== undefined) GitHubMirrorPreferences.values.set(context.filesDir,
          GitHubMirrorPreferences.copy(previous));
        throw error as Error;
      }
      GitHubMirrorPreferences.values.set(context.filesDir, GitHubMirrorPreferences.copy(next));
      return GitHubMirrorPreferences.copy(next);
    });
  }
}
