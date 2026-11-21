import { FollowedApp,FollowChange } from './Following';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { CatalogApp } from './CatalogApp';
import { DiscoveryCollections } from './DiscoveryCollections';
import { CatalogCache, CachedIcon } from './CatalogCache';
import { ReleaseInfo } from './ReleaseInfo';
import { DeveloperAccount } from './DeveloperAccount';
import { AccountService } from './AccountService';
import { ServiceFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';
import { SubmitDraft, AppReview, ReviewReply, reviewDeviceModel } from './StoreActions';
import { PrivacyConsent } from './PrivacyConsent';
import { CloudBackupConsent } from './CloudBackupConsent';
import { I18n } from './I18n';
import { StoreBuildConfig } from './StoreBuildConfig';
import { StoreRoute } from './StoreRoute';
import { DeveloperCenterState, GitHubAssociationStatus, RepositoryClaim } from './DeveloperRegistry';
import { ListingPresentation } from './ListingPresentation';

class PrepareBody { repo_url: string = ''; }
class ConfirmBody {
  asset_name: string = ''; draft_token: string = ''; asset_names: string[] = []; category: string = '';
  presentation?: ListingPresentation;
}
class ReviewReplyBody {
  body: string = '';
  reply_to_id?: number;
  device_model?: string;
}
class ReviewBody { stars: number = 0; body: string = ''; device_model?: string; }
class ReviewVisibilityBody { hidden: boolean = false; }
class ClaimActionBody { action: string = ''; }
class GitHubAssociationBody { receipt: string = ''; }
class GitHubNativeAssociationBody { state: string = ''; code: string = ''; }
class CategoryBody {
  category: string = '';
  source_draft_token: string = '';
  remove_secondary: boolean = false;
  primary_repo_url: string = '';
  expected_repo: string = '';
  presentation?: ListingPresentation;
  expected_configuration?: string;
}
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

export class UpdatePushWatchItem {
  app_id: number = 0;
  bundle_name: string = '';
  version_code: number = 0;
}

class FollowingBody { changes:FollowChange[]=[]; }
class PersonalLibraryBody { client_id: string = ''; items: UpdatePushWatchItem[] = []; }

class UpdatePushBody {
  deep_link:boolean=false;
  client_id: string = '';
  nickname: string = '';
  subscription: string = '';
  code: string = '';
  enabled: boolean = false;
  include_prerelease: boolean = false;
  items: UpdatePushWatchItem[] = [];
}

/// Server page size ceilings: /apps caps page_size at 100, /releases and
/// /reviews at 50. Every listing returns total next to items.
export class ListPage<T> {
  networkScope: string = '';
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

export class ReviewPage extends ListPage<AppReview> {
  ratingCount: number = 0;
  ratingAverage: number = 0;
  repliesSupported: boolean = false;
  canModerate: boolean = false;
  claimedByMe: boolean | undefined = undefined;
  static fromJson(data: Record<string, Object>, page: number, pageSize: number): ReviewPage {
    const result = new ReviewPage();
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    result.items = (rows ?? []).map((row: Record<string, Object>) => AppReview.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', page);
    result.pageSize = numberField(data, 'page_size', pageSize);
    const summary = data['summary'] as Record<string, Object> | undefined;
    result.ratingCount = summary ? numberField(summary, 'count', result.total) : result.total;
    result.ratingAverage = summary ? numberField(summary, 'average', 0) : 0;
    result.repliesSupported = data['replies_supported'] === true;
    result.canModerate = data['can_moderate'] === true;
    if (typeof data['claimed_by_me'] === 'boolean') result.claimedByMe = data['claimed_by_me'] === true;
    return result;
  }
}

export class ReviewReplyPage extends ListPage<ReviewReply> {
  targetsSupported: boolean = false;
  preview?: ReviewReply[];

  static fromJson(data: Record<string, Object>): ReviewReplyPage {
    const result = new ReviewReplyPage();
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    result.items = (rows ?? []).map((row: Record<string, Object>) => ReviewReply.fromJson(row));
    result.total = numberField(data, 'total', result.items.length);
    result.page = numberField(data, 'page', 1);
    result.pageSize = numberField(data, 'page_size', 10);
    result.targetsSupported = data['reply_targets_supported'] === true;
    const preview = data['reply_preview'] as Array<Record<string, Object>> | undefined;
    if (Array.isArray(preview)) result.preview = preview.map(item => ReviewReply.fromJson(item));
    return result;
  }
}

export class BackedUpIdentity {
  revision: number = 0;
  certId: string = '';
  privateKeyPem: string = '';
}

export class RepositoryReadme {
  found: boolean = false;
  html: string = '';
  sourceUrl: string = '';
  static fromJson(data: Record<string, Object>): RepositoryReadme {
    const value = new RepositoryReadme();
    value.found = data['found'] === true;
    value.html = String(data['html'] ?? '');
    value.sourceUrl = String(data['source_url'] ?? '');
    return value;
  }
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

export class PublishedAppConfiguration {
  app: CatalogApp = new CatalogApp();
  revision: string = '';
  categories: string[] = [];

  static fromJson(data: Record<string, Object>): PublishedAppConfiguration {
    const result = new PublishedAppConfiguration();
    result.revision = String(data['configuration'] ?? '');
    const row = data['app'] as Record<string, Object> | undefined;
    if (!row || !/^[a-f0-9]{24}$/.test(result.revision) || !Array.isArray(row['screenshots'])) {
      throw new Error(I18n.t('服务器未返回有效配置，请重新打开后重试'));
    }
    result.app = CatalogApp.fromJson(row);
    result.categories = (data['categories'] as string[] | undefined) ?? [];
    return result;
  }
}

export class StoreClient implements RenewalCatalog {
  private static viewedApps: Map<number, CatalogApp> = new Map();
  private static listingRevision: number = 0;
  private static recentlyUnlisted: number[] = [];

  static publicationRevision(): number { return StoreClient.listingRevision; }
  static takeUnlisted(): number[] {
    const ids = StoreClient.recentlyUnlisted;
    StoreClient.recentlyUnlisted = [];
    return ids;
  }

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
  private static networkScope: string = '';
  static currentScope(): string { return StoreClient.networkScope; }
  static beginRefresh(): void {
    StoreClient.networkScope = '';
    StoreClient.invalidatePublic(); StoreRoute.revalidate();
  }
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
    while (StoreClient.responses.size > 24 || bytes > 2 * 1024 * 1024) {
      const first = Array.from(StoreClient.responses.keys())[0];
      bytes -= StoreClient.responses.get(first)?.bytes ?? 0;
      StoreClient.responses.delete(first);
    }
  }

  private static readonly BASE_URL = StoreBuildConfig?.baseUrl ?? 'https://store.example.invalid';
  private static readonly PUBLIC_KEY_SHA256 = StoreBuildConfig?.publicKeySha256 ?? '';
  private caData: string;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    if (!StoreBuildConfig?.configured) throw new Error(I18n.t('此构建未配置商店服务'));
    this.caData = StoreBuildConfig.caData;
    StoreRoute.onNetworkChange(() => {
      StoreClient.networkScope = '';
      StoreClient.invalidatePublic();
    });
  }

  private async requestData(path: string, method: http.RequestMethod,
    account?: DeveloperAccount, body?: Object, retried: boolean = false,
    generationRetry: number = 0): Promise<Record<string, Object>> {
    PrivacyConsent.assertBusinessAllowed();
    await StoreRoute.prepare();
    const request = http.createHttp();
    const epoch = StoreClient.responseEpoch;
    try {
      const headers: Record<string, string> = {};
      headers['Cache-Control'] = 'no-cache';
      const liveReadme = /\/readme(?:\?|$)/.test(path);
      const cached = !account && method === http.RequestMethod.GET && !liveReadme ? StoreClient.responses.get(path) : undefined;
      if (cached?.etag) headers['If-None-Match'] = cached.etag;
      if (account) {
        if (account.jwtToken.length === 0 || account.accessToken.length === 0) {
          throw new ServiceFailure(FailureKind.ACCOUNT, I18n.t('请先登录华为开发者账号'), 401);
        }
        headers['Authorization'] = 'Bearer ' + account.jwtToken;
        headers['X-Huawei-Access-Token'] = account.accessToken;
        if (account.site && account.site !== 'CN') headers['X-Huawei-Site'] = account.site;
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
        usingCache: false,
        caData: this.caData,
        certificatePinning: {
          publicKeyHash: StoreClient.PUBLIC_KEY_SHA256,
          hashAlgorithm: 'SHA-256'
        },
        maxLimit: 2 * 1024 * 1024
      };
      if (body) options.extraData = JSON.stringify(body);
      if (path.startsWith('/api/v1/signing-identity') && account &&
        !await CloudBackupConsent.allowed(this.context, account)) {
        throw new Error(I18n.t('云备份未启用，本机签名材料已保留'));
      }
      PrivacyConsent.assertBusinessAllowed();
      if (path.startsWith('/api/v1/signing-identity') && account &&
        !CloudBackupConsent.isAllowedNow(this.context, account)) {
        throw new Error(I18n.t('云备份已停用，本机签名材料已保留'));
      }
      const response = await StoreRoute.request(request, path, options);
      PrivacyConsent.assertBusinessAllowed();
      if (!account && method === http.RequestMethod.GET && epoch !== StoreClient.responseEpoch) {
        // Never publish an old-route result after an explicit refresh or an exit
        // change. Retry once against the current generation, with no old ETag.
        if (generationRetry >= 1) throw new ServiceFailure(FailureKind.NETWORK, I18n.t('网络已切换，请重新刷新'));
        return this.requestData(path, method, account, body, retried, generationRetry + 1);
      }
      if (response.responseCode === 304 && cached) {
        if (epoch === StoreClient.responseEpoch) cached.receivedAt = Date.now();
        return cached.data;
      }
      if (response.responseCode === 401 && account && !retried) {
        PrivacyConsent.assertBusinessAllowed();
        AccountService.configure(this.context);
        await AccountService.refresh(account, true);
        PrivacyConsent.assertBusinessAllowed();
        return this.requestData(path, method, account, body, true);
      }
      if (response.responseCode === 429 || response.responseCode >= 500) {
        throw new ServiceFailure(FailureKind.NETWORK, response.responseCode === 429 ?
          I18n.t('请求过于频繁，请稍后重试') : I18n.t('商店服务响应异常，请稍后重试'), response.responseCode);
      }
      if (typeof response.result !== 'string') {
        throw new Error(I18n.t('商店服务响应格式无效'));
      }
      const envelope = JSON.parse(response.result) as Record<string, Object>;
      if (envelope['ok'] !== true) {
        const error = envelope['error'] as Record<string, Object> | undefined;
        throw new ServiceFailure(response.responseCode === 401 ? FailureKind.ACCOUNT :
          response.responseCode === 403 ? FailureKind.INTERNAL : FailureKind.NETWORK,
          String(error?.['message'] ?? I18n.t('商店服务暂不可用')) +
          (error?.['hint'] ? ' · ' + String(error['hint']) : ''), response.responseCode);
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(I18n.t('商店服务返回 ') + response.responseCode);
      }
      const data = envelope['data'] as Record<string, Object>;
      if (!account && (data['network_scope'] === 'ordinary' || data['network_scope'] === 'overseas')) {
        const scope = String(data['network_scope']);
        if (StoreClient.networkScope && StoreClient.networkScope !== scope) StoreClient.invalidatePublic();
        StoreClient.networkScope = scope;
      }
      if (!account && method === http.RequestMethod.GET && !liveReadme && epoch === StoreClient.responseEpoch) {
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

  private async getData(path: string, account?: DeveloperAccount,
    freshnessMs: number = 0): Promise<Record<string, Object>> {
    // 私有数据不共享；公开读取按完整路径（含频道、分页）合并。
    if (account) return this.requestData(path, http.RequestMethod.GET, account);
    await StoreRoute.prepare();
    const cached = StoreClient.responses.get(path);
    if (cached && freshnessMs > 0 && Date.now() - cached.receivedAt < freshnessMs) {
      return cached.data;
    }
    const existing = StoreClient.publicReads.get(path);
    if (existing) return existing;
    const read = this.requestData(path, http.RequestMethod.GET).finally(() => {
      if (StoreClient.publicReads.get(path) === read) StoreClient.publicReads.delete(path);
    });
    StoreClient.publicReads.set(path, read);
    return read;
  }

  async following(account:DeveloperAccount,changes:FollowChange[]=[]):Promise<FollowedApp[]>{
    const body=new FollowingBody();body.changes=changes;
    const data=changes.length?await this.requestData('/api/v1/me/following',http.RequestMethod.POST,account,body):await this.getData('/api/v1/me/following',account);
    const rows=data['items'] as Array<Record<string,Object>>;
    return (Array.isArray(rows)?rows:[]).slice(0,200).map((row:Record<string,Object>)=>FollowedApp.fromJson(row));
  }

  /** A private retry stays outside shared public caches and in-flight reads. */
  private async getAppData(path: string, freshnessMs: number = 0): Promise<Record<string, Object>> {
    try { return await this.getData(path, undefined, freshnessMs); }
    catch (error) {
      const failure = error as Error;
      if (!(failure instanceof ServiceFailure) || failure.status !== 404) throw failure;
      const account = await AccountService.current(this.context);
      if (!account) throw failure;
      const data = await this.getData(path, account);
      data['personal_access'] = true;
      return data;
    }
  }

  async personalCatalog(account: DeveloperAccount, clientId: string, items: UpdatePushWatchItem[]): Promise<CatalogApp[]> {
    const body = new PersonalLibraryBody(); body.client_id = clientId; body.items = items.slice(0, 200);
    const data = await this.requestData('/api/v1/me/library', http.RequestMethod.POST, account, body);
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => {
      const app = CatalogApp.fromJson(row); app.personalOnly = true; return app;
    });
  }

  async updatePushState(account: DeveloperAccount, clientId: string): Promise<Record<string, Object>> {
    return this.getData('/api/v1/me/update-push?client_id=' + encodeURIComponent(clientId), account);
  }

  async webPushPublicKey(): Promise<Record<string, Object>> {
    return this.getData('/api/v1/push/vapid-key');
  }

  async webPushChallenge(account: DeveloperAccount, clientId: string,
    subscription: string): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId; body.subscription = subscription;
    return this.requestData('/api/v1/me/update-push/webpush-challenge', http.RequestMethod.POST, account, body);
  }

  async webPushConfirm(account: DeveloperAccount, clientId: string,
    code: string): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId; body.code = code;
    return this.requestData('/api/v1/me/update-push/webpush-confirm', http.RequestMethod.POST, account, body);
  }

  async updatePushChallenge(account: DeveloperAccount, clientId: string,
    nickname: string): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId; body.nickname = nickname;
    return this.requestData('/api/v1/me/update-push/challenge', http.RequestMethod.POST, account, body);
  }

  async updatePushConfirm(account: DeveloperAccount, clientId: string,
    code: string): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId; body.code = code;
    return this.requestData('/api/v1/me/update-push/confirm', http.RequestMethod.POST, account, body);
  }

  async updatePushPreferences(account: DeveloperAccount, clientId: string,
    enabled: boolean): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId;
    body.enabled = enabled; body.include_prerelease = true;
    return this.requestData('/api/v1/me/update-push/preferences', http.RequestMethod.POST, account, body);
  }

  async updatePushWatchlist(account: DeveloperAccount, clientId: string,
    items: UpdatePushWatchItem[]): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId; body.items = items; body.deep_link=true;
    return this.requestData('/api/v1/me/update-push/watchlist', http.RequestMethod.POST, account, body);
  }

  async updatePushTest(account: DeveloperAccount, clientId: string): Promise<Record<string, Object>> {
    const body = new UpdatePushBody(); body.client_id = clientId;
    return this.requestData('/api/v1/me/update-push/test', http.RequestMethod.POST, account, body);
  }

  async updatePushRemove(account: DeveloperAccount, clientId: string): Promise<Record<string, Object>> {
    return this.requestData('/api/v1/me/update-push?client_id=' + encodeURIComponent(clientId)+'&account_scope=1',
      http.RequestMethod.DELETE, account);
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
    result.networkScope = String(data['network_scope'] ?? '');
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

  async collections(windowDays: number = 7, limit: number = 8, key: string = '',
    page: number = 1, force: boolean = false): Promise<DiscoveryCollections> {
    const filter = key.length > 0 ? '&key=' + encodeURIComponent(key) + '&page=' + page : '';
    const data = await this.getData('/api/v1/collections?window_days=' + windowDays +
      '&limit=' + limit + filter, undefined, force ? 0 : 60000);
    return DiscoveryCollections.fromJson(data);
  }

  async repositoryReadme(id: number, forceRefresh: boolean = false, language: string = ''): Promise<RepositoryReadme> {
    const locale = language === 'zh' || language === 'en' ? '?lang=' + language : '';
    return RepositoryReadme.fromJson(await this.getAppData('/api/v1/apps/' + id + '/readme' + locale, 0));
  }

  async appDetail(id: number, forceRefresh: boolean = false): Promise<CatalogApp> {
    const epoch = StoreClient.responseEpoch;
    const app = CatalogApp.fromJson(await this.getAppData('/api/v1/apps/' + id, forceRefresh ? 0 : 30000));
    const previous = StoreClient.viewedApps.get(id);
    const at = Number(app.updatedAt), previousAt = Number(previous?.updatedAt);
    const known = Number.isFinite(at) && at > 0;
    const previousKnown = Number.isFinite(previousAt) && previousAt > 0;
    // 请求缓存已失效时，迟到结果仍可返回给原调用方，但不能回灌已更新的列表。
    if (epoch === StoreClient.responseEpoch && (previous === undefined || !previousKnown ||
      (known && at >= previousAt))) {
      StoreClient.viewedApps.set(id, CatalogApp.copy(app));
      if (StoreClient.viewedApps.size > 32) StoreClient.viewedApps.delete(Array.from(StoreClient.viewedApps.keys())[0]);
    }
    return app;
  }

  /**
   * 图标的原始字节。
   *
   * 单独抽出来是为了能缓存：PixelMap 不能序列化，但字节可以。冷启动时先用
   * 缓存的字节直接画出图标，再去后端刷新。
   */
  private async cachedIconBytes(app: CatalogApp, useCache: boolean): Promise<ArrayBuffer | undefined> {
    const cacheGeneration = CatalogCache.generation();
    if (app.id <= 0 || app.iconUrl !== '/api/v1/apps/' + app.id + '/icon') {
      return undefined;
    }
    if (useCache) {
      const cached = await CatalogCache.loadIcons(this.context, [app]);
      const bytes = cached.get(app.id);
      if (bytes !== undefined) return bytes;
    }
    const key = app.id + ':' + app.iconRev + ':' + cacheGeneration;
    const existing = StoreClient.iconReads.get(key);
    if (existing) return existing;
    const read = this.appIconBytes(app).then(async (bytes: ArrayBuffer | undefined) => {
      if (bytes !== undefined && app.iconRev && CatalogCache.iconWithinLimit(bytes)) {
        const icon = new CachedIcon();
        icon.id = String(app.id); icon.rev = app.iconRev;
        icon.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
        await CatalogCache.saveIcons(this.context, [icon], cacheGeneration);
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
    const revision = app.iconRev.length > 0 ? '?v=' + encodeURIComponent(app.iconRev) : '';
    return this.appImageBytes(app.iconUrl + revision);
  }

  async screenshotBytes(appId: number, digest: string): Promise<ArrayBuffer | undefined> {
    if (!Number.isSafeInteger(appId) || appId <= 0 || !/^[a-f0-9]{24}$/.test(digest)) return undefined;
    return this.appImageBytes('/api/v1/apps/' + appId + '/screenshots/' + digest);
  }

  private async appImageBytes(path: string): Promise<ArrayBuffer | undefined> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
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
      };
      let response = await StoreRoute.request(request, path, options);
      if (response.responseCode === 404) {
        const account = await AccountService.current(this.context);
        if (account && account.jwtToken.length > 0 && account.accessToken.length > 0) {
          options.header = { 'Authorization': 'Bearer ' + account.jwtToken,
            'X-Huawei-Access-Token': account.accessToken };
          if (account.site && account.site !== 'CN') {
            (options.header as Record<string, string>)['X-Huawei-Site'] = account.site;
          }
          response = await StoreRoute.request(request, path, options);
        }
      }
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

  /** The full source file, preserving its dimensions, alpha and encoding. */
  async originalIconBytes(app: CatalogApp): Promise<ArrayBuffer | undefined> {
    return this.cachedIconBytes(app, true);
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
    if (appId <= 0) throw new Error(I18n.t('应用编号无效'));
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
    pageSize: number = 20, includePrerelease: boolean = false,
    forceRefresh: boolean = false): Promise<ListPage<ReleaseInfo>> {
    const data = await this.getAppData('/api/v1/apps/' + appId + '/releases?page=' +
      Math.max(1, Math.floor(page)) + '&page_size=' +
      Math.min(50, Math.max(1, Math.floor(pageSize))) +
      '&prerelease=' + (includePrerelease ? '1' : '0'), forceRefresh ? 0 : 30000);
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
    account: DeveloperAccount, presentation?: ListingPresentation): Promise<CatalogApp> {
    if (assetNames.length > 1 && !draft.supportsMultiSelect) {
      throw new Error(I18n.t('服务器尚未支持多包上架，请先更新服务端'));
    }
    const body = new ConfirmBody();
    body.draft_token = draft.token;
    body.asset_name = assetNames[0] ?? '';
    body.asset_names = assetNames;
    body.category = category;
    body.presentation = presentation;
    const data = await this.requestData('/api/v1/submit/confirm', http.RequestMethod.POST,
      account, body);
    return CatalogApp.fromJson(data['app'] as Record<string, Object>);
  }

  async myApps(account: DeveloperAccount): Promise<CatalogApp[]> {
    const data = await this.getData('/api/v1/me/apps', account);
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    return (rows ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
  }

  async developerCenter(account: DeveloperAccount, enroll: boolean = false): Promise<DeveloperCenterState> {
    const path = '/api/v1/me/developer';
    const data = enroll ? await this.requestData(path, http.RequestMethod.POST, account, new EmptyBody()) :
      await this.getData(path, account);
    return DeveloperCenterState.fromJson(data);
  }

  async repositoryClaim(appId: number, account: DeveloperAccount, action: string = ''): Promise<RepositoryClaim> {
    const path = '/api/v1/apps/' + appId + '/claim';
    const body = new ClaimActionBody();
    body.action = action;
    const data = action ? await this.requestData(path, http.RequestMethod.POST, account, body) :
      await this.getData(path, account);
    const claim = RepositoryClaim.fromJson(data);
    if (action && claim.status === 'mine') StoreClient.listingRevision++;
    return claim;
  }

  async releaseClaim(appId: number, account: DeveloperAccount): Promise<DeveloperCenterState> {
    const data = await this.requestData('/api/v1/me/developer/claims/' + appId, http.RequestMethod.DELETE, account);
    return DeveloperCenterState.fromJson(data);
  }

  async githubAssociationStatus(account: DeveloperAccount): Promise<GitHubAssociationStatus> {
    try {
      const data = await this.getData('/api/v1/me/developer/github', account);
      return GitHubAssociationStatus.fromJson(data);
    } catch (error) {
      if (error instanceof ServiceFailure && error.status === 404) return new GitHubAssociationStatus();
      throw error as Error;
    }
  }

  async startGitHubAssociation(account: DeveloperAccount): Promise<string> {
    const data = await this.requestData('/api/v1/me/developer/github/start', http.RequestMethod.POST,
      account, new EmptyBody());
    return String(data['authorization_url'] ?? '');
  }

  async confirmGitHubAssociation(receipt: string, account: DeveloperAccount): Promise<void> {
    const body = new GitHubAssociationBody();
    body.receipt = receipt;
    await this.requestData('/api/v1/me/developer/github/confirm', http.RequestMethod.POST, account, body);
  }

  async confirmGitHubNativeAssociation(state: string, code: string, account: DeveloperAccount): Promise<void> {
    const body = new GitHubNativeAssociationBody();
    body.state = state;
    body.code = code;
    await this.requestData('/api/v1/me/developer/github/confirm', http.RequestMethod.POST, account, body);
  }

  async unlinkGitHubAssociation(account: DeveloperAccount): Promise<GitHubAssociationStatus> {
    const data = await this.requestData('/api/v1/me/developer/github', http.RequestMethod.DELETE, account);
    return GitHubAssociationStatus.fromJson(data);
  }

  async removeMyApp(id: number, account: DeveloperAccount): Promise<void> {
    const result = await this.requestData('/api/v1/me/apps/' + id, http.RequestMethod.DELETE, account);
    if (result['removed'] !== true) throw new Error(I18n.t('服务器未确认下架，请刷新后重试'));
    StoreClient.viewedApps.delete(id);
    StoreClient.recentlyUnlisted.push(id);
    StoreClient.listingRevision++;
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

  async ownedAppConfiguration(id: number, account: DeveloperAccount): Promise<PublishedAppConfiguration> {
    const path = '/api/v1/me/apps/' + id + '/configuration';
    return PublishedAppConfiguration.fromJson(await this.getData(path, account));
  }

  async configureMyApp(config: PublishedAppConfiguration, category: string, account: DeveloperAccount,
    sourceDraftToken: string = '', removeSecondary: boolean = false, primaryRepoUrl: string = '',
    presentation?: ListingPresentation): Promise<PublishedAppConfiguration> {
    const body = new CategoryBody();
    body.category = category;
    body.source_draft_token = sourceDraftToken;
    body.remove_secondary = removeSecondary;
    body.primary_repo_url = primaryRepoUrl;
    body.expected_repo = config.app.repo;
    body.expected_configuration = config.revision;
    body.presentation = presentation;
    const data = await this.requestData('/api/v1/me/apps/' + config.app.id + '/category',
      http.RequestMethod.POST, account, body);
    const saved = PublishedAppConfiguration.fromJson(data);
    if (saved.app.id !== config.app.id) throw new Error(I18n.t('服务器未返回有效配置，请重新打开后重试'));
    StoreClient.viewedApps.set(saved.app.id, CatalogApp.copy(saved.app));
    StoreClient.listingRevision++;
    return saved;
  }

  /// Reviews always sort newest first, so page 1 is also what a new review lands on.
  async listReviews(appId: number, page: number = 1,
    pageSize: number = 20, account?: DeveloperAccount): Promise<ReviewPage> {
    const query = '?reply_preview=1&page=' + Math.max(1, Math.floor(page)) +
      '&page_size=' + Math.min(50, Math.max(1, Math.floor(pageSize)));
    if (account) {
      try {
        const data = await this.requestData('/api/v1/me/apps/' + appId + '/reviews' + query,
          http.RequestMethod.GET, account);
        return ReviewPage.fromJson(data, page, pageSize);
      } catch (_) { /* Expired identity must not hide the public discussion. */ }
    }
    const data = await this.getAppData('/api/v1/apps/' + appId + '/reviews' + query, 15000);
    return ReviewPage.fromJson(data, page, pageSize);
  }

  async postReview(appId: number, stars: number, body: string,
    account: DeveloperAccount): Promise<ReviewPage> {
    const payload = new ReviewBody(); payload.stars = stars; payload.body = body;
    payload.device_model = this.commentDeviceModel();
    const data = await this.requestData('/api/v1/apps/' + appId + '/reviews?reply_preview=1', http.RequestMethod.POST,
      account, payload);
    return ReviewPage.fromJson(data, 1, 20);
  }

  async deleteReview(appId: number, reviewId: number, page: number,
    account: DeveloperAccount): Promise<ReviewPage> {
    const data = await this.requestData('/api/v1/apps/' + appId + '/reviews/' + reviewId +
      '?reply_preview=1&page=' + Math.max(1, Math.floor(page)) + '&page_size=20', http.RequestMethod.DELETE, account);
    return ReviewPage.fromJson(data, page, 20);
  }

  async moderateReview(appId: number, reviewId: number, page: number, hidden: boolean,
    account: DeveloperAccount): Promise<ReviewPage> {
    const body = new ReviewVisibilityBody();
    body.hidden = hidden;
    const path = '/api/v1/apps/' + appId + '/reviews/' + reviewId +
      '/visibility?reply_preview=1&page=' + Math.max(1, Math.floor(page)) + '&page_size=20';
    return ReviewPage.fromJson(await this.requestData(path, http.RequestMethod.POST, account, body), page, 20);
  }

  private reviewRepliesPath(appId: number, reviewId: number): string {
    return '/api/v1/apps/' + appId + '/reviews/' + reviewId + '/replies';
  }

  async listReviewReplies(appId: number, reviewId: number, page: number,
    account?: DeveloperAccount): Promise<ReviewReplyPage> {
    const path = this.reviewRepliesPath(appId, reviewId) + '?order=asc&page=' + Math.max(1, Math.floor(page));
    if (account) {
      try {
        return ReviewReplyPage.fromJson(await this.requestData(path, http.RequestMethod.GET, account));
      } catch (error) {
        if (!(error instanceof ServiceFailure) || error.status !== 401) throw error as Error;
      }
    }
    return ReviewReplyPage.fromJson(await this.getData(path));
  }

  async postReviewReply(appId: number, reviewId: number, body: string,
    account: DeveloperAccount, replyToId: number = 0, showLastPage: boolean = false): Promise<ReviewReplyPage> {
    const payload = new ReviewReplyBody(); payload.body = body;
    payload.device_model = this.commentDeviceModel();
    if (replyToId > 0) payload.reply_to_id = replyToId;
    const path = this.reviewRepliesPath(appId, reviewId) + '?order=asc' + (showLastPage ? '&page=last' : '&page_size=3');
    return ReviewReplyPage.fromJson(await this.requestData(path, http.RequestMethod.POST, account, payload));
  }

  private commentDeviceModel(): string | undefined {
    return reviewDeviceModel(deviceInfo.marketName) || reviewDeviceModel(deviceInfo.productModel) || undefined;
  }

  async deleteReviewReply(appId: number, reviewId: number, replyId: number, page: number,
    account: DeveloperAccount): Promise<ReviewReplyPage> {
    const path = this.reviewRepliesPath(appId, reviewId) + '/' + replyId +
      '?order=asc&page=' + Math.max(1, Math.floor(page));
    return ReviewReplyPage.fromJson(await this.requestData(path, http.RequestMethod.DELETE, account));
  }

  /** 按账号及证书保留成功备份的回执，不把其他设备的版本作为轮换条件。 */
  async rememberSigningIdentity(account: DeveloperAccount, identity: BackedUpIdentity): Promise<void> {
    if (!Number.isSafeInteger(identity.revision) || identity.revision < 1) {
      throw new Error(I18n.t('备份服务尚未支持版本校验，请更新服务端'));
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
    account: DeveloperAccount): Promise<boolean> {
    if (!await CloudBackupConsent.allowed(this.context, account)) return false;
    const body = new IdentityBody();
    body.cert_id = certId;
    body.private_key_pem = privateKeyPem;
    const result = await this.requestData('/api/v1/signing-identity',
      http.RequestMethod.POST, account, body);
    if (!await CloudBackupConsent.allowed(this.context, account)) return false;
    if (result['synced'] !== true || String(result['cert_id'] ?? '') !== certId) {
      throw new Error(I18n.t('签名身份备份未确认，已保留本机材料，请核对云端身份'));
    }
    const saved = new BackedUpIdentity();
    saved.certId = certId;
    saved.revision = Number(result['revision'] ?? 0);
    await this.rememberSigningIdentity(account, saved);
    return true;
  }

  async signingIdentity(account: DeveloperAccount, certId: string = ''): Promise<BackedUpIdentity | undefined> {
    if (!await CloudBackupConsent.allowed(this.context, account)) return undefined;
    const data = await this.getData('/api/v1/signing-identity' +
      (certId.length > 0 ? '?cert_id=' + encodeURIComponent(certId) : ''), account);
    if (!await CloudBackupConsent.allowed(this.context, account)) return undefined;
    const row = data['identity'] as Record<string, Object> | null | undefined;
    if (!row) return undefined;
    const identity = new BackedUpIdentity();
    identity.certId = String(row['cert_id'] ?? '');
    identity.revision = Number(row['revision'] ?? 0);
    identity.privateKeyPem = String(row['private_key_pem'] ?? '');
    if (!/^\d{1,64}$/.test(identity.certId) ||
      !/^-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----\s*$/.test(identity.privateKeyPem) ||
      identity.privateKeyPem.length > 8192) {
      throw new Error(I18n.t('云端签名身份格式无效'));
    }
    if (certId.length > 0 && identity.certId !== certId) {
      throw new Error(I18n.t('备份服务返回了其他证书，已保留本机身份，请更新服务端'));
    }
    return identity;
  }
}
