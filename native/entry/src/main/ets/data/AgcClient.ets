import { http } from '@kit.NetworkKit';
import { DeveloperAccount } from './DeveloperAccount';

const AGC_API = 'https://connect-api.cloud.huawei.com/api';

class SourceUrlsBody { sourceUrls: string = ''; }
class DeleteCertsBody { certIds: string[] = []; }
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
      const response = await request.request(AGC_API + path, {
        method: verb,
        header: {
          'oauth2Token': this.account.accessToken,
          'teamId': this.account.teamId,
          'uid': this.account.userId,
          'Content-Type': 'application/json'
        },
        extraData: body ? JSON.stringify(body) : '',
        connectTimeout: 8000,
        readTimeout: 15000,
        maxLimit: 1024 * 1024
      });
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
