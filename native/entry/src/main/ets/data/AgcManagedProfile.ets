import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { AgcClient } from './AgcClient';
import { DeveloperAccount } from './DeveloperAccount';
import { SigningIdentityRecovery } from './SigningIdentity';
import { ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';

/** Ordinary debug Profiles survive in AGC and are never temporary leases. */
export class AgcManagedProfile {
  // A rolling window may recover before tomorrow; avoid locking ACL-dependent
  // apps into the manual path for an entire day after one rejection.
  private static readonly RETRY_MS: number = 10 * 60 * 1000;

  static automaticLimited(context: common.UIAbilityContext, account: DeveloperAccount): boolean {
    try {
      const row = JSON.parse(fileIo.readTextSync(context.filesDir + '/signing-profiles/automatic-limit.json')) as
        Record<string, Object>;
      const at = Number(row['at'] ?? 0);
      return row['accountId'] === account.userId && row['teamId'] === account.teamId &&
        Number.isFinite(at) && Date.now() >= at && Date.now() - at < AgcManagedProfile.RETRY_MS;
    } catch (_) { return false; }
  }

  static rememberLimit(context: common.UIAbilityContext, account: DeveloperAccount): void {
    const path = context.filesDir + '/signing-profiles/automatic-limit.json';
    try {
      SigningIdentityRecovery.writeFile(path + '.part', JSON.stringify({
        accountId: account.userId, teamId: account.teamId, at: Date.now()
      }));
      fileIo.renameSync(path + '.part', path);
    } catch (_) { console.warn('AGC automatic quota marker could not be saved'); }
    finally { if (fileIo.accessSync(path + '.part')) fileIo.unlinkSync(path + '.part'); }
  }

  private static async appId(agc: AgcClient, bundleName: string, account: DeveloperAccount): Promise<string> {
    const apps = (await agc.registeredApps(bundleName)).filter((row: Record<string, Object>) =>
      String(row['packageName'] ?? '') === bundleName && Number(row['installationFree'] ?? 0) === 0);
    if (apps.length > 1) throw new Error('AGC 存在多个同包名应用，请先核对应用登记');
    if (apps.length === 1) return AgcClient.cloudId(apps[0]['appId']);
    const projects = (await agc.signingProjects()).filter((row: Record<string, Object>) =>
      row['name'] === '轻启本地签名' && String(row['teamId'] ?? '') === account.teamId);
    // Re-query on the next attempt after a timeout; never blindly repeat a POST.
    const project = projects.length > 0 ? AgcClient.cloudId(projects[0]['projectId']) :
      await agc.createSigningProject();
    try {
      return await agc.createSigningApp(project, bundleName);
    } catch (error) {
      if (!/app pkg's name has been used|bundle name.*already in use|package name.*already.*use/i.test(String(error))) {
        throw error as Error;
      }
      // Another request may have registered this package for the same team.
      // Re-query once before treating AGC's global uniqueness check as a denial.
      const existing = (await agc.registeredApps(bundleName)).filter((row: Record<string, Object>) =>
        String(row['packageName'] ?? '') === bundleName && Number(row['installationFree'] ?? 0) === 0);
      if (existing.length === 1) return AgcClient.cloudId(existing[0]['appId']);
      throw new ServiceFailure(FailureKind.ACCOUNT,
        '自动签名申请次数已达上限，本机没有此应用可复用的授权。AGC 已占用此包名（' + bundleName +
        '），当前团队无法申请普通手动授权。需恢复此应用原有的配套签名材料，或等待自动签名额度恢复后继续。安装包已保留。',
        (error as ServiceFailure).status);
    }
  }

  private static async profileName(appId: string, certId: string, deviceIds: string[], acls: string[]): Promise<string> {
    const content = JSON.stringify([appId, certId, deviceIds.slice().sort(), acls.slice().sort()]);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(content) });
    const bytes = (await md.digest()).data;
    let hash = '';
    for (let i = 0; i < bytes.length; i++) hash += bytes[i].toString(16).padStart(2, '0');
    return 'qingqi-managed-' + hash.substring(0, 48);
  }

  static async obtain(agc: AgcClient, account: DeveloperAccount, certId: string, deviceIds: string[],
    acls: string[], bundleName: string, temporary: string, valid: (path: string) => boolean,
    udid: string = ''): Promise<void> {
    const appId = await AgcManagedProfile.appId(agc, bundleName, account);
    const name = await AgcManagedProfile.profileName(appId, certId, deviceIds, acls);
    const profiles = await agc.managedProfiles(appId);
    let existingName = false;
    for (const row of profiles) {
      if (Number(row['tempFlag'] ?? 1) !== 0 || Number(row['provisionType'] ?? 0) !== 1 ||
        String(row['certId'] ?? '') !== certId || String(row['packageName'] ?? '') !== bundleName) continue;
      existingName = existingName || row['provisionName'] === name;
      const expiry = Number(row['expireTime'] ?? 0);
      if (expiry > 0 && expiry <= Date.now() + 3600000) continue;
      const devices = row['deviceList'] as Array<Record<string, Object>> | undefined;
      if (devices && !devices.some((device: Record<string, Object>) =>
        deviceIds.includes(String(device['id'] ?? '')) ||
        (udid.length > 0 && device['udid'] === udid))) continue;
      const objectId = String(row['provisionObjectId'] ?? '');
      if (objectId.length === 0) continue;
      // Cloud metadata is only a hint. Check the signed CMS before reuse.
      const url = await agc.certificateUrl(objectId);
      SigningIdentityRecovery.writeFile(temporary, await agc.download(url));
      if (valid(temporary)) {
        console.info('AGC Profile source=managed-cloud-cache');
        return;
      }
      fileIo.unlinkSync(temporary);
    }
    if (existingName) throw new Error('云端已有相同签名材料的授权，但未通过核验，请在 AGC 核对设备授权');
    if (acls.length > 0) {
      const approved = await agc.approvedAcls(appId);
      const missing = acls.filter((acl: string) => !approved.includes(acl));
      if (missing.length > 0) throw new ServiceFailure(FailureKind.ACCOUNT,
        '自动签名次数已达上限；官方手动签名尚缺少已批准的 ACL：' + missing.join('、') +
        '。请在 AGC 为此应用申请权限，现有应用已保留。', 205389941);
    }
    await agc.createManagedProfile(name, appId, certId, deviceIds, acls);
    const created = (await agc.managedProfiles(appId)).filter((row: Record<string, Object>) =>
      row['provisionName'] === name && String(row['certId'] ?? '') === certId &&
      Number(row['tempFlag'] ?? 1) === 0 && Number(row['provisionType'] ?? 0) === 1);
    if (created.length !== 1) throw new Error('AGC 已收到手动签名请求，授权暂未可查询；重试会先查询已有授权');
    const url = await agc.certificateUrl(String(created[0]['provisionObjectId'] ?? ''));
    SigningIdentityRecovery.writeFile(temporary, await agc.download(url));
    if (!valid(temporary)) throw new Error('AGC 手动签名授权与应用、设备、证书、ACL 或有效期不匹配');
    console.info('AGC Profile source=managed-created');
  }
}
