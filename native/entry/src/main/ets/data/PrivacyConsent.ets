import { common } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';
import { I18n } from './I18n';

// The AGC candidate builder enables this temporarily and restores the source.
// Existing public sideload builds retain their current initialization path.
export const INVITE_PRIVACY_MANAGED = false;

/** Official hosted agreement consent; it does not grant optional cloud-key backup consent. */
export class PrivacyConsent {
  private static allowed: boolean = !INVITE_PRIVACY_MANAGED;
  private static revoked: boolean = false;
  private static error: string = '';
  private static agreementLinks: privacyManager.AppPrivacyLink[] = [];
  private static subscriber: commonEventManager.CommonEventSubscriber | undefined;
  private static subscribing: boolean = false;
  private static pending: Promise<boolean> | undefined;
  private static generation: number = 0;
  private static nextListener: number = 1;
  private static listeners: Map<number, () => void> = new Map();

  static isManaged(): boolean { return INVITE_PRIVACY_MANAGED; }
  static isBusinessAllowed(): boolean { return !INVITE_PRIVACY_MANAGED || PrivacyConsent.allowed; }
  static lastError(): string { return PrivacyConsent.error; }
  static assertBusinessAllowed(): void {
    if (!PrivacyConsent.isBusinessAllowed()) {
      // Existing durable account-wait recovery retains packages and resumes after consent.
      throw new ServiceFailure(FailureKind.ACCOUNT, I18n.t('请先阅读并同意隐私声明'));
    }
  }
  static subscribe(listener: () => void): number {
    const id = PrivacyConsent.nextListener++;
    PrivacyConsent.listeners.set(id, listener);
    return id;
  }
  static unsubscribe(id: number): void { PrivacyConsent.listeners.delete(id); }

  private static publish(allowed: boolean, error: string): boolean {
    const changed = PrivacyConsent.allowed !== allowed || PrivacyConsent.error !== error;
    PrivacyConsent.allowed = allowed;
    PrivacyConsent.error = error;
    if (changed) PrivacyConsent.listeners.forEach((listener: () => void) => {
      try { listener(); } catch (_) { /* One disposed UI observer cannot change consent. */ }
    });
    return allowed;
  }

  static configure(context: common.UIAbilityContext): void {
    if (!INVITE_PRIVACY_MANAGED) return;
    PrivacyConsent.refresh();
    if (PrivacyConsent.subscriber || PrivacyConsent.subscribing) return;
    PrivacyConsent.subscribing = true;
    commonEventManager.createSubscriber({ events: ['usual.event.PRIVACY_STATE_CHANGED'] })
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        PrivacyConsent.subscriber = subscriber;
        commonEventManager.subscribe(subscriber, () => {
          // The broadcast is only a wakeup. Always verify this app's current IDs and versions.
          PrivacyConsent.refresh();
        });
      }).catch(() => {
        PrivacyConsent.subscriber = undefined;
        // Foreground checks and the direct system-dialog result remain usable.
      }).finally(() => { PrivacyConsent.subscribing = false; });
  }

  static refresh(): boolean {
    if (!INVITE_PRIVACY_MANAGED) return true;
    if (PrivacyConsent.revoked) return PrivacyConsent.publish(false, PrivacyConsent.error);
    try {
      const info = privacyManager.getAppPrivacyMgmtInfo();
      PrivacyConsent.agreementLinks = info.privacyInfo;
      if (info.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE ||
        !info.privacyInfo.some((link: privacyManager.AppPrivacyLink) =>
          link.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK &&
          link.id.length > 0 && /^https:\/\//.test(link.url))) {
        return PrivacyConsent.publish(false, I18n.t('隐私声明尚未就绪，请稍后重试'));
      }
      const results = privacyManager.getAppPrivacyResult();
      const allowed = info.privacyInfo.every((link: privacyManager.AppPrivacyLink) => {
        const type = link.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK ?
          privacyManager.AppPrivacyType.PRIVACY_AGREEMENT : privacyManager.AppPrivacyType.USER_AGREEMENT;
        return link.id.length > 0 && Number.isSafeInteger(link.versionCode) && link.versionCode >= 0 &&
          results.some((row: privacyManager.AppPrivacyResult) =>
          row.type === type && row.id === link.id && row.versionCode === link.versionCode &&
          row.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED);
      });
      return PrivacyConsent.publish(allowed, allowed ? '' : I18n.t('同意隐私声明后即可继续使用'));
    } catch (_) {
      PrivacyConsent.agreementLinks = [];
      // Includes 1006700003: this candidate has not been attached to a hosted agreement.
      return PrivacyConsent.publish(false, I18n.t('暂时无法读取隐私声明，请稍后重试'));
    }
  }

  static links(): privacyManager.AppPrivacyLink[] {
    if (!INVITE_PRIVACY_MANAGED) return [];
    if (PrivacyConsent.agreementLinks.length === 0) PrivacyConsent.refresh();
    return PrivacyConsent.agreementLinks.slice();
  }

  static ensureConsent(context: common.UIAbilityContext): Promise<boolean> {
    if (!INVITE_PRIVACY_MANAGED) return Promise.resolve(true);
    if (PrivacyConsent.pending) return PrivacyConsent.pending;
    if (PrivacyConsent.refresh()) return Promise.resolve(true);
    PrivacyConsent.revoked = false;
    const generation = PrivacyConsent.generation;
    const request = (async (): Promise<boolean> => {
      try {
        await privacyManager.requestAppPrivacyConsent(context);
        if (generation !== PrivacyConsent.generation) return false;
        return PrivacyConsent.refresh();
      } catch (_) {
        if (generation === PrivacyConsent.generation) {
          PrivacyConsent.publish(false, I18n.t('暂时无法打开隐私声明，请稍后重试'));
        }
        return false;
      }
    })();
    PrivacyConsent.pending = request;
    request.finally(() => {
      if (PrivacyConsent.pending === request) PrivacyConsent.pending = undefined;
    });
    return request;
  }

  static withdraw(): void {
    if (!INVITE_PRIVACY_MANAGED) return;
    PrivacyConsent.generation++;
    PrivacyConsent.revoked = true;
    PrivacyConsent.publish(false, I18n.t('已撤回同意'));
    try { privacyManager.disableService(); }
    catch (_) {
      PrivacyConsent.publish(false, I18n.t('已停止后续业务，系统撤回未完成，请重试'));
      throw new Error(I18n.t('系统撤回未完成，请重试'));
    }
  }
}
