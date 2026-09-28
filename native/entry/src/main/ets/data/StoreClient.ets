import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { CatalogApp } from './CatalogApp';
import { ReleaseInfo } from './ReleaseInfo';
import { DeveloperAccount } from './DeveloperAccount';
import { SubmitDraft, AppReview } from './StoreActions';

class PrepareBody { repo_url: string = ''; }
class ConfirmBody { draft_token: string = ''; asset_name: string = ''; category: string = ''; }
class ReviewBody { stars: number = 0; body: string = ''; }

export class BackedUpIdentity {
  certId: string = '';
  privateKeyPem: string = '';
}

/// The server uses a self-signed certificate. Trusting only the bundled
/// certificate and pinning its public key preserves the Flutter client's TLS
/// boundary; network errors never fall back to plain HTTP.
export class StoreClient {
  private static readonly BASE_URL = 'https://store.example.com';
  private static readonly PUBLIC_KEY_SHA256 = '1z7Q/bXjcnfeell5HUKRCLRP1E8u1rJHMJYRN3PI3Lo=';
  private caData: string;

  constructor(context: common.UIAbilityContext) {
    const bytes = context.resourceManager.getRawFileContentSync('store-ca.crt');
    this.caData = new util.TextDecoder('utf-8').decodeToString(bytes);
  }

  private async requestData(path: string, method: http.RequestMethod,
    account?: DeveloperAccount, body?: Object): Promise<Record<string, Object>> {
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = {};
      if (account) {
        if (account.jwtToken.length === 0 || account.accessToken.length === 0) {
          throw new Error('请先登录华为开发者账号');
        }
        headers['Authorization'] = 'Bearer ' + account.jwtToken;
        headers['X-Huawei-Access-Token'] = account.accessToken;
      }
      if (body) headers['Content-Type'] = 'application/json';
      const response = await request.request(StoreClient.BASE_URL + path, {
        method: method,
        header: headers,
        extraData: body ? JSON.stringify(body) : '',
        connectTimeout: 8000,
        readTimeout: 20000,
        caData: this.caData,
        certificatePinning: {
          publicKeyHash: StoreClient.PUBLIC_KEY_SHA256,
          hashAlgorithm: 'SHA-256'
        },
        maxLimit: 2 * 1024 * 1024
      });
      if (typeof response.result !== 'string') {
        throw new Error('商店服务响应格式无效');
      }
      const envelope = JSON.parse(response.result) as Record<string, Object>;
      if (envelope['ok'] !== true) {
        const error = envelope['error'] as Record<string, Object> | undefined;
        throw new Error(String(error?.['message'] ?? '商店服务暂不可用') +
          (error?.['hint'] ? ' · ' + String(error['hint']) : ''));
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('商店服务返回 ' + response.responseCode);
      }
      return envelope['data'] as Record<string, Object>;
    } finally {
      request.destroy();
    }
  }

  private getData(path: string, account?: DeveloperAccount): Promise<Record<string, Object>> {
    return this.requestData(path, http.RequestMethod.GET, account);
  }

  async listApps(): Promise<CatalogApp[]> {
    const data = await this.getData('/api/v1/apps?sort=updated&page=1&page_size=30');
    const raw = data['items'] as Array<Record<string, Object>> | undefined;
    return (raw ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
  }

  async appDetail(id: number): Promise<CatalogApp> {
    return CatalogApp.fromJson(await this.getData('/api/v1/apps/' + id));
  }

  async appIcon(app: CatalogApp): Promise<image.PixelMap | undefined> {
    if (app.id <= 0 || app.iconUrl !== '/api/v1/apps/' + app.id + '/icon') {
      return undefined;
    }
    const request = http.createHttp();
    try {
      const response = await request.request(StoreClient.BASE_URL + app.iconUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 12000,
        caData: this.caData,
        certificatePinning: {
          publicKeyHash: StoreClient.PUBLIC_KEY_SHA256,
          hashAlgorithm: 'SHA-256'
        },
        maxLimit: 1024 * 1024
      });
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        return undefined;
      }
      const source = image.createImageSource(response.result);
      try { return await source.createPixelMap(); }
      finally { await source.release(); }
    } catch (_) {
      return undefined;
    } finally {
      request.destroy();
    }
  }

  async listReleases(appId: number): Promise<ReleaseInfo[]> {
    const data = await this.getData('/api/v1/apps/' + appId +
      '/releases?page=1&page_size=20');
    const raw = data['items'] as Array<Record<string, Object>> | undefined;
    return (raw ?? []).map((row: Record<string, Object>) => ReleaseInfo.fromJson(row));
  }

  async prepareSubmit(repoUrl: string, account: DeveloperAccount): Promise<SubmitDraft> {
    const body = new PrepareBody();
    body.repo_url = repoUrl;
    const data = await this.requestData('/api/v1/submit/prepare', http.RequestMethod.POST,
      account, body);
    return SubmitDraft.fromJson(data);
  }

  async confirmSubmit(draft: SubmitDraft, assetName: string, category: string,
    account: DeveloperAccount): Promise<CatalogApp> {
    const body = new ConfirmBody();
    body.draft_token = draft.token;
    body.asset_name = assetName;
    body.category = category;
    const data = await this.requestData('/api/v1/submit/confirm', http.RequestMethod.POST,
      account, body);
    return CatalogApp.fromJson(data['app'] as Record<string, Object>);
  }

  async myApps(account: DeveloperAccount): Promise<CatalogApp[]> {
    const data = await this.getData('/api/v1/me/apps', account);
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
  }

  async removeMyApp(id: number, account: DeveloperAccount): Promise<void> {
    await this.requestData('/api/v1/me/apps/' + id, http.RequestMethod.DELETE, account);
  }

  async listReviews(appId: number): Promise<AppReview[]> {
    const data = await this.getData('/api/v1/apps/' + appId + '/reviews');
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => AppReview.fromJson(row));
  }

  async postReview(appId: number, stars: number, body: string,
    account: DeveloperAccount): Promise<AppReview[]> {
    const payload = new ReviewBody();
    payload.stars = stars;
    payload.body = body;
    const data = await this.requestData('/api/v1/apps/' + appId + '/reviews', http.RequestMethod.POST,
      account, payload);
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => AppReview.fromJson(row));
  }

  async signingIdentity(account: DeveloperAccount): Promise<BackedUpIdentity | undefined> {
    const data = await this.getData('/api/v1/signing-identity', account);
    const row = data['identity'] as Record<string, Object> | null | undefined;
    if (!row) return undefined;
    const identity = new BackedUpIdentity();
    identity.certId = String(row['cert_id'] ?? '');
    identity.privateKeyPem = String(row['private_key_pem'] ?? '');
    if (!/^\d{1,64}$/.test(identity.certId) ||
      !/^-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----\s*$/.test(identity.privateKeyPem) ||
      identity.privateKeyPem.length > 8192) {
      throw new Error('云端签名身份格式无效');
    }
    return identity;
  }
}
