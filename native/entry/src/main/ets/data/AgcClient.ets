import { http } from '@kit.NetworkKit';
import { DeveloperAccount } from './DeveloperAccount';
import { AccountService } from './AccountService';
import { ServiceFailure, ClassifiedFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';
import { certificateQuotaFailure } from './CertificateQuota';

const AGC_API = 'https://connect-api.cloud.huawei.com/api';

class SourceUrlsBody { sourceUrls: string = ''; }
class DeleteCertsBody { certIds: string[] = []; }
class CreateCertBody {
  csr: string = '';
  certName: string = '';
  certType: number = 1;
}
class RegisterDeviceBody {
  deviceName: string = '';
  udid: string = '';
  deviceType: number = 4;
}
class CreateProfileBody {
  provisionName: string = '';
  aclPermissionList: string[] = [];
  deviceList: string[] = [];
  certList: string[] = [];
  packageName: string = '';
}
class CreateManagedProfileBody {
  provisionName: string = '';
  certList: string[] = [];
  deviceList: string[] = [];
  aclPermissionList: string[] = [];
  provisionType: number = 1;
  appId: string = '';
  reqSource: string = 'IDE';
}

export class CreatedAgcProfile {
  id: string = '';
  downloadUrl: string = '';
}

export class AgcClient {
  private account: DeveloperAccount;

  constructor(account: DeveloperAccount) { this.account = account; }

  private async request(path: string, body?: Object,
    method?: http.RequestMethod, retried: boolean = false, appId: string = '',
    form?: string): Promise<Record<string, Object>> {
    const request = http.createHttp();
    const startedAt = Date.now();
    const verb = method ?? (body ? http.RequestMethod.POST : http.RequestMethod.GET);
    try {
      const options: http.HttpRequestOptions = {
        method: verb,
        header: {
          'oauth2Token': this.account.accessToken,
          'teamId': this.account.teamId,
          'uid': this.account.userId,
          'Content-Type': form === undefined ? 'application/json' : 'application/x-www-form-urlencoded'
        },
        connectTimeout: 8000,
        readTimeout: 15000,
        maxLimit: 1024 * 1024
      };
      if (appId.length > 0) (options.header as Record<string, string>)['appId'] = appId;
      // HarmonyOS rejects extraData: '' before a bodyless GET reaches AGC.
      if (body) options.extraData = JSON.stringify(body);
      if (form !== undefined) options.extraData = form;
      const response = await request.request(AGC_API + path, options);
      if (response.responseCode === 401 && !retried) {
        await AccountService.refresh(this.account, true);
        return this.request(path, body, method, true, appId, form);
      }
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        const code = response.responseCode;
        throw new ServiceFailure(code === 401 ? FailureKind.ACCOUNT :
          code === 403 ? FailureKind.INTERNAL : FailureKind.NETWORK,
          code === 401 ? '登录已过期，请重新登录' : code === 403 ? 'AGC 权限不足，请检查开发者账号授权' :
            code === 429 ? 'AGC 请求过于频繁，请稍后重试' : 'AGC 暂时无法完成请求（HTTP ' + code + '）', code);
      }
      const data = JSON.parse(response.result) as Record<string, Object>;
      const ret = data['ret'] as Record<string, Object> | undefined;
      if (ret && Number(ret['code'] ?? 0) !== 0) {
        const code = Number(ret['code']);
        if (code === 401 && !retried) {
          await AccountService.refresh(this.account, true);
          return this.request(path, body, method, true, appId, form);
        }
        throw new ServiceFailure(code === 401 ? FailureKind.ACCOUNT : FailureKind.INTERNAL,
          'AGC 拒绝请求：' + String(ret['msg'] ?? ret['code']), code);
      }
      return data;
    } catch (error) {
      if ((error as ClassifiedFailure).failureKind !== undefined) throw error as Error;
      throw new ServiceFailure(FailureKind.NETWORK, 'AGC 网络请求失败：' + String(error));
    } finally {
      request.destroy();
      console.info('AGC request: path=' + path.split('?')[0] + ' elapsedMs=' + (Date.now() - startedAt));
    }
  }

  async download(url: string): Promise<ArrayBuffer> {
    if (!/^https:\/\/[^/@\s]+\//.test(url)) throw new Error('AGC 下载地址无效');
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 15000,
        maxLimit: 2 * 1024 * 1024
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
        response.result.byteLength < 100 || response.result.byteLength > 2 * 1024 * 1024) {
        throw new Error('AGC 文件下载失败');
      }
      return response.result;
    } finally {
      request.destroy();
    }
  }

  async certificates(): Promise<Array<Record<string, Object>>> {
    const data = await this.request('/cps/harmony-cert-manage/v1/cert/list');
    return data['certList'] as Array<Record<string, Object>> ?? [];
  }

  /**
   * 申请调试证书（certType 1），返回 AGC 建好的证书记录。
   *
   * 这是唯一会占用 AGC 调试证书槽位的调用，所以只应由 SigningIdentityRecovery
   * 在「账号下没有任何证书与本机私钥配对」之后调用，不要在登录/核对路径上顺手调用。
   */
  async createCertificate(csrPem: string, certName: string): Promise<Record<string, Object>> {
    if (!/^-----BEGIN CERTIFICATE REQUEST-----/.test(csrPem)) {
      throw new Error('证书请求格式无效，已取消申请');
    }
    const body = new CreateCertBody();
    body.csr = csrPem;
    body.certName = certName;
    body.certType = 1;
    let data: Record<string, Object>;
    try { data = await this.request('/cps/harmony-cert-manage/v1/cert/add', body); }
    catch (error) { throw certificateQuotaFailure(error as Error); }
    const created = data['harmonyCert'] as Record<string, Object> | undefined;
    if (!created || String(created['id'] ?? '').length === 0) {
      const ret = data['ret'] as Record<string, Object> | undefined;
      throw new Error('AGC 未返回新证书：' + String(ret?.['msg'] ?? '原因未知'));
    }
    return created;
  }

  /** 删除调试证书。接口形态与 Flutter 版 agc_service.deleteCertList 一致。 */
  async deleteCertificates(certIds: string[]): Promise<void> {
    if (certIds.length === 0) throw new Error('没有要删除的证书');
    const body = new DeleteCertsBody();
    body.certIds = certIds;
    await this.request('/cps/harmony-cert-manage/v1/cert/delete', body,
      http.RequestMethod.DELETE);
  }

  async certificateUrl(objectId: string): Promise<string> {
    const body = new SourceUrlsBody();
    body.sourceUrls = objectId;
    const data = await this.request('/amis/app-manage/v1/objects/url/reapply', body);
    const urls = data['urlsInfo'] as Array<Record<string, Object>> | undefined;
    return String(urls?.[0]?.['newUrl'] ?? '');
  }

  async devices(): Promise<Array<Record<string, Object>>> {
    const data = await this.request(
      '/cps/device-manage/v1/device/list?start=1&pageSize=100&encodeFlag=0');
    return data['list'] as Array<Record<string, Object>> ?? [];
  }

  async registerDevice(udid: string): Promise<void> {
    const body = new RegisterDeviceBody();
    body.udid = udid;
    body.deviceName = 'qingqi-' + udid.substring(0, Math.min(10, udid.length));
    await this.request('/cps/device-manage/v1/device/add', body);
  }

  async createProfile(name: string, certId: string, deviceIds: string[],
    permissions: string[], bundleName: string): Promise<CreatedAgcProfile> {
    const body = new CreateProfileBody();
    body.provisionName = name;
    body.certList = [certId];
    body.deviceList = deviceIds;
    body.aclPermissionList = permissions;
    body.packageName = bundleName;
    const data = await this.request('/cps/provision-manage/v1/ide/test/provision/add', body);
    const info = data['provisionInfo'] as Record<string, Object> | undefined;
    const created = new CreatedAgcProfile();
    const ret = data['ret'] as Record<string, Object> | undefined;
    const recordId = info?.['id'] || info?.['provisionId'] || data['id'] || data['provisionId'] || ret?.['id'];
    // Cloud IDs exceed JS's safe integer range. Never round one into another
    // record's ID when the server has unexpectedly encoded it as a number.
    if (typeof recordId === 'string') created.id = recordId;
    else if (typeof recordId === 'number' && Number.isSafeInteger(recordId)) created.id = String(recordId);
    created.downloadUrl = String(info?.['provisionFileUrl'] || data['provisionFileUrl'] || ret?.['downloadUrl'] || '');
    // Basic IDE authorization can return a file without a persistent cloud row.
    // A receipt is optional: verify and retain the signed file in either case.
    // Never substitute a CMS UUID or rounded number for a deletion receipt.
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(created.id)) {
      created.id = '';
    }
    console.info('AGC Profile receipt=' + (created.id.length > 0 ? 'present' : 'absent'));
    return created;
  }

  async deleteProfile(id: string): Promise<void> {
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(id)) throw new Error('AGC 授权记录编号无效');
    await this.request('/cps/provision-manage/v1/provision/delete?id=' + encodeURIComponent(id),
      undefined, http.RequestMethod.DELETE);
  }

  async registeredApps(bundleName: string): Promise<Array<Record<string, Object>>> {
    const data = await this.request('/amis/app-manage/v1/manage/app/brief-info/list?packageNames=' +
      encodeURIComponent(bundleName));
    return data['appInfos'] as Array<Record<string, Object>> ?? [];
  }

  async signingProjects(): Promise<Array<Record<string, Object>>> {
    const rows: Array<Record<string, Object>> = [];
    for (let page = 1; page <= 10; page++) {
      const data = await this.request('/project-service/v1/projects?uid=' +
        encodeURIComponent(this.account.userId) + '&teamId=' + encodeURIComponent(this.account.teamId) +
        '&queryFlag=0&fromPage=' + page + '&pageSize=100');
      const part = data['projectList'] as Array<Record<string, Object>> ?? [];
      rows.push(...part);
      if (part.length < 100 || rows.length >= Number(data['totalCount'] ?? Infinity)) return rows;
    }
    throw new Error('AGC 项目过多，无法完整核对已有签名项目');
  }

  async createSigningProject(): Promise<string> {
    // DevEco's registration endpoints use form encoding, unlike Profile creation.
    const form = 'uid=' + encodeURIComponent(this.account.userId) + '&teamId=' +
      encodeURIComponent(this.account.teamId) + '&name=' + encodeURIComponent('轻启本地签名') +
      '&createAllianceProjectFlag=1&createDevProjectFlag=0&createTenantProjectFlag=0';
    const data = await this.request('/cpms/project-management-service/v1/projects', undefined,
      http.RequestMethod.POST, false, '', form);
    const mapping = data['mapping'] as Record<string, Object> | undefined;
    return AgcClient.cloudId(mapping?.['projectId']);
  }

  async createSigningApp(projectId: string, bundleName: string): Promise<string> {
    const form = 'teamId=' + encodeURIComponent(this.account.teamId) + '&projectId=' +
      encodeURIComponent(projectId) + '&appName=' + encodeURIComponent(('轻启-' + bundleName).substring(0, 64)) +
      '&packageName=' + encodeURIComponent(bundleName) + '&parentType=13&installationFree=0';
    const data = await this.request('/publish/v3/app', undefined, http.RequestMethod.POST, false, '', form);
    return AgcClient.cloudId(data['appId']);
  }

  static cloudId(value: Object | undefined): string {
    if (typeof value === 'string' && /^\d{1,64}$/.test(value)) return value;
    if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) return String(value);
    throw new Error('AGC 未返回有效的云端记录编号');
  }

  async managedProfiles(appId: string): Promise<Array<Record<string, Object>>> {
    const data = await this.request(
      '/cps/provision-manage/v1/provision/list?encodeFlag=0&start=1&pageSize=100&certTypes=1',
      undefined, undefined, false, appId);
    const rows = data['list'] as Array<Record<string, Object>> ?? [];
    if (Number(data['totalCount'] ?? rows.length) > 100) throw new Error('AGC 授权列表未完整返回');
    return rows;
  }

  async approvedAcls(appId: string): Promise<string[]> {
    const data = await this.request('/cps/provision-manage/v1/user/permission',
      undefined, undefined, false, appId);
    const user = data['userPermission'] as Record<string, Object> | undefined;
    return String(user?.['aclPermissionList'] ?? '').split(',').map((acl: string) => acl.trim())
      .filter((acl: string) => acl.length > 0);
  }

  async createManagedProfile(name: string, appId: string, certId: string, deviceIds: string[],
    acls: string[]): Promise<void> {
    const body = new CreateManagedProfileBody();
    body.provisionName = name; body.appId = appId; body.certList = [certId];
    body.deviceList = deviceIds; body.aclPermissionList = acls;
    await this.request('/cps/provision-manage/v1/provision/add', body, undefined, false, appId);
  }
}
