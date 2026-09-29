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
class IdentityBody { cert_id: string = ''; private_key_pem: string = ''; }

/// Server page size ceilings: /apps caps page_size at 100, /releases and
/// /reviews at 50. Every listing returns total next to items.
export class ListPage<T> {
  items: T[] = [];
  /** Total number of records on the server, not just this page. */
  total: number = 0;
  page: number = 1;
  pageSize: number = 20;
  /**
   * 服务端原样的行数据。
   *
   * 缓存要存的是"服务端说了什么"，不是我们解析后的对象 —— 存原样才能在
   * 版本升级后仍按当前解析规则读回来。
   */
  rawItems: Array<Record<string, Object>> = [];

  get totalPages(): number {
    if (this.total <= 0 || this.pageSize <= 0) return 1;
    return Math.ceil(this.total / this.pageSize);
  }

  get hasMore(): boolean {
    return this.page < this.totalPages;
  }
}

function numberField(row: Record<string, Object>, key: string, fallback: number): number {
  const value = Number(row[key] ?? fallback);
  return Number.isFinite(value) ? value : fallback;
}

export class BackedUpIdentity {
  certId: string = '';
  privateKeyPem: string = '';
}

/// The server uses a self-signed certificate. Trusting only the bundled
/// certificate and pinning its public key preserves the Flutter client's TLS
/// boundary; network errors never fall back to plain HTTP.
export class StoreClient {
  private static readonly BASE_URL = 'https://47.98.250.230';
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

  /// ``page`` is 1-based. ``sort`` is one of updated/stars/name/new.
  /// ``query`` 走服务端搜索：只过滤本地已加载的那一页会漏掉没加载的应用。
  async listApps(page: number = 1, pageSize: number = 30,
    sort: string = 'updated', query: string = ''): Promise<ListPage<CatalogApp>> {
    const trimmed = query.trim();
    const data = await this.getData('/api/v1/apps?sort=' + encodeURIComponent(sort) +
      '&page=' + Math.max(1, Math.floor(page)) +
      '&page_size=' + Math.min(100, Math.max(1, Math.floor(pageSize))) +
      (trimmed.length > 0 ? '&q=' + encodeURIComponent(trimmed) : ''));
    const result = new ListPage<CatalogApp>();
    const raw = data['items'] as Array<Record<string, Object>> | undefined;
    result.rawItems = raw ?? [];
    result.items = (raw ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', page);
    result.pageSize = numberField(data, 'page_size', pageSize);
    return result;
  }

  async appDetail(id: number): Promise<CatalogApp> {
    return CatalogApp.fromJson(await this.getData('/api/v1/apps/' + id));
  }

  /**
   * 图标的原始字节。
   *
   * 单独抽出来是为了能缓存：PixelMap 不能序列化，但字节可以。冷启动时先用
   * 缓存的字节直接画出图标，再去后端刷新。
   */
  async appIconBytes(app: CatalogApp): Promise<ArrayBuffer | undefined> {
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
      return response.result;
    } catch (_) {
      return undefined;
    } finally {
      request.destroy();
    }
  }

  async appIcon(app: CatalogApp): Promise<image.PixelMap | undefined> {
    const bytes = await this.appIconBytes(app);
    if (bytes === undefined) return undefined;
    try {
      const source = image.createImageSource(bytes);
      try { return await source.createPixelMap(); }
      finally { await source.release(); }
    } catch (_) {
      return undefined;
    }
  }

  /// ``page`` is 1-based; the server caps page_size at 50.
  async listReleases(appId: number, page: number = 1,
    pageSize: number = 20): Promise<ListPage<ReleaseInfo>> {
    const data = await this.getData('/api/v1/apps/' + appId + '/releases?page=' +
      Math.max(1, Math.floor(page)) + '&page_size=' +
      Math.min(50, Math.max(1, Math.floor(pageSize))));
    const result = new ListPage<ReleaseInfo>();
    const raw = data['items'] as Array<Record<string, Object>> | undefined;
    result.items = (raw ?? []).map((row: Record<string, Object>) => ReleaseInfo.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', page);
    result.pageSize = numberField(data, 'page_size', pageSize);
    return result;
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

  /// Reviews always sort newest first, so page 1 is also what a new review lands on.
  async listReviews(appId: number, page: number = 1,
    pageSize: number = 20): Promise<ListPage<AppReview>> {
    const data = await this.getData('/api/v1/apps/' + appId + '/reviews?page=' +
      Math.max(1, Math.floor(page)) + '&page_size=' +
      Math.min(50, Math.max(1, Math.floor(pageSize))));
    const result = new ListPage<AppReview>();
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    result.items = (rows ?? []).map((row: Record<string, Object>) => AppReview.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', page);
    result.pageSize = numberField(data, 'page_size', pageSize);
    return result;
  }

  async postReview(appId: number, stars: number, body: string,
    account: DeveloperAccount): Promise<ListPage<AppReview>> {
    const payload = new ReviewBody();
    payload.stars = stars;
    payload.body = body;
    const data = await this.requestData('/api/v1/apps/' + appId + '/reviews', http.RequestMethod.POST,
      account, payload);
    const result = new ListPage<AppReview>();
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    result.items = (rows ?? []).map((row: Record<string, Object>) => AppReview.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', 1);
    // The POST route returns the endpoint's default page, not the length of
    // the page it just produced.
    result.pageSize = numberField(data, 'page_size', 20);
    return result;
  }

  /**
   * 备份本机签名身份到商店服务，换设备时可直接取回。
   * 服务端同一账号首次写入生效，之后保持原值，所以重复调用是安全的。
   */
  async publishSigningIdentity(certId: string, privateKeyPem: string,
    account: DeveloperAccount): Promise<void> {
    const body = new IdentityBody();
    body.cert_id = certId;
    body.private_key_pem = privateKeyPem;
    await this.requestData('/api/v1/signing-identity', http.RequestMethod.POST, account, body);
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
