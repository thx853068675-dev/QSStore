import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { CatalogApp } from './CatalogApp';
import { CatalogCache, CachedIcon } from './CatalogCache';
import { ReleaseInfo } from './ReleaseInfo';
import { DeveloperAccount } from './DeveloperAccount';
import { AccountService } from './AccountService';
import { ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';
import { SubmitDraft, AppReview } from './StoreActions';

class PrepareBody { repo_url: string = ''; }
class ConfirmBody {
  asset_name: string = ''; draft_token: string = ''; asset_names: string[] = []; category: string = ''; }
class ReviewBody { stars: number = 0; body: string = ''; }
class CategoryBody { category: string = ''; source_draft_token: string = ''; remove_secondary: boolean = false; }
class IdentityBody {
  backup_scope: string = 'certificate';
  cert_id: string = '';
  private_key_pem: string = '';
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
  snapshot: string = '';
  snapshotExpired: boolean = false;
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
class PublicResponse {
  etag: string = '';
  data: Record<string, Object> = {};
  bytes: number = 0;
  receivedAt: number = 0;
}

export interface RenewalCatalog {
  listReleases(appId: number, page: number, pageSize: number,
    preview: boolean): Promise<ListPage<ReleaseInfo>>;
}

export class StoreClient implements RenewalCatalog {
  private static viewedApps: Map<number, CatalogApp> = new Map();

  /** 返回页面只合并详情已读取的变化，不重载分页列表、重置滚动和图标。 */
  static consumeViewedApps(): CatalogApp[] {
    const apps = Array.from(StoreClient.viewedApps.values());
    StoreClient.viewedApps.clear();
    return apps;
  }
  private static responses: Map<string, PublicResponse> = new Map();
  private static publicReads: Map<string, Promise<Record<string, Object>>> = new Map();
  private static iconReads: Map<string, Promise<ArrayBuffer | undefined>> = new Map();
  private static responseEpoch: number = 0;
  private static invalidatePublic(): void {
    StoreClient.responseEpoch++;
    StoreClient.responses.clear();
    StoreClient.publicReads.clear();
  }
  private static remember(path: string, etag: string, data: Record<string, Object>): void {
    const row = new PublicResponse();
    row.etag = etag; row.data = data; row.bytes = JSON.stringify(data).length * 2;
    row.receivedAt = Date.now();
    if (row.bytes > 2 * 1024 * 1024) return;
    StoreClient.responses.delete(path);
    StoreClient.responses.set(path, row);
    let bytes = 0;
    StoreClient.responses.forEach((entry: PublicResponse) => { bytes += entry.bytes; });
    while (StoreClient.responses.size > 64 || bytes > 8 * 1024 * 1024) {
      const first = Array.from(StoreClient.responses.keys())[0];
      bytes -= StoreClient.responses.get(first)?.bytes ?? 0;
      StoreClient.responses.delete(first);
    }
  }

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
    account?: DeveloperAccount, body?: Object, retried: boolean = false): Promise<Record<string, Object>> {
    const request = http.createHttp();
    const epoch = StoreClient.responseEpoch;
    try {
      const headers: Record<string, string> = {};
      const cached = !account && method === http.RequestMethod.GET ? StoreClient.responses.get(path) : undefined;
      if (cached?.etag) headers['If-None-Match'] = cached.etag;
      if (account) {
        if (account.jwtToken.length === 0 || account.accessToken.length === 0) {
          throw new ServiceFailure(FailureKind.ACCOUNT, '请先登录华为开发者账号', 401);
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
      if (response.responseCode === 304 && cached) {
        if (epoch === StoreClient.responseEpoch) cached.receivedAt = Date.now();
        return cached.data;
      }
      if (response.responseCode === 401 && account && !retried) {
        AccountService.configure(this.context);
        await AccountService.refresh(account, true);
        return this.requestData(path, method, account, body, true);
      }
      if (typeof response.result !== 'string') {
        throw new Error('商店服务响应格式无效');
      }
      const envelope = JSON.parse(response.result) as Record<string, Object>;
      if (envelope['ok'] !== true) {
        const error = envelope['error'] as Record<string, Object> | undefined;
        throw new ServiceFailure(response.responseCode === 401 ? FailureKind.ACCOUNT :
          response.responseCode === 403 ? FailureKind.INTERNAL : FailureKind.NETWORK,
          String(error?.['message'] ?? '商店服务暂不可用') +
          (error?.['hint'] ? ' · ' + String(error['hint']) : ''), response.responseCode);
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('商店服务返回 ' + response.responseCode);
      }
      const data = envelope['data'] as Record<string, Object>;
      if (!account && method === http.RequestMethod.GET && epoch === StoreClient.responseEpoch) {
        const responseHeaders = response.header as Record<string, Object>;
        const etag = String(responseHeaders?.['etag'] ?? responseHeaders?.['ETag'] ?? '');
        StoreClient.remember(path, etag, data);
      }
      if (method !== http.RequestMethod.GET && /^\/api\/v1\/(apps\/|me\/apps|submit\/confirm)/.test(path)) {
        StoreClient.invalidatePublic();
      }
      return data;
    } finally {
      request.destroy();
    }
  }

  private getData(path: string, account?: DeveloperAccount,
    freshnessMs: number = 0): Promise<Record<string, Object>> {
    // 私有数据不共享；公开读取按完整路径（含频道、分页）合并。
    if (account) return this.requestData(path, http.RequestMethod.GET, account);
    const cached = StoreClient.responses.get(path);
    if (cached && freshnessMs > 0 && Date.now() - cached.receivedAt < freshnessMs) {
      return Promise.resolve(cached.data);
    }
    const existing = StoreClient.publicReads.get(path);
    if (existing) return existing;
    const read = this.requestData(path, http.RequestMethod.GET).finally(() => {
      if (StoreClient.publicReads.get(path) === read) StoreClient.publicReads.delete(path);
    });
    StoreClient.publicReads.set(path, read);
    return read;
  }

  /// ``page`` is 1-based. ``discover`` ranks featured apps before pagination.
  /// Other orders: updated/stars/name/new.
  /// ``query`` 走服务端搜索：只过滤本地已加载的那一页会漏掉没加载的应用。
  async listApps(page: number = 1, pageSize: number = 30,
    sort: string = 'updated', query: string = '', category: string = '',
    forceRefresh: boolean = false, direction: string = '', snapshot: string = '',
    stablePages: boolean = false): Promise<ListPage<CatalogApp>> {
    const trimmed = query.trim();
    const data = await this.getData('/api/v1/apps?sort=' + encodeURIComponent(sort) +
      '&page=' + Math.max(1, Math.floor(page)) +
      '&page_size=' + Math.min(100, Math.max(1, Math.floor(pageSize))) +
      (trimmed.length > 0 ? '&q=' + encodeURIComponent(trimmed) : '') +
      (category.trim().length > 0 ? '&category=' + encodeURIComponent(category.trim()) : '') +
      (direction.length > 0 ? '&direction=' + encodeURIComponent(direction) : '') +
      (stablePages ? '&pagination=snapshot' : '') +
      (snapshot.length > 0 ? '&snapshot=' + encodeURIComponent(snapshot) : ''),
      undefined, forceRefresh ? 0 : 30000);
    const result = new ListPage<CatalogApp>();
    result.snapshot = String(data['snapshot'] ?? '');
    result.snapshotExpired = data['snapshot_expired'] === true;
    const raw = data['items'] as Array<Record<string, Object>> | undefined;
    result.rawItems = raw ?? [];
    result.items = (raw ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', page);
    result.pageSize = numberField(data, 'page_size', pageSize);
    return result;
  }

  async appDetail(id: number): Promise<CatalogApp> {
    const app = CatalogApp.fromJson(await this.getData('/api/v1/apps/' + id, undefined, 30000));
    StoreClient.viewedApps.set(id, CatalogApp.copy(app));
    if (StoreClient.viewedApps.size > 32) StoreClient.viewedApps.delete(Array.from(StoreClient.viewedApps.keys())[0]);
    return app;
  }

  /**
   * 图标的原始字节。
   *
   * 单独抽出来是为了能缓存：PixelMap 不能序列化，但字节可以。冷启动时先用
   * 缓存的字节直接画出图标，再去后端刷新。
   */
  private async cachedIconBytes(app: CatalogApp, useCache: boolean): Promise<ArrayBuffer | undefined> {
    if (app.id <= 0 || app.iconUrl !== '/api/v1/apps/' + app.id + '/icon') {
      return undefined;
    }
    if (useCache) {
      const cached = await CatalogCache.loadIcons(this.context, [app]);
      const bytes = cached.get(app.id);
      if (bytes !== undefined) return bytes;
    }
    const key = app.id + ':' + app.iconRev;
    const existing = StoreClient.iconReads.get(key);
    if (existing) return existing;
    const read = this.appIconBytes(app).then(async (bytes: ArrayBuffer | undefined) => {
      if (bytes !== undefined && app.iconRev && CatalogCache.iconWithinLimit(bytes)) {
        const icon = new CachedIcon();
        icon.id = String(app.id); icon.rev = app.iconRev;
        icon.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
        await CatalogCache.saveIcons(this.context, [icon]);
      }
      return bytes;
    }).finally(() => {
      if (StoreClient.iconReads.get(key) === read) StoreClient.iconReads.delete(key);
    });
    StoreClient.iconReads.set(key, read);
    return read;
  }

  async appIconBytes(app: CatalogApp): Promise<ArrayBuffer | undefined> {
    if (app.id <= 0 || app.iconUrl !== '/api/v1/apps/' + app.id + '/icon') return undefined;
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
    for (let attempt = 0; attempt < 2; attempt++) {
      const bytes = await this.cachedIconBytes(app, attempt === 0);
      if (bytes === undefined) return undefined;
      try {
        const source = image.createImageSource(bytes);
        try { return await source.createPixelMap({ desiredSize: { width: 256, height: 256 } }); }
        finally { await source.release(); }
      } catch (_) {
        // 本地缓存损坏时只绕过一次缓存取新图，不能持续返回坏图。
      }
    }
    return undefined;
  }

  /** Enqueue a bounded server refresh; heavy collection runs in the worker. */
  async refreshApp(appId: number): Promise<string> {
    if (appId <= 0) throw new Error('应用编号无效');
    const data = await this.requestData('/api/v1/apps/' + appId + '/refresh',
      http.RequestMethod.POST, undefined, new EmptyBody());
    return String(data['status'] ?? 'done');
  }

  async refreshStatus(appId: number): Promise<string> {
    const data = await this.getData('/api/v1/apps/' + appId + '/refresh');
    const status = String(data['status'] ?? 'done');
    if (status === 'done') StoreClient.invalidatePublic();
    if (status === 'failed') throw new Error(String(data['last_error'] ?? '仓库检查失败'));
    return status;
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
      '&prerelease=' + (includePrerelease ? '1' : '0'), undefined, 30000);
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

  async submitStatus(draft: SubmitDraft, account: DeveloperAccount): Promise<SubmitDraft> {
    const body = new ConfirmBody();
    body.draft_token = draft.token;
    const data = await this.requestData('/api/v1/submit/status', http.RequestMethod.POST, account, body);
    return SubmitDraft.fromJson(data);
  }

  async confirmSubmit(draft: SubmitDraft, assetNames: string[], category: string,
    account: DeveloperAccount): Promise<CatalogApp> {
    if (assetNames.length > 1 && !draft.supportsMultiSelect) {
      throw new Error('服务器尚未支持多包上架，请先更新服务端');
    }
    const body = new ConfirmBody();
    body.draft_token = draft.token;
    body.asset_name = assetNames[0] ?? '';
    body.asset_names = assetNames;
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

  async prepareAppSource(id: number, repoUrl: string, account: DeveloperAccount): Promise<SubmitDraft> {
    const body = new PrepareBody();
    body.repo_url = repoUrl;
    const data = await this.requestData('/api/v1/me/apps/' + id + '/source/prepare',
      http.RequestMethod.POST, account, body);
    return SubmitDraft.fromJson(data);
  }

  async configureMyApp(id: number, category: string, account: DeveloperAccount,
    sourceDraftToken: string = '', removeSecondary: boolean = false): Promise<CatalogApp> {
    const body = new CategoryBody();
    body.category = category;
    body.source_draft_token = sourceDraftToken;
    body.remove_secondary = removeSecondary;
    const data = await this.requestData('/api/v1/me/apps/' + id + '/category',
      http.RequestMethod.POST, account, body);
    return CatalogApp.fromJson(data['app'] as Record<string, Object>);
  }

  /// Reviews always sort newest first, so page 1 is also what a new review lands on.
  async listReviews(appId: number, page: number = 1,
    pageSize: number = 20): Promise<ListPage<AppReview>> {
    const data = await this.getData('/api/v1/apps/' + appId + '/reviews?page=' +
      Math.max(1, Math.floor(page)) + '&page_size=' +
      Math.min(50, Math.max(1, Math.floor(pageSize))), undefined, 15000);
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

  /** 按账号及证书保留成功备份的回执，不把其他设备的版本作为轮换条件。 */
  async rememberSigningIdentity(account: DeveloperAccount, identity: BackedUpIdentity): Promise<void> {
    if (!Number.isSafeInteger(identity.revision) || identity.revision < 1) {
      throw new Error('备份服务尚未支持版本校验，请更新服务端');
    }
    const store = await preferences.getPreferences(this.context, 'signing-backup-version');
    // 这里只保存版本，不复制私钥到 preferences。
    const baseline = new BackedUpIdentity();
    baseline.certId = identity.certId;
    baseline.revision = identity.revision;
    await store.put(account.userId + ':' + identity.certId, JSON.stringify(baseline));
    await store.flush();
  }

  async publishSigningIdentity(certId: string, privateKeyPem: string,
    account: DeveloperAccount): Promise<void> {
    const body = new IdentityBody();
    body.cert_id = certId;
    body.private_key_pem = privateKeyPem;
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

  async signingIdentity(account: DeveloperAccount, certId: string = ''): Promise<BackedUpIdentity | undefined> {
    const data = await this.getData('/api/v1/signing-identity' +
      (certId.length > 0 ? '?cert_id=' + encodeURIComponent(certId) : ''), account);
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
    if (certId.length > 0 && identity.certId !== certId) {
      throw new Error('备份服务返回了其他证书，已保留本机身份，请更新服务端');
    }
    return identity;
  }
}
