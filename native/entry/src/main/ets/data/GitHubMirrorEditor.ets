import { common } from '@kit.AbilityKit';
import { GitHubMirrorPreferences, GitHubMirrorSetting } from './GitHubMirrorPreferences';
import { GitHubMirrorProbe } from './GitHubMirrorProbe';
import { I18n } from './I18n';

export class GitHubMirrorView {
  enabled: boolean = false;
  address: string = '';
  ready: boolean = false;
  checking: boolean = false;
  state: string = 'idle';
  message: string = '';
}

/** Keep durable choices and asynchronous checks separate from the input draft. */
export class GitHubMirrorEditor {
  private view: GitHubMirrorView = new GitHubMirrorView();
  private saved: GitHubMirrorSetting = new GitHubMirrorSetting();
  private pendingWrites: number = 0;
  private lastValidAddress: string = '';
  private revision: number = 0;
  private timer: number = -1;
  private disposed: boolean = false;
  private probe: GitHubMirrorProbe = new GitHubMirrorProbe();
  private context: common.UIAbilityContext;
  private notify: (view: GitHubMirrorView) => void;

  constructor(context: common.UIAbilityContext, notify: (view: GitHubMirrorView) => void) {
    this.context = context;
    this.notify = notify;
  }

  private publish(): void {
    if (this.disposed) return;
    const copy = new GitHubMirrorView();
    copy.enabled = this.view.enabled; copy.address = this.view.address; copy.ready = this.view.ready;
    copy.checking = this.view.checking; copy.state = this.view.state; copy.message = this.view.message;
    this.notify(copy);
  }

  async load(): Promise<void> {
    const revision = this.revision;
    const setting = await GitHubMirrorPreferences.load(this.context);
    if (this.disposed || revision !== this.revision) return;
    this.saved = setting;
    this.lastValidAddress = setting.address;
    this.view.enabled = setting.enabled;
    this.view.address = setting.address;
    this.view.ready = true;
    this.publish();
    if (setting.enabled && setting.address) this.commit(true);
  }

  private invalidate(): void {
    this.revision++;
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    this.probe.cancel();
    this.view.checking = false;
  }

  toggle(enabled: boolean): void {
    if (this.disposed || !this.view.ready || enabled === this.view.enabled) return;
    this.invalidate();
    this.view.enabled = enabled;
    this.view.state = 'idle';
    this.view.message = this.view.address.trim() ? I18n.t('正在保存…') : '';
    this.publish();
    this.commit(enabled);
  }

  edit(value: string): void {
    if (this.disposed || !this.view.ready || !this.view.enabled || value === this.view.address) return;
    this.invalidate();
    this.view.address = value;
    this.view.state = 'idle';
    this.view.message = value.trim() ? I18n.t('输入后自动保存并检验') : '';
    this.publish();
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.commit(true);
    }, 600);
  }

  private async commit(check: boolean): Promise<void> {
    const revision = this.revision;
    const setting = new GitHubMirrorSetting();
    setting.enabled = this.view.enabled;
    try {
      setting.address = GitHubMirrorPreferences.normalize(this.view.address.trim());
      this.lastValidAddress = setting.address;
    }
    catch (_) {
      // Closing the switch still works when the unsaved draft is invalid.
      if (!setting.enabled) setting.address = this.lastValidAddress;
      else {
        this.view.state = 'warning';
        this.view.message = I18n.t('请输入有效的 HTTPS 镜像地址');
        this.publish();
        return;
      }
    }
    try {
      if (this.pendingWrites > 0 || setting.enabled !== this.saved.enabled || setting.address !== this.saved.address) {
        this.pendingWrites++;
        try { this.saved = await GitHubMirrorPreferences.save(this.context, setting); }
        finally { this.pendingWrites--; }
      }
      if (this.disposed || revision !== this.revision) return;
      if (!setting.enabled) return;
      if (!setting.address) {
        this.view.state = 'idle'; this.view.message = '';
        this.publish(); return;
      }
      if (!check) {
        this.view.state = 'unconfirmed'; this.view.message = I18n.t('地址已保存，下载时检验');
        this.publish(); return;
      }
      this.view.checking = true;
      this.view.state = 'checking'; this.view.message = I18n.t('地址已保存，正在检验…');
      this.publish();
      const result = await this.probe.check(this.context, setting.address);
      if (this.disposed || revision !== this.revision) return;
      this.view.checking = false;
      this.view.state = result.state; this.view.message = result.message;
      this.publish();
    } catch (_) {
      if (this.disposed || revision !== this.revision) return;
      // Restore only the durable switch; keep the input for a later correction.
      this.view.enabled = this.saved.enabled;
      this.view.checking = false; this.view.state = 'warning';
      this.view.message = I18n.t('未能保存，请稍后重试');
      this.publish();
    }
  }

  pause(): void {
    if (this.disposed || !this.view.ready) return;
    this.invalidate();
    // Do not lose the last valid keystrokes when leaving before the debounce.
    this.commit(false);
  }

  dispose(): void {
    this.pause();
    this.disposed = true;
    this.invalidate();
  }
}
