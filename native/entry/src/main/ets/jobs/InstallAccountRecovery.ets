import { I18n } from '../data/I18n';

/** Only session errors request sign-in; ACL, quotas and network failures do not. */
export class InstallAccountRecovery {
  private static requested: string = '';
  private static expected: string = '';
  private static owner: number = -1;
  private static next: number = 0;
  private static listeners: Map<number, (job: string) => void> = new Map();
  static requiresLogin(message: string): boolean {
    return [I18n.t('华为账号返回的信息不完整'), I18n.t('华为登录态已失效，请重新登录'),
      I18n.t('登录已过期，请重新登录'), I18n.t('账号身份发生变化，请重新登录'),
      I18n.t('请先登录华为开发者账号')].some((text: string) => text.length > 0 && message.includes(text));
  }
  static subscribe(callback: (job: string) => void): number {
    const id = ++InstallAccountRecovery.next; InstallAccountRecovery.listeners.set(id, callback); return id;
  }
  private static notify(id: number, job: string): void { try { InstallAccountRecovery.listeners.get(id)?.(job); } catch (_) {} }
  static activate(id: number): void {
    if (InstallAccountRecovery.owner !== id) InstallAccountRecovery.notify(InstallAccountRecovery.owner, '');
    InstallAccountRecovery.owner = id; InstallAccountRecovery.notify(id, InstallAccountRecovery.requested);
  }
  static deactivate(id: number): void {
    if (InstallAccountRecovery.owner !== id) return;
    InstallAccountRecovery.notify(id, ''); InstallAccountRecovery.owner = -1;
  }
  static unsubscribe(id: number): void { InstallAccountRecovery.deactivate(id); InstallAccountRecovery.listeners.delete(id); }
  static isOwner(id: number): boolean { return id > 0 && InstallAccountRecovery.owner === id; }
  static isRequested(job: string): boolean { return job.length > 0 && InstallAccountRecovery.requested === job; }
  static scope(job: string): string { return InstallAccountRecovery.isRequested(job) ? InstallAccountRecovery.expected : ''; }
  static request(job: string, scope: string): void {
    if (!job || InstallAccountRecovery.requested) return;
    AppStorage.setOrCreate('accountReauthRequired', true);
    InstallAccountRecovery.requested = job; InstallAccountRecovery.expected = scope;
    InstallAccountRecovery.notify(InstallAccountRecovery.owner, job);
  }
  static clear(job: string): void {
    if (!InstallAccountRecovery.isRequested(job)) return;
    InstallAccountRecovery.requested = ''; InstallAccountRecovery.expected = '';
    InstallAccountRecovery.notify(InstallAccountRecovery.owner, '');
  }
}
