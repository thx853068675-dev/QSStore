import { http } from '@kit.NetworkKit';
import { DeveloperAccount } from './DeveloperAccount';

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

export class AgcClient {
  private account: DeveloperAccount;

  constructor(account: DeveloperAccount) { this.account = account; }

  private async request(path: string, body?: Object,
    method?: http.RequestMethod): Promise<Record<string, Object>> {
    const request = http.createHttp();
    const verb = method ?? (body ? http.RequestMethod.POST : http.RequestMethod.GET);
    try {
      const options: http.HttpRequestOptions = {
        method: verb,
        header: {
          'oauth2Token': this.account.accessToken,
          'teamId': this.account.teamId,
          'uid': this.account.userId,
          'Content-Type': 'application/json'
        },
        connectTimeout: 8000,
        readTimeout: 15000,
        maxLimit: 1024 * 1024
      };
      // HarmonyOS rejects extraData: '' before a bodyless GET reaches AGC.
      if (body) options.extraData = JSON.stringify(body);
      const response = await request.request(AGC_API + path, options);
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new Error('AGC 暂时无法完成请求');
      }
      const data = JSON.parse(response.result) as Record<string, Object>;
      const ret = data['ret'] as Record<string, Object> | undefined;
      if (ret && Number(ret['code'] ?? 0) !== 0) {
        throw new Error('AGC 拒绝请求：' + String(ret['msg'] ?? ret['code']));
      }
      return data;
    } finally {
      request.destroy();
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
    const data = await this.request('/cps/harmony-cert-manage/v1/cert/add', body);
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
    permissions: string[], bundleName: string): Promise<string> {
    const body = new CreateProfileBody();
    body.provisionName = name;
    body.certList = [certId];
    body.deviceList = deviceIds;
    body.aclPermissionList = permissions;
    body.packageName = bundleName;
    const data = await this.request('/cps/provision-manage/v1/ide/test/provision/add', body);
    const url = String(data['provisionFileUrl'] ?? '');
    if (url.length === 0) throw new Error('AGC 未返回设备授权文件');
    return url;
  }
}
