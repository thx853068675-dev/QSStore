import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
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
class CategoryBody { category: string = ''; }
class IdentityBody {
  cert_id: string = '';
  private_key_pem: string = '';
  /**
   * 证书轮换时才带的期望值：服务端只在记录里的 cert_id 等于它时才替换。
   * 首次备份不带（留空），服务端按 first-write-wins 处理。
   */
  replace_cert_id: string = '';
  replace_revision: number = 0;
}
/**
 * 无参数的 POST 的请求体。
 *
 * 服务端对空 body 是容忍的；这里显式给一个 `{}` 是为了让请求带上
 * `Content-Type: application/json`，语义上更明确。
 *
 * （原来的注释说「ArkTS 的 http 不接受空 extraData」，那个归因不准确：真正的坑是
 * **空字符串** extraData 会被参数校验拒掉。现在无 body 的请求干脆不带这个字段，
 * 见 requestData。）
 */
class EmptyBody { }

/**
 * `POST /apps/refresh-stale` 的请求体。
 *
 * `app_ids` 为空数组时服务端按「最过期的」兜底采几个；非空则只采点名的那些。
 */
class RefreshStaleBody {
  app_ids: number[] = [];
}

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
  revision: number = 0;
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
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
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
      // **没有 body 就不要带 extraData 这个字段。** 它本来就是可选的；塞一个空字符串
      // 会被 http 模块的参数校验拒掉（BusinessError 401 Parameter error），请求根本
      // 发不出去 —— 表现是「下架报 parameter error」而服务端日志里连这条请求都没有。
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 20000,
        caData: this.caData,
        certificatePinning: {
          publicKeyHash: StoreClient.PUBLIC_KEY_SHA256,
          hashAlgorithm: 'SHA-256'
        },
        maxLimit: 2 * 1024 * 1024
      };
      if (body) options.extraData = JSON.stringify(body);
      const response = await request.request(StoreClient.BASE_URL + path, options);
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
      // The endpoint path stays stable when the server replaces an icon. Give
      // each revision a distinct URL so intermediate HTTP caches cannot serve
      // the previous image after the catalog has already changed.
      const revision = app.iconRev.length > 0 ? '?v=' + encodeURIComponent(app.iconRev) : '';
      const response = await request.request(StoreClient.BASE_URL + app.iconUrl + revision, {
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

  /**
   * 让服务端立刻重采这个应用，把 GitHub 上刚发布的版本拉进来。
   *
   * 采集器按固定周期跑（默认 30 分钟），所以「刚发的 Release」在客户端要等
   * 下一轮才看得见。用户点「检查更新」时调这个接口即时重采一次。
   * 服务端按 IP 限流；失败只代表这次没查到新版本，不影响已有数据。
   */
  async refreshApp(appId: number): Promise<void> {
    if (appId <= 0) throw new Error('应用编号无效');
    // 带一个空 JSON 对象：http.request 的 extraData 传空字符串会直接抛
    // 401 Parameter error，服务端对空 body 本身是容忍的。
    await this.requestData('/api/v1/apps/' + appId + '/refresh',
      http.RequestMethod.POST, undefined, new EmptyBody());
  }

  /**
   * 批量重采「已经不新鲜」的应用，供发现页下拉刷新使用。
   *
   * `GET /apps` 读的是缓存目录，`latest_asset` 要等采集周期（默认 30 分钟）才更新 ——
   * 所以下拉刷新原本看不到刚发布的版本，必须进详情页点「检查更新」。这个接口把
   * 单应用的即时重采批量化。
   *
   * 服务端按 IP 限流，且只采过期的、一次限量、总时长有上限：GitHub 采集是慢操作，
   * 不能让一次下拉把请求拖成几十秒。失败**不抛错** —— 下拉刷新宁可用旧数据，
   * 也不该因为某个仓库暂时不可达就整页报错。
   */
  async refreshStaleApps(appIds: number[] = []): Promise<number> {
    try {
      const body = new RefreshStaleBody();
      body.app_ids = appIds;
      const data = await this.requestData('/api/v1/apps/refresh-stale',
        http.RequestMethod.POST, undefined, body);
      const rows = data['refreshed'] as Array<Record<string, Object>> | undefined;
      return rows === undefined ? 0 : rows.length;
    } catch (_) {
      return 0;
    }
  }

  /// ``page`` is 1-based; the server caps page_size at 50.
  async listReleases(appId: number, page: number = 1,
    pageSize: number = 20, includePrerelease: boolean = false): Promise<ListPage<ReleaseInfo>> {
    const data = await this.getData('/api/v1/apps/' + appId + '/releases?page=' +
      Math.max(1, Math.floor(page)) + '&page_size=' +
      Math.min(50, Math.max(1, Math.floor(pageSize))) +
      '&prerelease=' + (includePrerelease ? '1' : '0'));
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

  async categories(): Promise<string[]> {
    const data = await this.getData('/api/v1/categories');
    return (data['items'] as string[] | undefined) ?? [];
  }

  async configureMyApp(id: number, category: string, account: DeveloperAccount): Promise<CatalogApp> {
    const body = new CategoryBody();
    body.category = category;
    const data = await this.requestData('/api/v1/me/apps/' + id + '/category',
      http.RequestMethod.POST, account, body);
    return CatalogApp.fromJson(data['app'] as Record<string, Object>);
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

  /** 仅保存本机已经恢复或成功备份的版本，查询冲突不能更新此期望值。 */
  async rememberSigningIdentity(account: DeveloperAccount, identity: BackedUpIdentity): Promise<void> {
    if (!Number.isSafeInteger(identity.revision) || identity.revision < 1) {
      throw new Error('备份服务尚未支持版本校验，请更新服务端');
    }
    const store = await preferences.getPreferences(this.context, 'signing-backup-version');
    // 这里只保存版本，不复制私钥到 preferences。
    const baseline = new BackedUpIdentity();
    baseline.certId = identity.certId;
    baseline.revision = identity.revision;
    await store.put(account.userId, JSON.stringify(baseline));
    await store.flush();
  }

  async publishSigningIdentity(certId: string, privateKeyPem: string,
    account: DeveloperAccount): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'signing-backup-version');
    const raw = await store.get(account.userId, '') as string;
    const body = new IdentityBody();
    body.cert_id = certId;
    body.private_key_pem = privateKeyPem;
    if (raw.length > 0) {
      const baseline = JSON.parse(raw) as BackedUpIdentity;
      if (baseline.certId.length > 0 && baseline.revision > 0) {
        body.replace_cert_id = baseline.certId;
        body.replace_revision = baseline.revision;
      }
    }
    const result = await this.requestData('/api/v1/signing-identity',
      http.RequestMethod.POST, account, body);
    if (result['synced'] !== true || String(result['cert_id'] ?? '') !== certId) {
      throw new Error('签名身份备份未确认，已保留本机材料，请核对云端身份');
    }
    const saved = new BackedUpIdentity();
    saved.certId = certId;
    saved.revision = Number(result['revision'] ?? 0);
    await this.rememberSigningIdentity(account, saved);
  }

  async signingIdentity(account: DeveloperAccount): Promise<BackedUpIdentity | undefined> {
    const data = await this.getData('/api/v1/signing-identity', account);
    const row = data['identity'] as Record<string, Object> | null | undefined;
    if (!row) return undefined;
    const identity = new BackedUpIdentity();
    identity.certId = String(row['cert_id'] ?? '');
    identity.revision = Number(row['revision'] ?? 0);
    identity.privateKeyPem = String(row['private_key_pem'] ?? '');
    if (!/^\d{1,64}$/.test(identity.certId) ||
      !/^-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----\s*$/.test(identity.privateKeyPem) ||
      identity.privateKeyPem.length > 8192) {
      throw new Error('云端签名身份格式无效');
    }
    return identity;
  }
}
