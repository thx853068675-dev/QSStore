import { common } from '@kit.AbilityKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { profileMatchesCertificate, readSignedProfile } from 'libhap_core.so';
import { ClassifiedFailure, ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';
import { AgcClient, CreatedAgcProfile } from './AgcClient';
import { AgcProfileLease } from './AgcProfileLease';
import { AgcManagedProfile } from './AgcManagedProfile';
import { DeveloperAccount } from './DeveloperAccount';
import { LocalSigningIdentity, SigningIdentityRecovery } from './SigningIdentity';
import { isMissingCertificate } from './CertificateRejection';
import { SideloadAclPolicy } from './SideloadAclPolicy';
import { I18n } from './I18n';

class DeviceRegistration {
  ids: string[] = [];
  verifiedAt: number = 0;
}

export class ProfileRefreshOptions {
  requestId: string = '';
  minimumExpiry: number = 0;
}

export class AgcProfile {
  private static registrations: Map<string, DeviceRegistration> = new Map();
  private static issuing: Map<string, Promise<void>> = new Map();
  private static readonly REGISTRATION_TTL_MS: number = 10 * 60 * 1000;

  private static isAutomaticLimit(error: Error): boolean {
    return Number((error as ServiceFailure).status ?? 0) === 205389938 ||
      /sign\s+ide\s+test\s+provision\s+number\s+exceeds?\s+limit/i.test(String(error));
  }

  /** AGC 205389941: a requested ACL is not in the automatic signing support scope. */
  private static isScopeRefusal(error: Error): boolean {
    return Number((error as ServiceFailure).status ?? 0) === 205389941 ||
      /permission\s+not\s+in\s+support\s+scope/i.test(String(error));
  }

  /**
   * A scope refusal means the IDE auto-signing path cannot request one of the
   * declared ACLs. Re-registering the device cannot change that, so fall back to
   * the approved-ACL route when it covers the requirement and otherwise report
   * exactly which permissions need an AGC approval.
   */
  private static async recoverFromScopeRefusal(context: common.UIAbilityContext, agc: AgcClient,
    account: DeveloperAccount, identity: LocalSigningIdentity, bundleName: string, udid: string, ids: string[],
    acls: string[], requiringApproval: string[], temporary: string, valid: (path: string) => boolean,
    refreshRequest: string): Promise<void> {
    // The SDK catalog can recognize an ACL that the IDE scope still refuses.
    // Distinguish that drift from an ACL this build never catalogued at all.
    const outsideCatalog = SideloadAclPolicy.unrecognized(requiringApproval);
    const blocker = outsideCatalog.length > 0 ? outsideCatalog : requiringApproval;
    try {
      const appId = await AgcManagedProfile.appId(agc, bundleName, account);
      const approved = await agc.approvedAcls(appId);
      if (!SideloadAclPolicy.covered(acls, approved)) throw AgcProfile.scopeFailure(blocker, acls, approved);
      await AgcManagedProfile.obtain(agc, account, identity.certId, ids, acls, bundleName, temporary, valid, udid,
        refreshRequest);
    } catch (error) {
      if (AgcProfile.isAutomaticLimit(error as Error)) throw error as Error;
      if ((error as ClassifiedFailure).failureKind === FailureKind.ACCOUNT ||
        (error as ClassifiedFailure).failureKind === FailureKind.NETWORK) throw error as Error;
      throw AgcProfile.scopeFailure(blocker, acls, []);
    }
  }

  private static scopeFailure(blocker: string[], acls: string[], approved: string[]): ServiceFailure {
    const pending = blocker.filter((acl: string) => !approved.includes(acl));
    return new ServiceFailure(FailureKind.ACCOUNT,
      I18n.t('AGC 不支持自动签名申请这些权限：') + (pending.length > 0 ? pending : blocker).join(I18n.t('、')) +
      I18n.t('。自动签名只能申请 IDE 自动授权范围内的 ACL，其余权限需先在 AGC 为此应用申请并获批；当前已保留全部 ') +
      acls.length + I18n.t(' 项权限声明和现有应用，未降级签名。'), 205389941);
  }

  private static async registeredDeviceIds(agc: AgcClient, udid: string): Promise<string[]> {
    let devices = await agc.devices();
    if (!devices.some((item: Record<string, Object>) => String(item['udid'] ?? '') === udid)) {
      await agc.registerDevice(udid);
      devices = await agc.devices();
    }
    const ids = devices.filter((item: Record<string, Object>) =>
      String(item['udid'] ?? '') === udid).map((item: Record<string, Object>) =>
      String(item['id'] ?? '')).filter((id: string) => id.length > 0).sort();
    if (ids.length === 0) throw new Error(I18n.t('AGC 设备登记尚未生效'));
    return ids;
  }
  private static async fingerprintOfPem(pem: string): Promise<string> {
    const match = /-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----/.exec(pem);
    if (!match) throw new Error(I18n.t('签名证书格式无效'));
    const der = new util.Base64Helper().decodeSync(match[1].replace(/\s/g, ''));
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: der });
    const digest = (await md.digest()).data;
    let fingerprint = '';
    for (let i = 0; i < digest.length; i++) {
      fingerprint += digest[i].toString(16).padStart(2, '0');
    }
    return fingerprint.toUpperCase();
  }

  /** 对 Profile 内实际签包证书求指纹，而不是误用 .cer 文件里的根证书。 */
  static async signingFingerprint(path: string): Promise<string> {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
    const pem = String(bundle?.['development-certificate'] ?? '');
    return AgcProfile.fingerprintOfPem(pem);
  }

  static appIdentifier(path: string): string {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
    return String(bundle?.['app-identifier'] ?? '');
  }

  /** The signing certificate can expire before the Profile's advertised end. */
  static effectiveExpiry(path: string, certificateExpiry: number): number {
    if (!Number.isFinite(certificateExpiry) || certificateExpiry <= 0) {
      throw new Error(I18n.t('无法核对签名证书有效期，请刷新证书信息后重试'));
    }
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const validity = profile['validity'] as Record<string, Object> | undefined;
    const expiry = Number(validity?.['not-after'] ?? 0);
    if (!Number.isFinite(expiry) || expiry <= 0) throw new Error(I18n.t('设备授权未提供有效的到期时间'));
    return Math.floor(Math.min(expiry, certificateExpiry));
  }

  static profileExpiry(path: string): number {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const validity = profile['validity'] as Record<string, Object> | undefined;
    const expiry = Number(validity?.['not-after'] ?? 0);
    return Number.isFinite(expiry) && expiry > 0 ? Math.floor(expiry) : 0;
  }

  /** Ordinary installs keep valid local Profiles; renewal requires a useful extension and a young Profile. */
  static reusableForRenewal(path: string, certificateExpiry: number, minimumExpiry: number): boolean {
    try {
      const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
      const validity = profile['validity'] as Record<string, Object> | undefined;
      const before = Number(validity?.['not-before'] ?? 0);
      const after = Number(validity?.['not-after'] ?? 0);
      const now = Date.now() / 1000;
      return Number.isFinite(before) && before > 0 && Number.isFinite(after) && after > before &&
        Number.isFinite(certificateExpiry) && certificateExpiry > 0 &&
        before <= now && now < before + (after - before) / 2 &&
        Math.floor(Math.min(after, certificateExpiry)) > minimumExpiry;
    } catch (_) { return false; }
  }

  static effectiveAcls(requested: string[]): string[] {
    return SideloadAclPolicy.effective(requested);
  }

  private static missingAcls(path: string, required: string[]): string[] {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const grants = profile['acls'] as Record<string, Object> | undefined;
    const allowed = grants?.['allowed-acls'];
    const names = Array.isArray(allowed) ? allowed as string[] : [];
    return required.filter((acl: string) => !names.includes(acl));
  }

  /** Durable, content-addressed material; install journals never share a mutable file. */
  private static async retain(path: string, prefix: string): Promise<string> {
    const digest = (await hash.hash(path, 'sha256')).toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error(I18n.t('无法核对本机授权文件'));
    const archived = prefix + '-p-' + digest + '.p7b';
    if (path === archived) return archived;
    if (fileIo.accessSync(archived) &&
      (await hash.hash(archived, 'sha256')).toLowerCase() === digest) return archived;
    const temporary = archived + '.part';
    try {
      fileIo.copyFileSync(path, temporary);
      const copied = fileIo.openSync(temporary, fileIo.OpenMode.READ_WRITE);
      try { fileIo.fsyncSync(copied.fd); }
      finally { fileIo.closeSync(copied); }
      fileIo.renameSync(temporary, archived);
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
    // Keep legacy paths for journals written by earlier versions.
    return archived;
  }

  static valid(path: string, bundleName: string, udid: string,
    certificatePath: string, acls: string[]): boolean {
    if (!fileIo.accessSync(path)) return false;
    try {
      const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
      const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
      const validity = profile['validity'] as Record<string, Object> | undefined;
      const debug = profile['debug-info'] as Record<string, Object> | undefined;
      const grants = profile['acls'] as Record<string, Object> | undefined;
      const deviceIds = debug?.['device-ids'] as string[] | undefined;
      const allowed = grants?.['allowed-acls'] as string[] | undefined;
      const now = Date.now() / 1000;
      return String(profile['type'] ?? '') === 'debug' &&
        String(bundle?.['bundle-name'] ?? '') === bundleName &&
        Number(validity?.['not-before'] ?? 0) <= now &&
        Number(validity?.['not-after'] ?? 0) > now + 3600 &&
        // Reject old lower-case authorizations too, so a paused task cannot
        // reuse the same signed package that BMS already refused.
        Array.isArray(deviceIds) && deviceIds.includes(udid.toUpperCase()) &&
        (acls.length === 0 || (Array.isArray(allowed) && acls.every((acl: string) => allowed.includes(acl)))) &&
        profileMatchesCertificate(path, certificatePath);
    } catch (_) {
      return false;
    }
  }

  static async ensure(context: common.UIAbilityContext, account: DeveloperAccount,
    identity: LocalSigningIdentity, bundleName: string, udid: string,
    requestedPermissions: string[], refresh?: ProfileRefreshOptions): Promise<string> {
    const key = JSON.stringify([context.filesDir, account.userId, account.teamId]);
    const previous = AgcProfile.issuing.get(key) ?? Promise.resolve();
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const tail = previous.then(() => gate);
    AgcProfile.issuing.set(key, tail);
    await previous;
    try {
      return await AgcProfile.ensureLocked(context, account, identity, bundleName, udid,
        requestedPermissions, refresh);
    } finally {
      release();
      if (AgcProfile.issuing.get(key) === tail) AgcProfile.issuing.delete(key);
    }
  }

  private static async ensureLocked(context: common.UIAbilityContext, account: DeveloperAccount,
    identity: LocalSigningIdentity, bundleName: string, udid: string,
    requestedPermissions: string[], refresh?: ProfileRefreshOptions): Promise<string> {
    if (identity.accountId !== account.userId || !/^\d{1,64}$/.test(identity.certId)) {
      throw new Error(I18n.t('签名证书与当前账号不一致'));
    }
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName) ||
      !/^[0-9a-fA-F]{32,128}$/.test(udid)) {
      throw new Error(I18n.t('应用包名或设备 UDID 无效'));
    }
    const dir = context.filesDir + '/signing-profiles';
    if (refresh && (!/^[a-z0-9]{1,24}$/.test(refresh.requestId) ||
      !Number.isFinite(refresh.minimumExpiry) || refresh.minimumExpiry <= 0)) {
      throw new Error(I18n.t('续签请求信息无效'));
    }
    if (refresh && (!Number.isFinite(identity.certExpiry) || identity.certExpiry <= 0)) {
      throw new ServiceFailure(FailureKind.ACCOUNT,
        I18n.t('无法核对签名证书有效期，请刷新证书信息后重试'));
    }
    if (refresh && identity.certExpiry <= refresh.minimumExpiry) {
      throw new ServiceFailure(FailureKind.INVALID_PACKAGE,
        I18n.t('签名证书有效期不足以续签，旧应用已保留，请更新证书后重试'));
    }
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const path = dir + '/' + bundleName + '-' + identity.certId + '-' +
      udid.substring(0, 12).toLowerCase() + (refresh ? '-r-' + refresh.requestId : '') + '.p7b';
    const acls = AgcProfile.effectiveAcls(requestedPermissions);
    const prefix = bundleName + '-' + identity.certId + '-' + udid.substring(0, 12).toLowerCase();
    let selected = '';
    let selectedExpiry = 0;
    // Profiles live in filesDir, outside package eviction and cancel cleanup.
    // Preserve all ACL variants and old certificate material. Expired files are
    // retained as evidence, but never selected for signing. No AGC calls here.
    for (const file of fileIo.listFileSync(dir)) {
      const candidate = dir + '/' + file;
      if (!file.startsWith(prefix + '.') && !file.startsWith(prefix + '-r-') &&
        !file.startsWith(prefix + '-p-')) continue;
      if (!file.endsWith('.p7b') ||
        !AgcProfile.valid(candidate, bundleName, udid, identity.certificatePath, acls)) continue;
      if (refresh && !AgcProfile.reusableForRenewal(candidate, identity.certExpiry, refresh.minimumExpiry)) continue;
      const expiry = AgcProfile.profileExpiry(candidate);
      if (expiry > selectedExpiry) { selected = candidate; selectedExpiry = expiry; }
    }
    if (selected.length > 0) {
      const archived = await AgcProfile.retain(selected, dir + '/' + prefix);
      console.info('AGC Profile source=local-cache');
      return archived;
    }

    const agc = new AgcClient(account);
    await AgcProfileLease.recover(context, account, agc);
    // 仅缓存已成功签发并核验过授权的设备登记，账号、团队和 UDID 必须一致。
    const key = JSON.stringify([context.filesDir, account.userId, account.teamId, udid]);
    const saved = AgcProfile.registrations.get(key);
    const cached = saved !== undefined && Date.now() >= saved.verifiedAt &&
      Date.now() - saved.verifiedAt < AgcProfile.REGISTRATION_TTL_MS;
    let ids = cached && saved !== undefined ? saved.ids : await AgcProfile.registeredDeviceIds(agc, udid);
    const suffix = refresh ? '-r-' + refresh.requestId : '';
    const name = ('qingqi-' + bundleName + '-' + udid.substring(0, 8)).substring(0, 64 - suffix.length) + suffix;
    const temporary = path + '.part';
    let created: CreatedAgcProfile | undefined = undefined;
    let managed = false;
    const valid = (candidate: string): boolean =>
      AgcProfile.valid(candidate, bundleName, udid, identity.certificatePath, acls) &&
      (!refresh || AgcProfile.reusableForRenewal(candidate, identity.certExpiry, refresh.minimumExpiry));
    try {
      try {
        if (AgcManagedProfile.automaticLimited(context, account)) {
          await AgcManagedProfile.obtain(agc, account, identity.certId, ids, acls, bundleName, temporary, valid, udid,
            refresh?.requestId ?? '');
          managed = true;
        } else created = await agc.createProfile(name, identity.certId, ids, acls, bundleName);
      }
      catch (error) {
        // 设备登记刷新解决不了证书失效，由任务层恢复身份后继续签发。
        if (isMissingCertificate(error as Error)) throw error as Error;
        if (AgcProfile.isAutomaticLimit(error as Error)) {
          // Huawei's FAQ defines a rolling 150 requests / 30 days limit.
          // Deleting a Profile does not reset that usage counter, so neither
          // cleanup nor certificate rotation justifies retrying this request.
          // https://developer.huawei.com/consumer/cn/doc/doccenter-tools-faq/faqs-app-debugging-4
          AgcManagedProfile.rememberLimit(context, account);
          await AgcManagedProfile.obtain(agc, account, identity.certId, ids, acls, bundleName, temporary, valid, udid,
            refresh?.requestId ?? '');
          managed = true;
        } else if (AgcProfile.isScopeRefusal(error as Error)) {
          // A device re-registration cannot widen the IDE support scope, so the
          // ordinary retry below would only add a doomed cloud request.
          await AgcProfile.recoverFromScopeRefusal(context, agc, account, identity, bundleName, udid, ids, acls,
            SideloadAclPolicy.requiringApproval(requestedPermissions), temporary, valid, refresh?.requestId ?? '');
          managed = true;
        } else {
          // An ordinary Profile failure must not retry the exhausted IDE path.
          if (AgcManagedProfile.automaticLimited(context, account)) throw error as Error;
          if ((error as ClassifiedFailure).failureKind === FailureKind.ACCOUNT ||
            (error as ClassifiedFailure).failureKind === FailureKind.NETWORK) throw error as Error;
          if (!cached) throw error instanceof Error ? error : new Error(String(error));
          AgcProfile.registrations.delete(key);
          const fresh = await AgcProfile.registeredDeviceIds(agc, udid);
          // 设备登记确实变化才重试签发；证书或权限错误不能反复申请。
          if (fresh.join(',') === ids.join(',')) throw error instanceof Error ? error : new Error(String(error));
          ids = fresh;
          try { created = await agc.createProfile(name, identity.certId, ids, acls, bundleName); }
          catch (retryError) {
            if (!AgcProfile.isAutomaticLimit(retryError as Error)) throw retryError as Error;
            AgcManagedProfile.rememberLimit(context, account);
            await AgcManagedProfile.obtain(agc, account, identity.certId, ids, acls, bundleName, temporary, valid, udid,
              refresh?.requestId ?? '');
            managed = true;
          }
        }
      }
      if (!managed) {
        if (created === undefined) throw new Error(I18n.t('AGC 未返回设备授权'));
        if (created.id.length > 0) AgcProfileLease.remember(context, account, created.id);
        if (created.downloadUrl.length === 0) throw new Error(I18n.t('AGC 未返回设备授权下载地址'));
        const bytes = await agc.download(created.downloadUrl);
        SigningIdentityRecovery.writeFile(temporary, bytes);
      }
      if (!AgcProfile.valid(temporary, bundleName, udid, identity.certificatePath, acls)) {
        if (acls.length > 0 && AgcProfile.valid(temporary, bundleName, udid, identity.certificatePath, [])) {
          throw new ServiceFailure(FailureKind.ACCOUNT,
            I18n.t('AGC 返回的签名授权缺少应用所需 ACL：') + AgcProfile.missingAcls(temporary, acls).join(I18n.t('、')) +
            I18n.t('。请核对该账号和应用的权限授权后重试'));
        }
        throw new Error(I18n.t('AGC 返回的设备授权与应用、设备或证书不匹配'));
      }
      if (refresh && !AgcProfile.reusableForRenewal(temporary, identity.certExpiry, refresh.minimumExpiry)) {
        throw new ServiceFailure(FailureKind.INVALID_PACKAGE,
          I18n.t('新的授权有效期未延长或已经过半，已保留旧应用。请核对授权与证书有效期后再续签'));
      }
      const archived = await AgcProfile.retain(temporary, dir + '/' + prefix);
      const registration = new DeviceRegistration();
      registration.ids = ids.slice(); registration.verifiedAt = Date.now();
      if (AgcProfile.registrations.size >= 8) AgcProfile.registrations.clear();
      AgcProfile.registrations.set(key, registration);
      return archived;
    } catch (error) {
      AgcProfile.registrations.delete(key);
      throw error instanceof Error ? error : new Error(String(error));
    } finally {
      try {
        if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
      } finally {
        // A local signed authorization remains usable after its temporary AGC
        // record is removed. The reference CLI follows this same lifecycle.
        if (created !== undefined && created.id.length > 0) {
          await AgcProfileLease.release(context, account, agc, created.id);
        }
      }
    }
  }
}
