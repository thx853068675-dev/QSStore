import { LocalInstallTimeline, LocalTimelineView, LocalTimelineStep } from '../jobs/LocalInstallTimeline';
import { InstallTaskState, InstallTaskSnapshot } from '../jobs/InstallTaskState';
import { router, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { InstallJob, InstallStage, StageMark } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { LegacyInstalledMigration } from '../jobs/LegacyInstalledMigration';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { JobRunner } from '../jobs/JobRunner';
import { JobScheduler } from '../jobs/JobScheduler';
import { isPending } from '../jobs/RecoveryPlanner';
import { NativeJobRuntime } from '../jobs/NativeJobRuntime';
import { retryDelayMs } from '../jobs/RecoveryPlanner';
import { LocalImport } from '../jobs/LocalImport';
import { LocalBundles } from '../jobs/LocalBundles';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { iconReference, readIconBytes } from '../jobs/PackageInspector';
import { CatalogApp } from '../data/CatalogApp';
import { CatalogCache, CachedIcon } from '../data/CatalogCache';
import { ReleaseInfo, HapAsset } from '../data/ReleaseInfo';
import { StoreClient } from '../data/StoreClient';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { DevEcoLogin, isTransientAuthError } from '../data/DevEcoLogin';
import { LocalSigningIdentity, SigningIdentityRecovery, EnrollmentOptions, EnrollmentOutcome } from '../data/SigningIdentity';
import { AgcClient } from '../data/AgcClient';
import { SubmitDraft, SubmitChoice } from '../data/StoreActions';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';


class AppIcon {
  id: number = 0;
  rev: string = '';
  pixels?: image.PixelMap;
}

/**
 * 本地导入的 HAP 没有商店编号，图标只能从包内读。按任务 ID 缓存，
 * 避免每次重绘都重新解压一遍。
 */
class LocalIcon {
  jobId: string = '';
  pixels?: image.PixelMap;
}

class CertRow {
  id: string = '';
  name: string = '';
  expiry: string = '';
  inUse: boolean = false;
}

/** 已安装应用可用的新版本（管理页据此决定显示「更新」还是「打开」）。 */
/** installedVersion 的缓存条目：避免来回切页时反复起 hdc 进程。 */
class VersionCacheEntry {
  version: number = 0;
  at: number = 0;
}

class UpdateTarget {
  bundleName: string = '';
  appId: number = 0;
  assetName: string = '';
  assetUrl: string = '';
  assetSha256: string = '';
  mirrorUrls: string[] = [];
  versionCode: number = 0;
  versionName: string = '';
}

/**
 * 页面内容的横向边距。
 *
 * 发现页的标题、搜索框与列表，以及 `heading()` 都用它，改一处即可全页对齐。
 * （列表条目把这个值当内边距，卡片才不会贴到屏幕边缘。）
 */
const PAGE_INSET: number = 24;

/** Each featured card owns its canvas. Sharing one context between ListItems
 * makes later cards lose their stars when ArkUI recycles the list. */
@Component
struct FeaturedCardStars {
  @Prop appId: number = 0;
  @Prop tier: number = 1;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private hash(seed: number, salt: number): number {
    let h = (Math.floor(seed) * 2654435761 + salt * 40503) >>> 0;
    h = (h ^ (h >>> 15)) >>> 0;
    h = Math.imul(h, 2246822519) >>> 0;
    h = (h ^ (h >>> 13)) >>> 0;
    h = Math.imul(h, 3266489917) >>> 0;
    return (h ^ (h >>> 16)) >>> 0;
  }

  private paint(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    this.ctx.clearRect(0, 0, w, h);
    const count = this.tier === 3 ? 72 : this.tier === 2 ? 54 : 38;
    const gold = this.tier >= 2;
    for (let i = 0; i < count; i++) {
      const x = (this.hash(this.appId, i * 4 + 1) % 10000) / 10000 * w;
      const y = (this.hash(this.appId, i * 4 + 2) % 10000) / 10000 * h;
      const radius = 0.5 + (this.hash(this.appId, i * 4 + 3) % 100) / 100 *
        (this.tier === 3 ? 2.7 : 2.0);
      const alpha = 0.15 + (this.hash(this.appId, i * 4 + 4) % 100) / 100 * 0.48;
      this.ctx.beginPath();
      this.ctx.arc(x, y, radius, 0, Math.PI * 2);
      this.ctx.fillStyle = gold ? 'rgba(255,226,166,' + alpha.toFixed(2) + ')' :
        'rgba(255,255,255,' + alpha.toFixed(2) + ')';
      this.ctx.fill();
    }
    if (this.tier >= 2) {
      this.ctx.beginPath();
      this.ctx.arc(w * 0.87, h * 0.52, h * 0.58, 0, Math.PI * 2);
      this.ctx.strokeStyle = this.tier === 3 ? 'rgba(255,221,148,0.36)' :
        'rgba(234,216,255,0.22)';
      this.ctx.lineWidth = this.tier === 3 ? 1.5 : 1;
      this.ctx.stroke();
    }
  }

  build() {
    Canvas(this.ctx).width('100%').height(92)
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => this.paint())
  }
}

@Entry
@Component
struct Index {
  // 每个颜色使用点通过 colors() 读取此状态，主题变化会更新对应组件。
  @StorageProp('darkMode') darkMode: boolean = false;
  @State private currentTab: number = 0;
  @State private pendingJobs: InstallJob[] = [];
  @State private installedJobs: InstallJob[] = [];
  /** 商店目录里、本机已安装但非轻启安装的应用（无 job 记录）。 */
  @State private storeInstalled: InstallJob[] = [];
  // 探测已装版本的缓存与并发控制。installedVersion 每次都要起 hdc 进程，
  // 串行遍历目录在大目录下会非常慢，所以这里做 TTL 缓存 + 有界并发。
  private static readonly VERSION_TTL_MS: number = 60000;
  private static readonly SCAN_CONCURRENCY: number = 3;
  private versionCache: Map<string, VersionCacheEntry> = new Map();
  /** 每次扫描自增；回写前比对，丢弃被更新扫描取代的旧结果。 */
  private scanToken: number = 0;
  @State private expandedInstallBundles: string[] = [];
  @State private jobsError: string = '';
  @State private activeJobId: string = '';
  /** 进行中任务的阶段刷新定时器（-1 表示未在跑）。 */
  private stageTicker: number = -1;
  /** 本地时间轴的最新视图，包含成功、等待与失败终态。 */
  @State private localTimelineView: LocalTimelineView = new LocalTimelineView();
  /** 发现页搜索：输入框内容与当前生效的关键词（输入即搜，带防抖）。 */
  @State private searchText: string = '';
  /** 防抖定时器（-1 表示空闲）。 */
  private searchTimer: number = -1;
  /** 目录请求序号：用来丢弃过期响应。 */
  private catalogToken: number = 0;
  /** 已提交给服务端的关键词（与输入框可能不同：改词后按搜索才生效）。 */
  @State private activeQuery: string = '';
  /** 目录里每个应用在本机的版本（来自系统 bundleManager），0/缺失表示没装。 */
  @State private installedVersions: Map<number, number> = new Map<number, number>();
  @State private needsInstallScan: boolean = false;
  private initialScanDismissed: boolean = false;
  private catalogProbePending: string[] = [];
  /** 入队写库中的应用；只锁住被重复点击的那张卡。 */
  @State private enqueuingAppIds: number[] = [];
  private queueDraining: boolean = false;
  private queueRecoveryReady: boolean = false;
  @State private installTasks: InstallTaskSnapshot[] = [];
  private installSubscription: number = -1;
  /** 与设备核对卸载状态。 */
  @State private syncBusy: boolean = false;
  @State private syncMessage: string = '';
  @State private localBusy: boolean = false;
  @State private localMessage: string = '';
  /** 「我上架的应用」列表是否正在刷新。 */
  @State private myAppsBusy: boolean = false;
  /** 「设备连接」卡片里的一次性提示（如「已释放调试链路」）。 */
  @State private deviceMessage: string = '';
  /** 本地页时间轴要展示的任务 id。 */
  @State private localJobId: string = '';
  @State private localInfoJob: InstallJob = new InstallJob();
  @State private localFileSize: string = '';
  @State private cancellingJobs: string[] = [];
  @State private apps: CatalogApp[] = [];
  @State private appIcons: AppIcon[] = [];
  /** 本轮首屏加载到的图标字节，攒起来一次性写缓存。 */
  private pendingIconCache: CachedIcon[] = [];
  /** 本地 HAP 的包内图标，按任务 ID 缓存。 */
  @State private localIcons: LocalIcon[] = [];
  @State private catalogError: string = '';
  @State private catalogLoading: boolean = true;
  /** 服务端目录分页：catalogPage 是已加载到的页码，catalogTotal 是服务端总数。 */
  @State private catalogPage: number = 0;
  @State private catalogTotal: number = 0;
  @State private catalogMoreBusy: boolean = false;
  /** 发现页下拉刷新的转圈状态。 */
  @State private catalogRefreshing: boolean = false;
  /** 请求锁独立于 Refresh 双向绑定的动画状态。 */
  private catalogRefreshBusy: boolean = false;
  @State private account: DeveloperAccount = new DeveloperAccount();
  @State private signedIn: boolean = false;
  /** 是否已完成启动时的登录态检查（false 时显示检查中，避免闪一下登录页）。 */
  @State private accountChecked: boolean = false;
  @State private loginBusy: boolean = false;
  @State private loginMessage: string = '';
  /** 登录态校验降级时的提示（网络/服务端故障，不是登录失效）。 */
  @State private sessionNotice: string = '';
  @State private identityBusy: boolean = false;
  @State private identityMessage: string = '';
  /**
   * 云端备份未成功的提示。
   *
   * 非空表示本机私钥还没有云端副本 —— 此时重置会丢失唯一一份私钥，
   * 界面必须把这件事说出来，而不是等用户点了重置才发现。
   */
  @State private backupWarning: string = '';
  @State private showSubmit: boolean = false;
  @State private submitUrl: string = '';
  @State private submitDraft: SubmitDraft = new SubmitDraft();
  @State private submitAsset: string = '';
  @State private submitCategory: string = '';
  /** 分类滑动选择器的选中下标，与 submitCategory 同步。 */
  @State private submitCategoryIndex: number = 0;
  @State private submitBusy: boolean = false;
  @State private submitMessage: string = '';
  /** 当前草稿仓库在本店的状态：见 SUBMIT_STATE_*。 */
  @State private submitExisting: number = 0;
  /** 已在架时那条记录的编号与名称，供提示使用。 */
  @State private submitExistingId: number = 0;
  @State private submitExistingName: string = '';
  @State private myApps: CatalogApp[] = [];
  @State private myAppsMessage: string = '';
  @State private removingId: number = 0;
  @State private showAppConfig: boolean = false;
  @State private configApp: CatalogApp = new CatalogApp();
  @State private configCategories: string[] = [];
  @State private configCategory: string = '';
  @State private configBusy: boolean = false;
  @State private configMessage: string = '';
  @State private showReconnect: boolean = false;
  @State private reconnectPort: string = '';
  @State private reconnectBusy: boolean = false;
  @State private reconnectMessage: string = '';
  @State private resumeJobId: string = '';
  @State private updates: UpdateTarget[] = [];
  /** 更新目录独立于发现页的搜索和分页，整轮获取成功才替换。 */
  @State private updateCatalog: CatalogApp[] = [];
  @State private updateCatalogReady: boolean = false;
  @State private updateCatalogBusy: boolean = false;
  @State private updateCatalogError: string = '';
  @State private deviceConnected: boolean = false;
  @State private deviceBusy: boolean = false;
  @State private certReady: boolean = false;
  @State private certLabel: string = '';
  @State private certId: string = '';
  @State private certExpiry: string = '';
  @State private certMessage: string = '';
  @State private showCertSheet: boolean = false;
  @State private certRows: CertRow[] = [];
  @State private certSheetBusy: boolean = false;
  @State private certSheetMessage: string = '';
  @State private certDeleting: string = '';
  @State private certUsing: string = '';
  /** 证书即将到期（30 天内）时提示提前重建，别等签名失败。 */
  @State private certExpiringSoon: boolean = false;
  /** 只剩最后一个槽位时的二次确认：为 true 才会真的申请。 */
  @State private certLastSlotConfirmed: boolean = false;
  /** 左滑后等待确认删除的证书 ID。 */
  @State private certConfirmDelete: string = '';

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void {
    this.observeInstallTasks();
    InstalledAppRegistry.load(getContext(this) as common.UIAbilityContext)
      .then(() => this.refreshCatalogInstallState());
    this.loadJobs();
    this.loadUpdateCatalog();
    this.migrateLegacyJobs();
    // 先等缓存画出来，再发起刷新：刷新会重置 appIcons，顺序反了会把刚恢复的图标清掉
    this.loadCatalogFromCache().then(() => this.loadApps());
    this.recoverDownloads().finally(() => {
      this.queueRecoveryReady = true;
      this.drainInstallQueue();
    });
    this.restoreAccount();
  }

  /**
   * 每次页面回到前台都兜底一次。
   *
   * 安装中途离开再回来时，上次的「正在忙」状态可能还留在界面上，任务也可能停在
   * 半路。这里做两件事：把不再真的在跑的任务从「进行中」摘掉，把长时间没动静的
   * 任务标成可重试，让用户看到「继续安装」而不是一个永远转圈的进度。
   */
  onPageShow(): void {
    this.observeInstallTasks();
    this.refreshCatalogInstallState();
    this.reconcileInterruptedInstalls().then(() => this.reconcileStuckJobs());
    // Detail always fetches its icon afresh. Refresh the catalog when returning
    // so an icon revision changed on the server is reflected on discovery too.
    if (this.catalogPage > 0 && !this.catalogLoading && this.currentTab === Index.TAB_DISCOVER) {
      this.loadApps();
    }
  }

  aboutToDisappear(): void {
    InstallTaskState.unsubscribe(this.installSubscription);
    this.installSubscription = -1;
    // 页面离开就停掉阶段轮询与搜索防抖，别让定时器在后台空转
    this.stopStageTicker();
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  private async migrateLegacyJobs(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      if (await LegacyInstalledMigration.run(context, store) > 0) await this.loadJobs();
    } catch (error) {
      this.jobsError = '旧版安装记录暂无法导入：' + errorText(error);
    }
  }

  private async restoreAccount(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const saved = await AccountSession.load(context);
      if (!saved) {
        this.loginMessage = '';
        return;
      }
      try {
        const refreshed = await DevEcoLogin.refresh(saved);
        await AccountSession.save(context, refreshed);
        this.account = refreshed;
        this.sessionNotice = '';
      } catch (error) {
        // 断网 / 账号服务 5xx 时不要把用户踢回登录页：本地账号还在，
        // 沿用已保存的登录态，等下次启动或操作时再校验。
        if (!isTransientAuthError(error)) throw new Error(String(error));
        this.account = saved;
        this.sessionNotice = '账号服务暂时不可用，正在使用本地登录态';
      }
      this.signedIn = true;
      this.loginMessage = '';
      this.drainInstallQueue();
      this.recoverSigningIdentity();
      this.loadMyApps();
    } catch (_) {
      this.signedIn = false;
      this.loginMessage = '登录状态已过期，请重新登录';
    } finally {
      this.accountChecked = true;
      this.updateInstallScanPrompt();
    }
  }

  private async login(): Promise<void> {
    this.loginBusy = true;
    this.loginMessage = '请在浏览器中完成华为开发者账号登录';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await DevEcoLogin.login(context);
      await AccountSession.save(context, account);
      this.account = account;
      this.signedIn = true;
      this.loginMessage = '登录成功';
      this.updateInstallScanPrompt();
      this.drainInstallQueue();
      this.recoverSigningIdentity();
      this.loadMyApps();
    } catch (error) {
      this.loginMessage = errorText(error);
    } finally {
      this.loginBusy = false;
    }
  }

  private async signOut(): Promise<void> {
    await AccountSession.clear(getContext(this) as common.UIAbilityContext);
    this.account = new DeveloperAccount();
    this.signedIn = false;
    this.loginMessage = '';
    this.identityMessage = '';
    this.myApps = [];
  }

  /** 退出的二次确认：图标按钮容易误触，而退出会清掉登录态。 */
  private confirmSignOut(): void {
    AlertDialog.show({
      title: '退出账号',
      message: '退出后需要重新登录才能上架和评价。已安装的应用与安装记录不受影响。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '退出', action: () => { this.signOut(); } }
    });
  }

  private async recoverSigningIdentity(): Promise<void> {
    if (!this.signedIn || this.identityBusy) return;
    const account = this.account;
    this.identityBusy = true;
    this.identityMessage = '正在核对账号现有调试证书…';
    try {
      const identity = await SigningIdentityRecovery.restore(
        getContext(this) as common.UIAbilityContext, account);
      if (this.signedIn && this.account.userId === account.userId) {
        this.certReady = identity !== undefined;
        this.certLastSlotConfirmed = false;
        // 复用成功是正常状态，不需要一行说明文字；这个字段继续用于报错与
        // 需要用户动作的提示（未配对、重置失败等）。
        this.identityMessage = identity ? '' :
          '账号下还没有与本机配对的调试证书，可点「获取调试证书」申请一张';
        if (identity !== undefined) {
          await this.loadCertificateDetail(identity);
          await this.syncIdentityToCloud(getContext(this) as common.UIAbilityContext, identity);
        }
      }
    } catch (error) {
      if (this.signedIn && this.account.userId === account.userId) {
        this.identityMessage = errorText(error);
      }
    } finally {
      this.identityBusy = false;
    }
  }

  /** 取当前调试证书的名称与到期时间（拿不到不影响签名可用性）。 */
  private async loadCertificateDetail(identity: LocalSigningIdentity): Promise<void> {
    this.certId = identity.certId;
    this.certLabel = identity.certName;
    this.certExpiringSoon = false;
    if (identity.certExpiry > 0) {
      this.certExpiry = Index.formatDay(identity.certExpiry);
      this.certExpiringSoon = identity.certExpiry - Math.floor(Date.now() / 1000) <
        Index.CERT_EXPIRY_WARNING_DAYS * 86400;
    } else {
      this.certExpiry = '';
    }
    try {
      const rows = await new AgcClient(this.account).certificates();
      const row = rows.find((item: Record<string, Object>) =>
        String(item['id'] ?? '') === identity.certId);
      if (row === undefined) return;
      const name = String(row['certName'] ?? '');
      if (name.length > 0) this.certLabel = name;
      const seconds = Index.expirySeconds(row['expireTime']);
      if (seconds > 0) {
        this.certExpiry = Index.formatDay(seconds);
        this.certExpiringSoon = seconds - Math.floor(Date.now() / 1000) <
          Index.CERT_EXPIRY_WARNING_DAYS * 86400;
      }
    } catch (_) {
      // 离线时只显示本机记录的名称与到期时间
    }
  }

  private static readonly CERT_EXPIRY_WARNING_DAYS: number = 30;

  private static expirySeconds(raw: Object | undefined): number {
    const value = Number(raw ?? 0);
    if (!Number.isFinite(value) || value <= 0) return 0;
    return value > 100000000000 ? Math.floor(value / 1000) : Math.floor(value);
  }

  private static formatDay(epochSeconds: number): string {
    const date = new Date(epochSeconds * 1000);
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
  }

  /**
   * 首次签名 / 证书重建：复用优先，确无可用证书才向 AGC 申请。
   *
   * 只剩最后一个槽位时第一次点击只给出确认提示，再点一次才真的申请，
   * 避免误触占掉团队的最后一个调试证书槽位。
   */
  private async prepareSigningIdentity(): Promise<void> {
    if (!this.signedIn || this.identityBusy || this.certDeleting.length > 0) return;
    const account = this.account;
    this.identityBusy = true;
    this.certMessage = '';
    this.identityMessage = '正在核对账号现有调试证书…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const options = new EnrollmentOptions();
      options.allowLastSlot = this.certLastSlotConfirmed;
      options.renewBeforeSeconds = this.certExpiringSoon ?
        Math.floor(Date.now() / 1000) + Index.CERT_EXPIRY_WARNING_DAYS * 86400 : 0;
      const result = await SigningIdentityRecovery.enroll(context, account, options);
      if (!this.signedIn || this.account.userId !== account.userId) return;
      this.certReady = true;
      this.certLastSlotConfirmed = false;
      await this.loadCertificateDetail(result.identity);
      await this.syncIdentityToCloud(context, result.identity);
      const label = this.certLabel.length > 0 ? this.certLabel : result.identity.certId;
      this.identityMessage = result.outcome === EnrollmentOutcome.CREATED ?
        '已申请并配对新的调试证书「' + label + '」，签名材料已保存在本机' :
        '已复用账号现有调试证书「' + label + '」，未占用新槽位';
    } catch (error) {
      if (!this.signedIn || this.account.userId !== account.userId) return;
      const message = errorText(error);
      // 「只剩最后一个槽位」是可确认的状态，不是失败；把按钮切换成确认态。
      this.certLastSlotConfirmed = message.includes('最后一个调试证书槽位');
      this.identityMessage = message;
    } finally {
      this.identityBusy = false;
    }
  }

  /**
   * 把新身份备份到商店服务，换设备时可直接取回。
   *
   * 备份失败**必须让用户看见**：本机私钥是唯一一份，云端备份是它仅有的副本。
   * 以前这里静默吞掉异常，用户以为已经备份好，随后「重置」就把私钥删了 ——
   * 永久丢失，重新申请还要占一个新槽位。
   *
   * 现在失败时留下明确提示；`reset` 也会在真正删除前再验证一次备份可用。
   */
  private async syncIdentityToCloud(context: common.UIAbilityContext,
    identity: LocalSigningIdentity): Promise<boolean> {
    try {
      const pem = fileIo.readTextSync(identity.privateKeyPath);
      await new StoreClient(context).publishSigningIdentity(identity.certId, pem, this.account);
      if (this.backupWarning.length > 0) this.backupWarning = '';
      return true;
    } catch (error) {
      this.backupWarning = '签名身份尚未备份到云端（' + errorText(error) +
        '）。已保留本机材料，下次核对身份时会重试备份。';
      return false;
    }
  }

  /** 读取账号下所有调试证书，供应用内弹窗展示。 */
  private async loadCertRows(): Promise<void> {
    this.certSheetBusy = true;
    this.certSheetMessage = '';
    try {
      const rows = await new AgcClient(this.account).certificates();
      const list: CertRow[] = [];
      for (const row of rows) {
        if (Number(row['certType'] ?? 0) !== 1) continue;
        const item = new CertRow();
        item.id = String(row['id'] ?? '');
        const name = String(row['certName'] ?? '');
        item.name = name.length > 0 ? name : '调试证书';
        const expire = Number(row['expireTime'] ?? 0);
        if (Number.isFinite(expire) && expire > 0) {
          const seconds = expire > 100000000000 ? Math.floor(expire / 1000) : expire;
          const date = new Date(seconds * 1000);
          const pad = (n: number): string => n < 10 ? '0' + n : String(n);
          item.expiry = date.getFullYear() + '-' + pad(date.getMonth() + 1) +
            '-' + pad(date.getDate());
        }
        item.inUse = item.id.length > 0 && item.id === this.certId;
        list.push(item);
      }
      this.certRows = list;
      if (list.length === 0) this.certSheetMessage = '账号下没有调试证书';
    } catch (error) {
      this.certSheetMessage = '读取失败：' + errorText(error);
    } finally {
      this.certSheetBusy = false;
    }
  }

  /**
   * 使用某张证书：默认先尝试与本机私钥配对，配不上就报错，不静默切换。
   */
  private async useCertificate(row: CertRow): Promise<void> {
    if (this.certUsing.length > 0) return;
    this.certUsing = row.id;
    this.certSheetMessage = '';
    try {
      const identity = await SigningIdentityRecovery.activate(
        getContext(this) as common.UIAbilityContext, this.account, row.id);
      this.certId = identity.certId;
      this.certReady = true;
      const backedUp = await this.syncIdentityToCloud(
        getContext(this) as common.UIAbilityContext, identity);
      this.certSheetMessage = '已切换到「' + row.name + '」' +
        (backedUp ? '，备份已同步' : '，云端备份待重试');
      await this.loadCertRows();
      await this.loadCertificateDetail(identity);
    } catch (error) {
      this.certSheetMessage = errorText(error);
    } finally {
      this.certUsing = '';
    }
  }

  /** 删除最后一张时保留私钥，删除成功后清除本机对旧证书的引用。 */
  private async deleteCertificate(row: CertRow): Promise<void> {
    if (this.certDeleting.length > 0) return;
    this.certDeleting = row.id;
    this.certSheetMessage = '正在备份私钥并核对替代证书…';
    const context = getContext(this) as common.UIAbilityContext;
    let started = false;
    let deleted = false;
    let message = '';
    try {
      const current = await SigningIdentityRecovery.prepareCertificateDeletion(
        context, this.account, row.id);
      await SigningIdentityRecovery.beginCertificateDeletion(context, this.account, row.id);
      started = true;
      await new AgcClient(this.account).deleteCertificates([row.id]);
      deleted = true;
      await SigningIdentityRecovery.finishCertificateDeletion(context, this.account, row.id);
      if (current !== undefined) this.backupWarning = '';
      message = '已删除「' + row.name + '」' +
        (current !== undefined && current.certId === row.id ?
          '，本机私钥已保留；下次准备签名身份可重新获取证书' : '');
    } catch (error) {
      if (started && !deleted) {
        try {
          await SigningIdentityRecovery.cancelCertificateDeletion(context, this.account, row.id);
        } catch (_) {}
      }
      message = deleted ? 'AGC 已删除证书，但本机状态清理失败：' + errorText(error) :
        '删除失败：' + errorText(error);
    } finally {
      try {
        const active = await SigningIdentityRecovery.load(context, this.account);
        this.certReady = active !== undefined;
        this.certId = active?.certId ?? '';
        if (active !== undefined) await this.loadCertificateDetail(active);
        else {
          this.certLabel = '';
          this.certExpiry = '';
          this.certExpiringSoon = false;
        }
      } catch (_) {
        this.certReady = false;
        this.certId = '';
      }
      await this.loadCertRows();
      if (deleted) this.certRows = this.certRows.filter((item: CertRow) => item.id !== row.id);
      this.certSheetMessage = message;
      this.certDeleting = '';
    }
  }

  /** 没有可用证书时直接获取；已有身份时从云端重新核对并取回。 */
  private async resetCertificate(): Promise<void> {
    if (this.identityBusy || this.certDeleting.length > 0) return;
    if (!this.certReady) {
      await this.prepareSigningIdentity();
      return;
    }
    this.identityBusy = true;
    this.identityMessage = '正在确认云端备份可用…';
    try {
      // 先确认云端确实存着这把私钥才允许删除本机材料；
      // 备份不可用时 reset 会抛错并保留本机身份（不再先删后试恢复）。
      await SigningIdentityRecovery.reset(
        getContext(this) as common.UIAbilityContext, this.account);
    } catch (error) {
      this.identityMessage = errorText(error);
      this.identityBusy = false;
      return;
    }
    // 本机材料已经删掉，界面状态必须跟着清空，否则会显示一个已不存在的身份。
    this.certReady = false;
    this.certId = '';
    this.certLabel = '';
    this.certExpiry = '';
    this.identityMessage = '正在重置本机签名身份…';
    try {
      this.identityBusy = false;
      await this.recoverSigningIdentity();
      this.identityMessage = this.certReady ?
        '已重置并重新取回：' + (this.certLabel.length > 0 ? this.certLabel : this.certId) :
        this.identityMessage;
    } catch (error) {
      this.identityMessage = '重置失败：' + errorText(error);
    } finally {
      this.identityBusy = false;
    }
  }

  @Builder
  private certDeleteAction(row: CertRow) {
    Column() {
      Text(this.certDeleting === row.id ? '删除中…' : '删除')
        .fontSize(13).fontColor(this.colors().onAccent).fontWeight(FontWeight.Medium)
        .maxLines(1)
    }
    .width(64).height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor(this.certDeleting === row.id ? this.colors().textTertiary : this.colors().danger)
    .borderRadius(14)
    .onClick(() => {
      // 左滑删除是破坏性且不可撤销的动作，先要一次明确确认。
      this.certConfirmDelete = row.id;
      this.certSheetMessage = '';
    })
  }

  @Builder
  private certSheet() {
    Column({ space: 14 }) {
      Row() {
        Text('AGC 调试证书').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        Text('×').fontSize(24).fontColor(this.colors().textSecondary)
          .onClick(() => { this.showCertSheet = false; })
      }.width('100%')
      Text('安装时用与本机私钥配对的那张证书重签。')
        .fontSize(11).fontColor(this.colors().textTertiary)
        .lineHeight(17).width('100%')
      if (this.certSheetBusy) {
        Row({ space: 10 }) {
          LoadingProgress().width(18).height(18)
          Text('正在读取…').fontSize(12).fontColor(this.colors().textSecondary)
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
      } else {
        List({ space: 9 }) {
          ForEach(this.certRows, (row: CertRow) => {
            ListItem() {
              Row({ space: 11 }) {
                Column({ space: 4 }) {
                  Text(row.name).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().text).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('ID ' + row.id).fontSize(11).fontColor(this.colors().textTertiary)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (row.expiry.length > 0) {
                    Text('到期 ' + row.expiry).fontSize(11)
                      .fontColor(this.colors().textTertiary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (row.inUse) {
                  Text('已使用')
                    .fontSize(11).fontColor(this.colors().success)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .backgroundColor(this.colors().successSoft).borderRadius(8)
                } else {
                  Button(this.certUsing === row.id ? '配对中…' : '使用')
                    .height(30).fontSize(11)
                    .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
                    .borderRadius(8).enabled(this.certUsing.length === 0)
                    .onClick(() => this.useCertificate(row))
                }
              }.width('100%').padding(13)
                .backgroundColor(this.colors().surface).borderRadius(14)
            }
            // 卡片左滑露出删除。
            // 必须用 SwipeActionItem 对象形式：直接塞 CustomBuilder 会让
            // 按钮参与布局，把卡片挤窄、文字被截成碎片（竖排假象）。
            // actionAreaDistance 让按钮画在覆盖层里，卡片宽度不变。
            .swipeAction({
              end: {
                builder: () => { this.certDeleteAction(row) },
                actionAreaDistance: 64
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          }, (row: CertRow) => row.id + ':' + this.certDeleting)
        }
        .width('100%').constraintSize({ maxHeight: 320 })
        .scrollBar(BarState.Off)
      }
      if (this.certConfirmDelete.length > 0) {
        Column({ space: 10 }) {
          Text('删除后该证书不能再签名。若是最后一张，本机私钥会保留，下次可重新获取证书。')
            .fontSize(11).fontColor(this.colors().textSecondary).width('100%')
          Row({ space: 10 }) {
            Button('确认删除')
              .height(36).fontSize(12).layoutWeight(1)
              .backgroundColor(this.colors().danger).fontColor(this.colors().onAccent)
              .borderRadius(11).enabled(this.certDeleting.length === 0)
              .onClick(() => {
                const target = this.certRows.find((item: CertRow) =>
                  item.id === this.certConfirmDelete);
                this.certConfirmDelete = '';
                if (target !== undefined) this.deleteCertificate(target);
              })
            Button('取消')
              .height(36).fontSize(12).layoutWeight(1)
              .backgroundColor(this.colors().fill).fontColor(this.colors().textSecondary)
              .borderRadius(11)
              .onClick(() => { this.certConfirmDelete = ''; })
          }.width('100%')
        }.width('100%').padding(13)
          .backgroundColor(this.colors().surface).borderRadius(12)
          .border({ width: 1, color: this.colors().danger })
      }
      if (this.certSheetMessage.length > 0) {
        Text(this.certSheetMessage).fontSize(12).fontColor(this.colors().textSecondary)
          .maxLines(3).width('100%')
      }
      Row({ space: 10 }) {
        Button(this.certSheetBusy ? '读取中…' : '刷新列表')
          .height(40).fontSize(13).layoutWeight(1)
          .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
          .borderRadius(12).enabled(!this.certSheetBusy)
          .onClick(() => this.loadCertRows())
        Button('关闭')
          .height(40).fontSize(13).layoutWeight(1)
          .backgroundColor(this.colors().fill).fontColor(this.colors().textSecondary)
          .borderRadius(12)
          .onClick(() => { this.showCertSheet = false; })
      }.width('100%')
    }.padding(21).width('90%').backgroundColor(this.colors().bg).borderRadius(23)
  }

  /** 在浏览器里打开 AppGallery Connect 的证书管理页（备用入口）。 */
  private async openAgcConsole(): Promise<void> {
    this.certMessage = '';
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: 'https://developer.huawei.com/consumer/cn/service/josp/agc/index.html' +
          '#/myProject/certManage'
      });
    } catch (error) {
      this.certMessage = '无法打开浏览器：' + errorText(error);
    }
  }

  /** 目录每页条数；服务端 /apps 的 page_size 上限为 100。 */
  private static readonly CATALOG_PAGE_SIZE: number = 30;

  private catalogHasMore(): boolean {
    return this.apps.length < this.catalogTotal && !this.catalogMoreBusy;
  }

  private async loadApps(reset: boolean = true): Promise<void> {
    if (reset) {
      this.catalogLoading = true;
    } else if (!this.catalogHasMore()) {
      return;
    }
    this.catalogMoreBusy = true;
    // 输入即搜时请求会重叠：只认最后一次发出的那一个，先到的旧响应直接丢弃，
    // 否则「搜 quiet」的慢响应会盖掉「搜 quietstart」的结果。
    const token = ++this.catalogToken;
    const query = this.activeQuery;
    const nextPage = reset ? 1 : this.catalogPage + 1;
    this.pendingIconCache = [];
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      const page = await client.listApps(nextPage, Index.CATALOG_PAGE_SIZE,
        'updated', query);
      if (token !== this.catalogToken || query !== this.activeQuery) return;
      // 先加载的页在后，追加时按 id 去重，避免上架/删除后翻页出现重复项。
      const known = this.apps.map((app: CatalogApp) => app.id);
      const fresh = page.items.filter((app: CatalogApp) => known.indexOf(app.id) < 0);
      this.apps = reset ? page.items : this.apps.concat(fresh);
      // 只保留仍在列表里、且本轮不需要重新拉取的图标：
      // 重置整表会把缓存刚恢复的图标一起清掉，看起来像图标丢了。
      if (reset) {
        const keep = new Set<number>(page.items.map((app: CatalogApp) => app.id));
        this.appIcons = this.appIcons.filter((entry: AppIcon) =>
          keep.has(entry.id) && page.items.some((app: CatalogApp) =>
            app.id === entry.id && app.iconRev.length > 0 && app.iconRev === entry.rev));
      }
      // 首屏这一轮要等图标拿到再写缓存，否则缓存里只会有目录没有图标；
      // 追加页不需要等，图标照旧异步补上。
      const cacheablePage = reset && this.activeQuery.length === 0;
      const iconLoads: Promise<void>[] = [];
      for (const app of reset ? page.items : fresh) {
        // 服务端修正图标后，修订号变化就必须重新下载。
        if (this.iconFor(app.id) !== undefined) continue;
        const load = this.loadAppIcon(client, app, token, query, cacheablePage);
        if (cacheablePage) iconLoads.push(load);
      }
      if (cacheablePage) await Promise.all(iconLoads);
      if (token !== this.catalogToken || query !== this.activeQuery) return;
      this.catalogPage = nextPage;
      this.catalogTotal = page.total;
      this.catalogError = '';
      // 目录变了就重算「装没装」，卡片按钮跟着更新
      this.refreshCatalogInstallState();
      // 只缓存干净的第一页：缓存与分页混在一起会得到半新半旧的列表
      if (cacheablePage) {
        const context = getContext(this) as common.UIAbilityContext;
        CatalogCache.save(context, page.items, page.rawItems);
        this.flushIconCache(context);
      }
    } catch (error) {
      if (token !== this.catalogToken || query !== this.activeQuery) return;
      this.catalogError = errorText(error);
    } finally {
      if (token === this.catalogToken) {
        this.catalogMoreBusy = false;
        this.catalogLoading = false;
      }
    }
  }

  /**
   * 发现页下拉刷新：重新拉第一页。
   *
   * 保留当前搜索词和旧列表，成功后提交新页码；失败时仍可浏览旧结果。
   * Refresh 在回调前已将 catalogRefreshing 设为 true，因此使用独立的请求锁。
   *
   * **转圈有个最短停留时间。** 请求快时 loadApps 几十毫秒就返回，若立刻把
   * catalogRefreshing 置回 false，Refresh 的动画还没画出来就被收回，手感是
   * 「拉一下闪一下就弹回去」。给一个下限，让这次刷新看起来确实发生过。
   */
  private static readonly REFRESH_MIN_VISIBLE_MS: number = 600;
  /** 超过这个星数用大卡。 */
  private static readonly STARRED_MIN_STARS: number = 100;

  private async pullRefreshCatalog(): Promise<void> {
    if (this.catalogRefreshBusy) return;
    this.catalogRefreshBusy = true;
    this.catalogRefreshing = true;
    const startedAt = Date.now();
    try {
      // 只读取服务端已有目录；GitHub 采集由服务端周期任务或详情页主动检查负责。
      await this.loadApps();
      await this.reconcileCatalogInstallState();
      this.loadUpdateCatalog();
    } finally {
      const elapsed = Date.now() - startedAt;
      if (elapsed < Index.REFRESH_MIN_VISIBLE_MS) {
        await new Promise<void>((resolve) =>
          setTimeout(resolve, Index.REFRESH_MIN_VISIBLE_MS - elapsed));
      }
      this.catalogRefreshBusy = false;
      this.catalogRefreshing = false;
    }
  }

  /**
   * 按设备实际情况校正目录卡片的安装状态。
   *
   * 卡片是否显示「打开」有两个来源：库里的安装记录与 `installedVersions`。
   * 记录不会因为用户在系统设置里卸载而消失，所以刷新时必须跟设备核一次，
   * 否则装过又卸掉的应用会一直显示「打开」，点了当然打不开。
   *
   * 只在设备明确回答「没有这个包」时才删记录；查询失败（设备没连、命令超时）
   * 一律按「不确定」处理并保留记录 —— 断线一次就清空历史是不可接受的。
   *
   * **一次问完，不逐个查。** 逐个 `isInstalled` 是「一个包一次设备往返」，
   * 目录里有多少应用就要多少次；应用一多，刷新会慢到十几秒。这里用
   * `bm dump -a` 读取包名清单，再对目录涉及的包读取版本。
   *
   * **设备版本要覆盖安装记录。** 记录的版本是「当时装的那个」，用户之后可能装了
   * 别的版本；只看记录会让卡片一直显示「更新」。这里把设备上的真实版本写进
   * `installedVersions`（`installedVersionOf` 取两者的较大值），装完刷新即可收敛。
   */
  private async reconcileCatalogInstallState(): Promise<void> {
    const bundles: string[] = [];
    for (const app of this.apps) {
      const bundleName = app.latestAsset?.bundleName ?? '';
      if (bundleName.length > 0 && !bundles.includes(bundleName)) bundles.push(bundleName);
    }
    if (bundles.length === 0) return;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const bridge = new HdcDeviceBridge(context);
      const onDevice = await bridge.installedBundleVersions(bundles);
      if (onDevice === undefined) return;   // 解析不出包名 → 无法核实，保持原状
      const missing = bundles.filter((bundleName: string) => !onDevice.has(bundleName));
      if (missing.length > 0) {
        // 要删的记录先取快照：下面会先把 installedJobs 过滤掉（界面立刻正确），
        // 之后就没法再从它里面挑出待删的条目了。
        const dropped = this.installedJobs.filter((job: InstallJob) =>
          job.bundleName.length > 0 && missing.includes(job.bundleName));
        // 先把界面状态改掉：删库与清缓存都属于「收尾」，它们失败也不该让卡片
        // 继续显示一个设备上并不存在的「打开」。
        this.installedJobs = this.installedJobs.filter((job: InstallJob) =>
          job.bundleName.length === 0 || !missing.includes(job.bundleName));
        try {
          this.forgetInstalledVersions();
        } catch (error) {
          console.error('StarHub forgetInstalledVersions failed: ' + errorText(error));
        }
        this.refreshCatalogInstallState();
        try {
          const store = await JobStore.open(context);
          for (const job of dropped) await store.forget(job.id);
        } catch (error) {
          console.error('StarHub dropping uninstalled records failed: ' + errorText(error));
        }
      }
      // **设备版本最后写。** 上面的 refreshCatalogInstallState 会重建
      // installedVersions；先写就会被它盖掉，卡片又会回到安装记录里的旧版本，
      // 表现为「装完了刷新还显示更新」。
      //
      // 记录里存的是「当时装的那个版本」；设备上的才是真实情况。把设备版本写进
      // installedVersions（installedVersionOf 取两者较大值），装完刷新即可收敛。
      let versionChanged = false;
      for (const app of this.apps) {
        const bundleName = app.latestAsset?.bundleName ?? '';
        const version = bundleName.length > 0 ? onDevice.get(bundleName) : undefined;
        if (version !== undefined && version > 0 && this.installedVersions.get(app.id) !== version) {
          this.installedVersions.set(app.id, version);
          versionChanged = true;
        }
      }
      if (versionChanged) {
        this.installedVersions = new Map(this.installedVersions);
        this.checkInstalledUpdates();
      }
    } catch (error) {
      // 对账失败不影响已经拉到的列表，但要留下痕迹：被吞掉的异常会让
      // 「卸载后仍显示打开」这类问题完全无从排查。
      console.error('StarHub reconcileCatalogInstallState failed: ' + errorText(error));
    }
  }

  private loadMoreApps(): void {
    if (!this.catalogHasMore()) return;
    this.loadApps(false);
  }

  /** 单次请求最多 100 个版本；更新检查需要看到全部版本，否则会漏掉真正的最新版。 */
  private static readonly RELEASE_PAGE_SIZE: number = 50;
  private static readonly RELEASE_MAX_PAGES: number = 4;

  private async allReleases(client: StoreClient, appId: number): Promise<ReleaseInfo[]> {
    const collected: ReleaseInfo[] = [];
    for (let page = 1; page <= Index.RELEASE_MAX_PAGES; page++) {
      const result = await client.listReleases(appId, page, Index.RELEASE_PAGE_SIZE);
      collected.push(...result.items);
      if (!result.hasMore || result.items.length === 0) break;
    }
    return collected;
  }

  private async loadAppIcon(client: StoreClient, app: CatalogApp, token: number,
    query: string, cacheable: boolean): Promise<void> {
    try {
      if (app.iconRev.length === 0 || app.iconUrl.length === 0) return;
      let bytes: ArrayBuffer | undefined;
      for (let attempt = 0; attempt < 2; attempt++) {
        if (token !== this.catalogToken || query !== this.activeQuery) return;
        try { bytes = await client.appIconBytes(app); }
        catch (_) { bytes = undefined; }
        if (bytes !== undefined) break;
      }
      if (bytes === undefined || token !== this.catalogToken || query !== this.activeQuery) return;
      const source = image.createImageSource(bytes);
      try {
        const pixels = await source.createPixelMap();
        if (token !== this.catalogToken || query !== this.activeQuery || this.iconFor(app.id) !== undefined) {
          await pixels.release();
          return;
        }
        const icon = new AppIcon();
        icon.id = app.id;
        icon.rev = app.iconRev;
        icon.pixels = pixels;
        this.appIcons = this.appIcons.concat([icon]);
        if (cacheable && CatalogCache.iconWithinLimit(bytes)) {
          const record = new CachedIcon();
          record.id = String(app.id);
          record.rev = app.iconRev;
          record.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
          this.pendingIconCache = this.pendingIconCache.concat([record]);
        }
      } finally {
        await source.release();
      }
    } catch (_) {
      // 单张图标下载或解码失败不影响目录，下次刷新会重试缺失图标。
    }
  }

  /**
   * 把本轮加载到的图标字节写入缓存。
   *
   * 图标是异步逐个到的，所以攒在 pendingIconCache 里，等首屏这一轮结束后
   * 一次性落盘，避免多次写 preferences。
   */
  private flushIconCache(context: common.UIAbilityContext): void {
    if (this.pendingIconCache.length === 0) return;
    const records = this.pendingIconCache;
    this.pendingIconCache = [];
    CatalogCache.saveIcons(context, records);
  }

  /**
   * 先用缓存把界面画出来。
   *
   * 缓存里的图标是上次存下的字节，直接解码成 PixelMap；解码失败的条目等
   * 后台刷新时再补。只缓存第一页，所以这里拿到的就是"上次干净的第一页"。
   */
  private async loadCatalogFromCache(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const cached = await CatalogCache.load(context);
    if (cached.length === 0) return;
    // 期间已经拿到新数据就不要用旧数据覆盖
    if (this.apps.length > 0 || this.activeQuery.length > 0) return;
    this.apps = cached;
    this.catalogTotal = Math.max(this.catalogTotal, cached.length);
    this.refreshCatalogInstallState();
    this.catalogLoading = false;
    const icons = await CatalogCache.loadIcons(context, cached);
    icons.forEach((bytes: ArrayBuffer, id: number) => {
      try {
        const source = image.createImageSource(bytes);
        source.createPixelMap().then((pixels: image.PixelMap) => {
          const expected = cached.find((app: CatalogApp) => app.id === id)?.iconRev;
          if (!expected || !this.apps.some((app: CatalogApp) =>
            app.id === id && app.iconRev === expected) || this.iconFor(id) !== undefined) {
            pixels.release();
            return;
          }
          const icon = new AppIcon();
          icon.id = id;
          icon.rev = expected;
          icon.pixels = pixels;
          this.appIcons = this.appIcons.concat([icon]);
        }).catch((e: Object) => {
        });
      } catch (e) {
      }
    });
  }

  private iconFor(id: number): image.PixelMap | undefined {
    return this.appIcons.find((entry: AppIcon) => entry.id === id)?.pixels;
  }

  /** 已安装条目的图标：商店应用用目录图标，本地 HAP 用包内图标。 */
  private jobIcon(job: InstallJob): image.PixelMap | undefined {
    if (job.appId > 0) return this.iconFor(job.appId);
    return this.localIcons.find((entry: LocalIcon) => entry.jobId === job.id)?.pixels;
  }

  /**
   * 从本地 HAP 里取出应用图标。
   *
   * 商店的图标来自服务器，本地导入的包没有这一层，只能读包内的
   * `resources/base/media/<app.icon>`。读不到就保持文字占位，不算错误。
   */
  private async loadLocalIcon(job: InstallJob): Promise<void> {
    if (job.cachePath.length === 0 || !fileIo.accessSync(job.cachePath)) return;
    if (this.localIcons.some((entry: LocalIcon) => entry.jobId === job.id)) return;
    try {
      // 清单只解析一次，之后按引用直接取图标字节
      const reference = iconReference(job.cachePath);
      const bytes = readIconBytes(job.cachePath, reference);
      if (bytes === undefined) return;
      const source = image.createImageSource(bytes);
      try {
        const pixels = await source.createPixelMap();
        const icon = new LocalIcon();
        icon.jobId = job.id;
        icon.pixels = pixels;
        this.localIcons = this.localIcons.concat([icon]);
      } finally {
        await source.release();
      }
    } catch (_) {
      // 图标读不出来不影响安装结果，保持占位即可
    }
  }

  private async loadLocalIcons(jobs: InstallJob[]): Promise<void> {
    for (const job of jobs) {
      if (job.appId <= 0) await this.loadLocalIcon(job);
    }
  }

  /** 后台补齐本地 HAP 的图标，失败不影响列表本身。 */
  private syncLocalIcons(): void {
    const jobs = this.allInstalledJobs().filter((job: InstallJob) =>
      job.appId <= 0 && job.cachePath.length > 0);
    if (jobs.length === 0) return;
    this.loadLocalIcons(jobs);
  }

  /**
   * 安装阶段的用户可读说明。
   *
   * 界面原来只显示「继续中…」，用户看不到卡在哪一步。任务在 RDB 里逐阶段
   * 落盘，这里把它翻成一句话，进度和失败原因就都能看见了。
   */
  private stageLabel(stage: InstallStage): string {
    switch (stage) {
      case InstallStage.QUEUED: return '排队中';
      case InstallStage.DOWNLOADING: return '正在下载安装包';
      case InstallStage.VERIFIED: return '下载完成，正在读取应用信息';
      case InstallStage.PACKAGE_INSPECTED: return '已确认应用身份，正在准备设备授权';
      case InstallStage.PROFILE_READY: return '授权就绪，正在签名';
      case InstallStage.SIGNED: return '签名完成，正在校验签名';
      case InstallStage.SIGNATURE_VERIFIED: return '签名有效，正在连接设备';
      case InstallStage.WAITING_NETWORK: return '网络中断，稍后自动重试';
      case InstallStage.WAITING_ACCOUNT: return '等待登录华为开发者账号';
      case InstallStage.WAITING_CONFIRMATION: return '等待确认是否清除应用数据';
      case InstallStage.WAITING_DEVICE: return '等待无线调试连接';
      case InstallStage.INSTALLING: return '正在安装到设备';
      case InstallStage.INSTALLED: return '安装完成';
      case InstallStage.RETRYABLE_ERROR: return '可重试的错误';
      case InstallStage.TERMINAL_ERROR: return '无法继续';
      default: return '';
    }
  }

  /** 进行中的任务：阶段说明；空闲时给已安装的版本号或失败原因。 */
  /**
   * 展示用版本号。
   *
   * versionCode 是设备比对用的整数（2026092902 这种），给人看没有意义，
   * 所以优先显示 versionName；没有版本名时才回退。
   */
  private versionLabel(job: InstallJob): string {
    if (job.stage === InstallStage.INSTALLED) {
      const liveName = LocalBundles.installedVersionName(job.bundleName, job.versionCode);
      if (liveName.length > 0) return liveName;
    }
    if (job.versionName.length > 0) return job.versionName;
    // 旧记录（加 version_name 字段之前装的）没有版本名。直接显示 versionCode 会
    // 得到 2026092902 这种看着像日期的数字，所以依次退两步。
    const app = this.catalogForJob(job);
    if (app !== undefined) {
      const direct = app.latestAsset;
      if (direct !== undefined && direct.versionCode === job.versionCode &&
        direct.versionName.length > 0) {
        return direct.versionName;
      }
    }
    // 装的是旧版本时目录里只有「最新版」的版本名，对不上号；这时从包名解析。
    // 发布的包名通常带版本，如 qingqi-native-formal-0.4.5-device6.1-signed.hap。
    const fromName = Index.versionFromAssetName(job.assetName);
    return fromName.length > 0 ? fromName : String(job.versionCode);
  }

  /** 从 HAP 文件名里取出形如 0.4.5 的版本号；取不到返回空串。 */
  private static versionFromAssetName(assetName: string): string {
    const match = assetName.match(/([0-9]+\.[0-9]+\.[0-9]+)/);
    return match !== null && match.length > 1 ? match[1] : '';
  }

  private jobStatusLine(job: InstallJob): string {
    if (this.activeJobId === job.id) return this.stageLabel(job.stage);
    if (job.stage !== InstallStage.INSTALLED) {
      return job.lastError.length > 0 ? job.lastError : this.stageLabel(job.stage);
    }
    const update = this.updateFor(job.bundleName);
    if (update === undefined) {
      const ambiguous = job.appId === 0 && job.bundleName.length > 0 &&
        this.updateApps().filter((app: CatalogApp) =>
          app.latestAsset?.bundleName === job.bundleName).length > 1;
      return '版本 ' + this.versionLabel(job) +
        (ambiguous ? ' · 存在多个同包名来源，请从发现页选择' : '');
    }
    const target = update.versionName.length > 0 ? update.versionName :
      String(update.versionCode);
    if (target === this.versionLabel(job)) return '版本 ' + target + ' · 有修订更新';
    return '版本 ' + this.versionLabel(job) + ' → ' + target;
  }

  private jobTitle(job: InstallJob): string {
    const app = this.catalogForJob(job);
    if (app && app.displayName.length > 0) return app.displayName;
    if (job.bundleName === 'com.tonghongxiang.hapstore.nativepreview' ||
      job.bundleName === 'com.tonghongxiang.hapstore') return '轻启·安装器';
    if (job.sourceUrl === 'local' && job.bundleName.length > 0) {
      const parts = job.bundleName.split('.');
      return parts[parts.length - 1] + ' · 本地应用';
    }
    const name = job.assetName.replace(/\.hap$/i, '').replace(/[-_]/g, ' ');
    return name.length > 0 ? name : job.bundleName;
  }

  private async loadMyApps(): Promise<void> {
    if (!this.signedIn || this.myAppsBusy) return;
    this.myAppsBusy = true;
    try {
      this.myApps = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .myApps(this.account);
      this.myAppsMessage = '';
    } catch (error) {
      this.myAppsMessage = errorText(error);
    } finally {
      this.myAppsBusy = false;
    }
  }

  /**
   * 这个仓库在本店的现状。
   *
   * 服务端的 confirm 用 repo 做主键做 upsert，所以重复提交同一个仓库不会产生
   * 第二条记录，而是**覆盖**已有那条 —— 但那会让用户以为自己新上架了一个应用。
   * 这里在提交前把三种情况分清楚：自己已上架（是更新）、别人已上架（抢不了）、
   * 全新（真正的首次上架）。
   */
  /** 底部导航的页序号，与 HdsTabs 的 index 一致。 */
  /** 搜索防抖：停手多久后才真正发请求。 */
  private static readonly SEARCH_DEBOUNCE_MS: number = 300;

  private static readonly TAB_DISCOVER: number = 0;
  private static readonly TAB_LOCAL: number = 1;
  private static readonly TAB_MANAGE: number = 2;
  private static readonly TAB_MINE: number = 3;

  /** 目录卡片的安装状态。 */
  private static readonly CARD_NOT_INSTALLED: number = 0;
  private static readonly CARD_INSTALLED: number = 1;
  private static readonly CARD_UPDATE: number = 2;

  private static readonly SUBMIT_STATE_NEW: number = 0;
  private static readonly SUBMIT_STATE_MINE: number = 1;
  private static readonly SUBMIT_STATE_OTHER: number = 2;

  private submitStateLabel(): string {
    if (this.submitExisting === Index.SUBMIT_STATE_MINE) {
      return '该仓库已在你的上架列表中「' + this.submitExistingName +
        '」。继续只会更新这一条，不会新增应用。';
    }
    if (this.submitExisting === Index.SUBMIT_STATE_OTHER) {
      return '该仓库已由其他账号上架「' + this.submitExistingName + '」，无法重复上架。';
    }
    return '';
  }

  /** 查一次当前仓库的归属。服务端在 prepare 里已经判定，这里翻译成界面状态。 */
  private classifySubmitRepo(draft: SubmitDraft): void {
    this.submitExisting = Index.SUBMIT_STATE_NEW;
    this.submitExistingId = draft.existingAppId;
    this.submitExistingName = '';
    if (draft.existingState === 'other') {
      this.submitExisting = Index.SUBMIT_STATE_OTHER;
    } else if (draft.existingState === 'mine') {
      this.submitExisting = Index.SUBMIT_STATE_MINE;
    }
    if (this.submitExisting === Index.SUBMIT_STATE_NEW) return;
    // 已在架时补上展示名：本地列表里找得到就用本地的，省一次请求
    const key = draft.repo.trim().toLowerCase();
    const rows = this.submitExisting === Index.SUBMIT_STATE_MINE ? this.myApps : this.apps;
    const hit = rows.find((app: CatalogApp) => app.repo.toLowerCase() === key);
    this.submitExistingName = hit !== undefined ? hit.displayName : draft.repo;
  }

  private async prepareSubmit(): Promise<void> {
    if (!this.signedIn) {
      this.submitMessage = '请先在「我的」登录华为开发者账号';
      return;
    }
    this.submitBusy = true;
    this.submitMessage = '正在检查 Release 中的 HAP…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      // 上架前先刷新一次自己的上架列表，否则刚上架/刚删除的判断会用到旧数据。
      try { this.myApps = await new StoreClient(context).myApps(this.account); } catch (_) {}
      this.submitDraft = await new StoreClient(context).prepareSubmit(this.submitUrl.trim(),
        this.account);
      this.submitAsset = this.submitDraft.choices.length > 0 ? this.submitDraft.choices[0].name : '';
      const categories = this.submitDraft.categories;
      this.submitCategory = this.submitDraft.suggestedCategory;
      const index = categories.indexOf(this.submitCategory);
      this.submitCategoryIndex = index >= 0 ? index : 0;
      this.submitCategory = categories.length > 0 ? categories[this.submitCategoryIndex] : '';
      this.classifySubmitRepo(this.submitDraft);
      this.submitMessage = this.submitDraft.choices.length + ' 个 HAP 已检查，请确认上架内容';
    } catch (error) {
      this.submitDraft = new SubmitDraft();
      this.submitExisting = Index.SUBMIT_STATE_NEW;
      this.submitMessage = errorText(error);
    } finally {
      this.submitBusy = false;
    }
  }

  private async confirmSubmit(): Promise<void> {
    if (this.submitExisting === Index.SUBMIT_STATE_OTHER) {
      this.submitMessage = '该仓库已由其他账号上架，无法重复上架';
      return;
    }
    this.submitBusy = true;
    this.submitMessage = this.submitExisting === Index.SUBMIT_STATE_MINE ?
      '正在更新已上架的应用…' : '正在上架…';
    try {
      const app = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .confirmSubmit(this.submitDraft, this.submitAsset, this.submitCategory, this.account);
      const wasUpdate = this.submitExisting === Index.SUBMIT_STATE_MINE;
      this.showSubmit = false;
      this.submitDraft = new SubmitDraft();
      this.submitMessage = '';
      this.submitExisting = Index.SUBMIT_STATE_NEW;
      this.catalogPage = 0;
      await this.loadApps();
      await this.loadMyApps();
      this.jobsError = wasUpdate ? '' : '';
      router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
    } catch (error) {
      this.submitMessage = errorText(error);
    } finally {
      this.submitBusy = false;
    }
  }

  private removeMyApp(app: CatalogApp): void {
    AlertDialog.show({
      title: '下架应用',
      message: '确定下架「' + app.displayName + '」？已安装的应用不会被删除。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '下架', action: async () => {
        this.removingId = app.id;
        try {
          await new StoreClient(getContext(this) as common.UIAbilityContext)
            .removeMyApp(app.id, this.account);
          this.showAppConfig = false;
          await this.loadMyApps();
          await this.loadApps();
        } catch (error) {
          this.myAppsMessage = errorText(error);
          if (this.showAppConfig) this.configMessage = this.myAppsMessage;
        } finally {
          this.removingId = 0;
        }
      } }
    });
  }

  private async openAppConfig(app: CatalogApp): Promise<void> {
    this.configApp = app;
    this.configCategory = app.category;
    this.configMessage = '';
    this.configCategories = [];
    this.showAppConfig = true;
    this.configBusy = true;
    try {
      this.configCategories = await new StoreClient(getContext(this) as common.UIAbilityContext).categories();
    } catch (error) { this.configMessage = errorText(error); }
    finally { this.configBusy = false; }
  }

  private async saveAppConfig(): Promise<void> {
    if (this.configBusy || !this.configCategories.includes(this.configCategory)) return;
    this.configBusy = true;
    this.configMessage = '';
    try {
      const saved = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .configureMyApp(this.configApp.id, this.configCategory, this.account);
      if (saved.category !== this.configCategory) {
        throw new Error('服务器未保存所选分类，请重试');
      }
      // Keep both already-open lists in sync immediately. The subsequent fetch
      // also catches changes made from another device.
      this.myApps = this.myApps.map((app: CatalogApp) => app.id === saved.id ? saved : app);
      this.apps = this.apps.map((app: CatalogApp) => app.id === saved.id ? saved : app);
      this.showAppConfig = false;
      await this.loadMyApps();
      await this.loadApps();
    } catch (error) { this.configMessage = errorText(error); }
    finally { this.configBusy = false; }
  }

  private async cancelInstall(job: InstallJob): Promise<void> {
    if (this.cancellingJobs.includes(job.id)) return;
    this.cancellingJobs = this.cancellingJobs.concat([job.id]);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await JobScheduler.cancel(context, await JobStore.open(context), job);
      if (this.resumeJobId === job.id) {
        this.resumeJobId = '';
        this.showReconnect = false;
      }
      if (this.localJobId === job.id) this.resetLocalTimeline();
      this.jobsError = '';
      await this.loadJobs();
      this.refreshCatalogInstallState();
      this.drainInstallQueue();
    } catch (error) { this.jobsError = errorText(error); }
    finally { this.cancellingJobs = this.cancellingJobs.filter((id: string) => id !== job.id); }
  }

  private latestVersionTag(app: CatalogApp): string {
    const version = app.latestAsset?.versionName.trim() ?? '';
    if (version.length > 0) return /^v/i.test(version) ? version : 'v' + version;
    // 缺少解析版本时才回退 Release 名称，不把 versionCode 当可读版本号。
    return app.latestName.trim();
  }

  // Updating this installer stops its process before HDC can return success.
  // On the next launch, resolve interrupted installs from the device's real
  // version instead of leaving a permanent "installing" task.
  private reconcilingInstalls: boolean = false;

  private async reconcileInterruptedInstalls(): Promise<void> {
    if (this.reconcilingInstalls) return;
    this.reconcilingInstalls = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const bridge = new HdcDeviceBridge(context);
      const unfinished = (await store.listAll()).filter((job: InstallJob) =>
        !JobScheduler.isRunning(job.id) && (job.stage === InstallStage.INSTALLING ||
          ((job.stage === InstallStage.WAITING_DEVICE || job.stage === InstallStage.RETRYABLE_ERROR) &&
            job.stageHistory.some((mark: StageMark) => mark.stage === InstallStage.INSTALLING))));
      for (const job of unfinished) {
        try {
          const local = LocalBundles.liveInstalledVersion(job.bundleName);
          const installed = LocalBundles.isKnown(local) ? local : await bridge.installedVersion(job.bundleName);
          if (JobScheduler.isRunning(job.id)) continue;
          if (!job.reinstallRequired && installed === job.versionCode) {
            job.stage = InstallStage.INSTALLED;
            job.lastError = '';
            job.allowDataLoss = false;
            job.approvedInstalledVersion = 0;
            job.approvedInstalledFingerprint = '';
            job.approvedInstalledAppIdentifier = '';
          } else {
            job.stage = InstallStage.RETRYABLE_ERROR;
            job.lastError = '安装尚未完成，点击继续安装';
          }
        } catch (_) {
          job.stage = InstallStage.WAITING_DEVICE;
          job.lastError = '连接无线调试后确认安装结果';
        }
        if (!JobScheduler.isRunning(job.id)) await store.save(job);
      }
      if (unfinished.length > 0) await this.loadJobs();
    } catch (_) {
      // 查询失败保留任务，下一次回到前台仍可确认。
    } finally {
      this.reconcilingInstalls = false;
    }
  }

  /**
   * 兜底：把「卡住」的任务恢复成可操作的状态。
   *
   * 两个来源的卡住：
   *   · 界面自己的 activeJobId 还指着某个任务，但它其实已经不在运行（进程重启、
   *     页面重建、任务已经结束）—— 摘掉标记，阶段轮询也停掉。
   *   · 任务停在非终态且很久没有更新（设备掉线、底层调用悬挂、界面被销毁）——
   *     标成可重试，管理页会出现「继续安装」。
   *
   * 只标可重试、不自动重跑：设备上那次安装可能已经生效了，自动重跑会再装一遍。
   */
  private static readonly STUCK_JOB_MS: number = 10 * 60 * 1000;

  private async reconcileStuckJobs(): Promise<void> {
    // 先处理界面状态：activeJobId 指向的任务已经不在运行就清掉
    if (this.activeJobId.length > 0 && !JobScheduler.isRunning(this.activeJobId)) {
      this.activeJobId = '';
    }
    try {
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      const jobs = await store.listAll();
      const now = Date.now();
      let healed = 0;
      for (const job of jobs) {
        if (!isPending(job.stage)) continue;
        if (job.stage === InstallStage.WAITING_CONFIRMATION || job.stage === InstallStage.QUEUED) continue;
        if (JobScheduler.isRunning(job.id)) continue;
        if (now - job.updatedAt < Index.STUCK_JOB_MS) continue;
        job.stage = InstallStage.RETRYABLE_ERROR;
        job.lastError = '上次安装中断了，点击继续安装';
        await store.save(job);
        healed++;
      }
      if (healed > 0) {
        await this.loadJobs();
        this.jobsError = '';
      }
    } catch (_) {
      // 兜底失败不该影响页面：下次回到页面还会再试
    }
  }

  private observeInstallTasks(): void {
    if (this.installSubscription !== -1) return;
    this.installSubscription = InstallTaskState.subscribe((rows: InstallTaskSnapshot[]) => {
      this.installTasks = rows;
      this.refreshLocalTimeline();
      this.pendingJobs = rows.map((row: InstallTaskSnapshot) => row.job).filter((job: InstallJob) =>
        job.stage !== InstallStage.INSTALLED && job.stage !== InstallStage.TERMINAL_ERROR)
        .sort((a: InstallJob, b: InstallJob) => this.queueTime(a) - this.queueTime(b));
      const installed = rows.map((row: InstallTaskSnapshot) => row.job).filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLED);
      const previous = this.installedJobs.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',');
      const current = installed.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',');
      if (previous !== current) {
        this.installedJobs = installed;
        this.forgetInstalledVersions();
        this.refreshCatalogInstallState();
        this.checkInstalledUpdates();
      }
    });
  }

  private taskForApp(appId: number, bundleName: string = ''): InstallTaskSnapshot | undefined {
    const asset = this.catalogApp(appId)?.latestAsset;
    if (asset !== undefined) {
      return InstallTaskState.forAsset(this.installTasks, appId, asset.bundleName,
        asset.name, asset.sha256, asset.versionCode);
    }
    const update = this.updateFor(bundleName);
    if (update !== undefined) {
      return InstallTaskState.forAsset(this.installTasks, update.appId, bundleName,
        update.assetName, update.assetSha256, update.versionCode);
    }
    return InstallTaskState.forApp(this.installTasks, appId, bundleName);
  }

  private taskPending(appId: number, bundleName: string = ''): boolean {
    const row = this.taskForApp(appId, bundleName);
    return row !== undefined && (row.running || isPending(row.job.stage));
  }

  private taskRunning(appId: number, bundleName: string = ''): boolean {
    return this.taskForApp(appId, bundleName)?.running ?? false;
  }

  private taskLabel(appId: number, bundleName: string = ''): string {
    const row = this.taskForApp(appId, bundleName);
    return row === undefined ? '准备中' : InstallTaskState.label(row);
  }

  private jobRunning(id: string): boolean {
    return this.installTasks.find((row: InstallTaskSnapshot) => row.job.id === id)?.running ?? false;
  }

  private taskJobLabel(job: InstallJob): string {
    if (job.stage === InstallStage.QUEUED) {
      const ahead = this.pendingJobs.filter((item: InstallJob) =>
        item.stage === InstallStage.QUEUED && this.queueTime(item) < this.queueTime(job)).length;
      return '排队中 · 第 ' + (ahead + 1) + ' 个';
    }
    const row = this.installTasks.find((item: InstallTaskSnapshot) => item.job.id === job.id);
    return row === undefined ? this.stageLabel(job.stage) : InstallTaskState.label(row);
  }

  /**
   * 收起本地页的侧载进度，回到「只有选择文件按钮」的初始状态。
   *
   * 只清界面状态，不删安装记录 —— 已装完的任务仍留在「管理 → 已安装」里。
   */
  private resetLocalTimeline(): void {
    this.localJobId = '';
    this.localInfoJob = new InstallJob();
    this.localFileSize = '';
    this.localTimelineView = new LocalTimelineView();
    this.localMessage = '';
    this.stopStageTicker();
  }

  private async loadJobs(): Promise<void> {
    try {
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      InstallTaskState.seed(await store.listAll());
      this.jobsError = '';
      this.syncLocalIcons();
      this.refreshCatalogInstallState();
      this.checkInstalledUpdates();
    } catch (error) {
      this.jobsError = errorText(error);
    }
  }

  /** stageHistory 保留最初入队时间，updatedAt 则随进度变化。 */
  private queueTime(job: InstallJob): number {
    return job.stageHistory.length > 0 ? job.stageHistory[0].at : job.updatedAt;
  }

  /** 只自动处理排队项；需要用户连接、确认或手动重试的任务保持原状态。 */
  private async drainInstallQueue(): Promise<void> {
    if (!this.queueRecoveryReady || this.queueDraining || this.activeJobId.length > 0) return;
    this.queueDraining = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      while (this.activeJobId.length === 0) {
        const queued = (await store.listAll()).filter((job: InstallJob) =>
          job.appId > 0 && job.stage === InstallStage.QUEUED)
          .sort((a: InstallJob, b: InstallJob) => this.queueTime(a) - this.queueTime(b));
        const job = queued[0];
        if (job === undefined) break;
        // 需要登录的任务不启动；自更新可以直接使用发布包原签名。
        if (!this.signedIn && !LocalBundles.isSelfBundle(job.catalogBundleName)) break;
        try {
          await JobScheduler.runDownload(context, store, job);
          if (await store.get(job.id) === undefined) continue; // 已被用户取消
          await this.continueInstall(job);
          const finished = await store.get(job.id);
          if (finished !== undefined && finished.stage !== InstallStage.INSTALLED) break;
        } catch (error) {
          if (await store.get(job.id) === undefined) continue;
          this.jobsError = errorText(error);
          break;
        }
      }
    } catch (error) {
      this.jobsError = errorText(error);
    } finally {
      this.queueDraining = false;
      await this.loadJobs();
    }
  }

  /** 「已安装」区块展示的全部条目：轻启装过的 + 商店里探测到的。 */
  private allInstalledJobs(): InstallJob[] {
    const recent = this.recentInstalledJobs();
    return recent.concat(this.storeInstalled.filter((job: InstallJob) =>
      !recent.some((item: InstallJob) => item.bundleName === job.bundleName)))
      .map((job: InstallJob) => this.currentInstalledView(job));
  }

  /** 主列表展示设备当前版本；安装历史原样保留，外部更新不改写旧记录。 */
  private currentInstalledView(job: InstallJob): InstallJob {
    const version = LocalBundles.liveInstalledVersion(job.bundleName);
    if (version <= 0) return job;
    const versionName = LocalBundles.installedVersionName(job.bundleName, version);
    if (version === job.versionCode && (versionName.length === 0 ||
      versionName === job.versionName)) return job;
    const view = JSON.parse(JSON.stringify(job)) as InstallJob;
    view.versionCode = version;
    view.versionName = versionName.length > 0 ? versionName :
      (version === job.versionCode ? job.versionName : '');
    return view;
  }

  /**
   * 扫描商店目录里本机已安装的应用。
   *
   * 原生桥没有「列出全部已装应用」的能力（只支持 operation 0-4），
   * 所以只能反向探测：对目录里每个应用取版本资源拿到 bundleName，
   * 再用已装的 installedVersion 判断是否在本机。侧载进来但不在本店的
   * 应用仍然看不到。
   */
  /** 带 TTL 缓存的已装版本查询。 */
  private async cachedInstalledVersion(bridge: HdcDeviceBridge,
    bundleName: string): Promise<number> {
    const now = Date.now();
    const hit = this.versionCache.get(bundleName);
    if (hit !== undefined && now - hit.at < Index.VERSION_TTL_MS) return hit.version;
    const version = await bridge.installedVersion(bundleName);
    const entry = new VersionCacheEntry();
    entry.version = version;
    entry.at = Date.now();
    this.versionCache.set(bundleName, entry);
    return version;
  }

  /** 安装/更新完成后让缓存失效，否则会拿着旧版本号判断「无更新」。 */
  private forgetInstalledVersions(): void {
    this.versionCache.clear();
  }

  /**
   * 扫描商店目录里本机已安装的应用。
   *
   * 原生桥没有「列出全部已装应用」的能力（只支持 operation 0-4），所以只能
   * 反向探测：取版本资源拿到 bundleName，再查本机已装版本。侧载进来但不在
   * 本店目录的应用仍然看不到。
   *
   * 性能上做了两件事：
   *   1. installedVersion 结果按 bundleName 缓存 60 秒，切页不再重复起 hdc；
   *   2. 最多 3 个应用并行探测，避免串行等待（同时限制并发，防止 hdc 进程爆炸）。
   */
  private async scanStoreInstalled(): Promise<void> {
    if (!this.deviceConnected || this.apps.length === 0) {
      this.storeInstalled = [];
      return;
    }
    const token = ++this.scanToken;
    const context = getContext(this) as common.UIAbilityContext;
    const bridge = new HdcDeviceBridge(context);
    const targets: CatalogApp[] = this.apps.slice();
    const found: InstallJob[] = [];
    let cursor = 0;

    // 目录列表已经带上了每个应用最新版本的 bundleName 与 versionCode，
    // 所以这里只需要问设备「装没装 / 装的哪个版本」，不必再逐个请求 releases。
    const worker = async (): Promise<void> => {
      while (true) {
        const index = cursor;
        cursor += 1;
        if (index >= targets.length) return;
        const app = targets[index];
        const asset = app.latestAsset;
        if (asset === undefined || asset.bundleName.length === 0) continue;
        // 轻启自己装过的已经在 installedJobs 里，不重复列
        if (this.installedJobs.some((item: InstallJob) =>
          item.bundleName === asset.bundleName)) continue;
        try {
          const installed = await this.cachedInstalledVersion(bridge, asset.bundleName);
          if (installed <= 0) continue;
          const job = new InstallJob();
          job.id = 'store-' + app.id + '-' + asset.bundleName;
          job.appId = app.id;
          job.bundleName = asset.bundleName;
          job.versionCode = installed;
          job.assetName = asset.name;
          job.sourceUrl = asset.url;
          job.expectedSha256 = asset.sha256;
          job.mirrorUrls = asset.mirrorUrls;
          job.stage = InstallStage.INSTALLED;
          job.updatedAt = Date.now();
          found.push(job);
        } catch (_) {
          // 单个应用探测失败不影响其余
        }
      }
    };

    const workers: Promise<void>[] = [];
    const lanes = Math.min(Index.SCAN_CONCURRENCY, targets.length);
    for (let lane = 0; lane < lanes; lane++) workers.push(worker());
    await Promise.all(workers);

    // 期间又触发过扫描：本次结果已过期，直接丢弃
    if (token !== this.scanToken) return;
    found.sort((left: InstallJob, right: InstallJob) => left.appId - right.appId);
    this.storeInstalled = found;
    // Reactivity only fires on a new array; the installed map rebuilds off it.
    this.refreshCatalogInstallState();
  }

  /**
   * 目录里每个应用在本机的安装状态。
   *
   * 只依赖两处已经在内存里的数据：轻启自己装过的记录，以及扫描到的商店应用。
   * 因此卡片上的「安装 / 打开」按钮能立刻画出来，不用等任何网络或设备查询。
   */
  /**
   * 目录卡片右侧的动作按钮。
   *
   * 未安装给「安装」，装过且目录里有更新给「更新」，其余给「打开」—— 已装的
   * 应用不会再出现「安装」，避免重复装一遍。按钮自己就是进度显示。
   */
  @Builder
  private catalogCardAction(app: CatalogApp, featured: boolean = false) {
    Column() {
      if (this.taskPending(app.id, app.latestAsset?.bundleName ?? '')) {
        Button(this.taskLabel(app.id, app.latestAsset?.bundleName ?? ''))
          .width(94).height(38).padding({ left: 6, right: 6 }).fontSize(11)
          .fontColor(featured ? '#192856' : this.colors().accent)
          .backgroundColor(featured ? '#FFE5A7' : this.colors().accentSoft).borderRadius(12)
          .onClick(() => { this.currentTab = Index.TAB_MANAGE; })
      } else if (this.enqueuingAppIds.includes(app.id)) {
        LoadingProgress().width(24).height(24)
      } else if (this.installedBundleOf(app.id).length > 0) {
        if (this.updateForApp(app.id) !== undefined) {
          Button('更新')
            .width(74).height(38).fontSize(13)
            .fontColor(featured ? '#192856' : this.colors().onAccent)
            .backgroundColor(featured ? '#FFE5A7' : this.colors().accent).borderRadius(12)
            .onClick(() => this.installFromCatalog(app))
        } else {
          Button('打开')
            .width(74).height(38).fontSize(13)
            .fontColor(featured ? '#192856' : this.colors().accent)
            .backgroundColor(featured ? '#FFE5A7' : this.colors().accentSoft)
            .borderRadius(12)
            .onClick(() => this.openCatalogApp(app))
        }
      } else if (this.installedVersionOf(app.id) < 0) {
        // 权限不足且无线调试未连接时，状态无法核实；不能让用户永远卡在检查按钮。
        // 允许先下载并准备任务，设备连接在真正需要授权/安装时再处理。
        Button('安装/更新').width(94).height(38).fontSize(12)
          .fontColor(featured ? '#192856' : this.colors().onAccent)
          .backgroundColor(featured ? '#FFE5A7' : this.colors().accent).borderRadius(12)
          .onClick(() => this.installFromCatalog(app))
      } else {
        Button('安装')
          .width(74).height(38).fontSize(13)
          .fontColor(featured ? '#192856' : this.colors().onAccent)
          .backgroundColor(featured ? '#FFE5A7' : this.colors().accent).borderRadius(12)
          .onClick(() => this.installFromCatalog(app))
      }
    }
  }

  /**
   * 输入即搜，但带防抖。
   *
   * 每敲一个字都发请求既浪费带宽也会让结果乱跳（先到的旧响应可能覆盖新结果），
   * 所以等用户停手 SEARCH_DEBOUNCE_MS 再发一次。
   */
  private onSearchInput(value: string): void {
    this.searchText = value;
    if (this.searchTimer !== -1) clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.applySearch();
    }, Index.SEARCH_DEBOUNCE_MS);
  }

  private clearSearch(): void {
    this.searchText = '';
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.applySearch();
  }

  /**
   * 把关键词交给服务端。
   *
   * 只过滤本地已加载的那一页会漏掉没加载的应用 —— 目录是分页取的，用户看到
   * 的 30 个只是第一页。所以改词后从第 1 页重新拉。
   */
  private applySearch(): void {
    const next = this.searchText.trim();
    if (next === this.activeQuery) return;
    this.activeQuery = next;
    this.apps = [];
    this.catalogTotal = 0;
    this.catalogPage = 0;
    this.loadApps();
  }

  /** 上架入口统一在这里：发现页原来那个 ＋ 已改成搜索。 */
  private openSubmitSheet(): void {
    if (!this.signedIn) {
      this.jobsError = '上架需要先登录华为开发者账号，已切到「我的」';
      this.currentTab = Index.TAB_MINE;
      return;
    }
    this.submitDraft = new SubmitDraft();
    this.submitMessage = '';
    // 每次打开都从「未检查」开始，避免带上一轮的重复上架判断
    this.submitExisting = Index.SUBMIT_STATE_NEW;
    this.submitExistingName = '';
    this.submitCategory = '';
    this.submitCategoryIndex = 0;
    this.submitAsset = '';
    this.showSubmit = true;
  }

  private openDetail(appId: number): void {
    router.pushUrl({ url: 'pages/Detail', params: { id: appId } });
  }

  /** 已装应用的入口 ability 只有安装记录里才有，探测到的不一定知道。 */
  private openCatalogApp(app: CatalogApp): void {
    const job = this.installedJobFor(app.id);
    if (job === undefined) {
      router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
      return;
    }
    this.openInstalled(job);
  }

  /**
   * 从目录卡片直接安装或更新。
   *
   * 点击立即写入持久队列；后台按入队顺序下载、签名、安装。
   */
  private async installFromCatalog(app: CatalogApp): Promise<void> {
    if (this.enqueuingAppIds.includes(app.id) ||
      this.taskPending(app.id, app.latestAsset?.bundleName ?? '')) return;
    // ForEach 的点击闭包可能还持有上一轮卡片；与「更新」判断使用同一份当前目录。
    const asset = this.catalogApp(app.id)?.latestAsset;
    if (asset === undefined || !/^https:\/\//.test(asset.url)) {
      this.jobsError = '「' + app.displayName + '」缺少 HTTPS 下载地址';
      return;
    }
    if (!this.signedIn && !LocalBundles.isSelfBundle(asset.bundleName)) {
      // 安装器自更新保留发布包原签名，不消耗用户 AGC 证书。
      this.jobsError = '安装前需要先登录华为开发者账号，已切到「我的」';
      this.currentTab = Index.TAB_MINE;
      return;
    }
    if (this.installedVersionOf(app.id) >= asset.versionCode && asset.versionCode > 0) {
      this.checkInstalledUpdates();
      return;
    }
    this.enqueuingAppIds = this.enqueuingAppIds.concat([app.id]);
    this.jobsError = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      await store.enqueue(app.id, asset.name, asset.url, asset.sha256,
        asset.mirrorUrls, asset.versionName, asset.bundleName, asset.versionCode);
      this.drainInstallQueue();
    } catch (error) {
      this.jobsError = errorText(error);
    } finally {
      this.enqueuingAppIds = this.enqueuingAppIds.filter((id: number) => id !== app.id);
      await this.loadJobs();
    }
  }

  /**
   * 重建目录卡片的安装状态。
   *
   * 数据源按可靠性排序：
   *   1. 轻启自己的安装记录（知道入口 ability，能直接「打开」）
   *   2. 系统 bundleManager 查到的本机版本（同步、免网络、免无线调试）
   *   3. 上次由 HDC 确认并落盘的本机版本（系统权限不足且调试离线时使用）
   * 三者都没有才显示状态未知；未知仍可主动安装或更新。
   */
  private refreshCatalogInstallState(): void {
    const next = new Map<number, number>();
    const unresolved: string[] = [];
    for (const app of this.updateApps()) {
      const asset = app.latestAsset;
      if (asset === undefined || asset.bundleName.length === 0) continue;
      const version = LocalBundles.installedVersion(asset.bundleName);
      if (version > 0) {
        next.set(app.id, version);
        continue;
      }
      // 只有「确认没装」才能就此收手；「无法核实」需要退一步问设备。
      if (!LocalBundles.isKnown(version)) {
        next.set(app.id, this.installedVersions.get(app.id) ?? -1);
        unresolved.push(asset.bundleName);
      } else {
        next.set(app.id, 0);
      }
    }
    this.installedVersions = next;
    this.syncDetectedInstalled();
    this.checkInstalledUpdates();
    if (unresolved.length > 0) this.confirmCatalogVersionsViaDevice(unresolved);
    else this.updateInstallScanPrompt();
  }

  /** 初次没有设备快照时，先识别外部侧载应用；用户仍可稍后连接并浏览目录。 */
  private updateInstallScanPrompt(): void {
    this.needsInstallScan = this.updateApps().some((app: CatalogApp) =>
      (app.latestAsset?.bundleName.length ?? 0) > 0 && this.installedVersionOf(app.id) < 0);
    if (!this.needsInstallScan || !this.updateCatalogReady || !this.accountChecked ||
      !this.signedIn || this.catalogProbeBusy || this.initialScanDismissed ||
      InstalledAppRegistry.hasCatalogSnapshot() || this.showReconnect || this.showSubmit ||
      this.showAppConfig || this.activeJobId.length > 0 || this.pendingJobs.length > 0) return;
    this.openInstallScan();
  }

  private openInstallScan(): void {
    if (this.reconnectBusy) return;
    this.initialScanDismissed = true;
    this.resumeJobId = '';
    this.reconnectMessage = '';
    this.showReconnect = true;
  }

  /**
   * 系统查询被拒（权限不足）时，退一步问设备。
   *
   * HDC 的 `bm dump` 不需要任何权限，是这种情况下唯一可靠的来源。问到了就补进
   * `installedVersions`；问不到就什么都不做 —— 卡片宁可少显示一次「已安装」，
   * 也不能谎报「未安装」，那会让用户把已经装好的应用再装一遍。
   */
  private catalogProbeBusy: boolean = false;

  private async confirmCatalogVersionsViaDevice(bundleNames: string[]): Promise<void> {
    if (this.catalogProbeBusy) {
      this.catalogProbePending = this.catalogProbePending.concat(bundleNames)
        .filter((name: string, index: number, all: string[]) => all.indexOf(name) === index);
      return;
    }
    this.catalogProbeBusy = true;
    try {
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      const versions = await bridge.installedBundleVersions(bundleNames);
      if (versions === undefined) return;
      const next = new Map(this.installedVersions);
      for (const app of this.updateApps()) {
        const name = app.latestAsset?.bundleName ?? '';
        if (!bundleNames.includes(name)) continue;
        const version = versions.get(name);
        if (version === undefined) next.set(app.id, 0);
        else if (version > 0) next.set(app.id, version);
      }
      this.installedVersions = next;
      this.syncDetectedInstalled();
      this.checkInstalledUpdates();
      await this.reconcileDetectedJobs(versions);
      if (this.updateCatalogReady && this.updateApps().every((app: CatalogApp) =>
        (app.latestAsset?.bundleName.length ?? 0) === 0 || this.installedVersionOf(app.id) >= 0)) {
        await InstalledAppRegistry.markCatalogSnapshot(getContext(this) as common.UIAbilityContext);
      }
    } catch (_) {
      // 不可核实不等于未安装，保持最后一次已知状态。
    } finally {
      this.catalogProbeBusy = false;
      const pending = this.catalogProbePending;
      this.catalogProbePending = [];
      if (pending.length > 0) await this.confirmCatalogVersionsViaDevice(pending);
      this.updateInstallScanPrompt();
    }
  }

  /** 外部安装条目来自设备，而不是伪造一条本安装器的安装历史。 */
  private syncDetectedInstalled(): void {
    const found: InstallJob[] = [];
    const seen = new Set<string>();
    for (const app of this.updateApps()) {
      const asset = app.latestAsset;
      if (asset === undefined || seen.has(asset.bundleName)) continue;
      const version = this.installedVersions.get(app.id) ?? -1;
      if (version <= 0) continue;
      seen.add(asset.bundleName);
      const job = new InstallJob();
      job.id = 'store-' + app.id + '-' + asset.bundleName;
      job.appId = app.id;
      job.bundleName = asset.bundleName;
      job.versionCode = version;
      job.versionName = version === asset.versionCode ? asset.versionName : '';
      job.stage = InstallStage.INSTALLED;
      found.push(job);
    }
    this.storeInstalled = found;
  }

  /** 相同包、相同版本已经在设备上，无须再继续一个旧的暂停任务。 */
  private async reconcileDetectedJobs(versions: Map<string, number>): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const store = await JobStore.open(context);
    for (const task of this.installTasks) {
      if (task.running || task.job.appId <= 0 || task.job.reinstallRequired ||
        !isPending(task.job.stage) || task.job.versionCode <= 0 ||
        versions.get(task.job.bundleName) !== task.job.versionCode) continue;
      const current = await store.get(task.job.id);
      if (current === undefined || current.reinstallRequired ||
        JobScheduler.isRunning(current.id) || !isPending(current.stage)) continue;
      if (versions.get(current.bundleName) !== current.versionCode) continue;
      current.stage = InstallStage.INSTALLED;
      current.lastError = '';
      current.allowDataLoss = false;
      current.approvedInstalledVersion = 0;
      current.approvedInstalledFingerprint = '';
      current.approvedInstalledAppIdentifier = '';
      await store.save(current);
    }
  }

  /** 完整目录可用后，不再让搜索结果或第一页决定管理页的更新来源。 */
  private updateApps(): CatalogApp[] {
    return this.updateCatalogReady ? this.updateCatalog : this.apps;
  }

  private catalogApp(appId: number): CatalogApp | undefined {
    const management = this.updateApps().find((app: CatalogApp) => app.id === appId);
    const visible = this.apps.find((app: CatalogApp) => app.id === appId);
    if (management === undefined) return visible;
    if (visible === undefined) return management;
    return (visible.latestAsset?.versionCode ?? 0) >
      (management.latestAsset?.versionCode ?? 0) ? visible : management;
  }

  /** 已有线上来源保持来源；纯本地安装仅在包名唯一匹配时自动关联。 */
  private catalogForJob(job: InstallJob): CatalogApp | undefined {
    if (job.bundleName.length === 0) return undefined;
    const matches = this.updateApps().filter((app: CatalogApp) =>
      app.latestAsset?.bundleName === job.bundleName);
    if (job.appId > 0) return matches.find((app: CatalogApp) => app.id === job.appId);
    // 首屏只有部分目录，不能据此认定同包名来源唯一。
    return this.updateCatalogReady && matches.length === 1 ? matches[0] : undefined;
  }

  private featuredTier(stars: number): number {
    return stars >= 10000 ? 3 : stars >= 1000 ? 2 : stars > Index.STARRED_MIN_STARS ? 1 : 0;
  }

  private featuredColors(stars: number): Array<[string, number]> {
    const tier = this.featuredTier(stars);
    if (tier === 3) return [['#09152D', 0], ['#17365E', 0.58], ['#614575', 1]];
    if (tier === 2) return [['#302160', 0], ['#54409C', 0.58], ['#8852AD', 1]];
    return [['#214FD0', 0], ['#3369E8', 0.58], ['#5784F5', 1]];
  }

  /**
   * 发现页列表的展示顺序：大卡优先排在上方。
   *
   * 大卡之间按星数降序；其余保持目录原有顺序（服务端的排序有意义，不重排）。
   * 用 `slice()` 复制再排，别就地改 `this.apps` —— 那个数组还带着分页状态。
   */
  private displayApps(): CatalogApp[] {
    const starred = this.apps.filter((app: CatalogApp) => app.stars > Index.STARRED_MIN_STARS)
      .sort((a: CatalogApp, b: CatalogApp) =>
        b.stars !== a.stars ? b.stars - a.stars : a.id - b.id);
    const rest = this.apps.filter((app: CatalogApp) => app.stars <= Index.STARRED_MIN_STARS);
    return starred.concat(rest);
  }

  private openJobDetails(job: InstallJob): void {
    const app = this.catalogForJob(job);
    if (app !== undefined) router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
  }

  private async loadUpdateCatalog(): Promise<void> {
    if (this.updateCatalogBusy) return;
    this.updateCatalogBusy = true;
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      const collected: CatalogApp[] = [];
      const seen = new Set<number>();
      let pageNumber = 1;
      while (true) {
        const page = await client.listApps(pageNumber, 100, 'new', '');
        const before = collected.length;
        for (const app of page.items) {
          if (seen.has(app.id)) continue;
          seen.add(app.id);
          collected.push(app);
        }
        if (pageNumber * page.pageSize >= page.total) {
          if (collected.length !== page.total) throw new Error('应用目录已变化，请重试');
          break;
        }
        if (collected.length === before) throw new Error('应用目录分页未完成，请重试');
        pageNumber++;
      }
      this.updateCatalog = collected;
      this.updateCatalogReady = true;
      this.updateCatalogError = '';
      this.refreshCatalogInstallState();
    } catch (error) {
      this.updateCatalogError = '更新检查未完成：' + errorText(error);
    } finally {
      this.updateCatalogBusy = false;
    }
  }

  /** 按真实包名关联本地安装，不能拿 appId=0 或显示名称当身份。 */
  private installedVersionOf(appId: number): number {
    const bundleName = this.catalogApp(appId)?.latestAsset?.bundleName ?? '';
    if (bundleName.length === 0) return -1;
    const local = LocalBundles.installedVersion(bundleName);
    if (LocalBundles.isKnown(local)) return local;
    const detected = this.installedVersions.get(appId);
    if (detected !== undefined && detected >= 0) return detected;
    const job = this.allInstalledJobs().find((item: InstallJob) => item.bundleName === bundleName);
    return job !== undefined ? job.versionCode : -1;
  }

  private installedBundleOf(appId: number): string {
    if (this.installedVersionOf(appId) <= 0) return '';
    return this.catalogApp(appId)?.latestAsset?.bundleName ?? '';
  }

  private installedJobFor(appId: number): InstallJob | undefined {
    const bundleName = this.installedBundleOf(appId);
    if (bundleName.length === 0) return undefined;
    return this.allInstalledJobs().find((item: InstallJob) =>
      item.bundleName === bundleName);
  }

  /** 本机版本落后于目录最新版本时给「更新」。 */
  private updateForApp(appId: number): UpdateTarget | undefined {
    const asset = this.catalogApp(appId)?.latestAsset;
    if (asset === undefined) return undefined;
    const installed = this.installedVersionOf(appId);
    if (installed <= 0 || asset.versionCode <= installed) return undefined;
    const target = new UpdateTarget();
    target.bundleName = asset.bundleName;
    target.appId = appId;
    target.assetName = asset.name;
    target.assetUrl = asset.url;
    target.assetSha256 = asset.sha256;
    target.mirrorUrls = asset.mirrorUrls;
    target.versionCode = asset.versionCode;
    target.versionName = asset.versionName;
    return target;
  }

  /**
   * 从目录与系统查询推导出「哪些应用有更新」。
   *
   * 完全是本地计算：目录列表已经带了每个应用最新版本的 versionCode，本机版本
   * 由 bundleManager 同步返回。以前这里要逐个应用请求 releases + 逐个问设备，
   * 是切页卡顿的主要来源。
   */
  private checkInstalledUpdates(): void {
    const found: UpdateTarget[] = [];
    for (const job of this.allInstalledJobs()) {
      const app = this.catalogForJob(job);
      if (app === undefined) continue;
      const target = this.updateForApp(app.id);
      if (target !== undefined) found.push(target);
    }
    this.updates = found;
  }

  private updateFor(bundleName: string): UpdateTarget | undefined {
    return this.updates.find((item: UpdateTarget) => item.bundleName === bundleName);
  }

  /** 下载最新版本并接上安装链路。 */
  private async startUpdate(job: InstallJob, target: UpdateTarget): Promise<void> {
    const app = this.catalogApp(target.appId);
    if (app === undefined) {
      this.jobsError = '更新来源暂不可用，请刷新应用列表';
      return;
    }
    await this.installFromCatalog(app);
  }

  private async openInstalled(job: InstallJob): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await new HdcDeviceBridge(context).openApp(job.bundleName, job.moduleName, job.mainAbility);
      this.jobsError = '';
    } catch (error) {
      this.jobsError = '无法打开应用：' + errorText(error);
    }
  }

  /**
   * 设备连接状态（我的页展示）。
   *
   * HdcDeviceBridge.connected() 内部要起 hdc 进程，本身没有超时；
   * 设备不在线时它可能长时间不返回，界面就会永远停在"正在检测"。
   * 这里加一个硬超时兜底，超时按未连接处理。
   * 另外不要再调用 udid()：它内部会重新跑一遍 connected()，等于再赌一次。
   */
  private async checkDevice(): Promise<void> {
    if (this.deviceBusy) return;
    this.deviceBusy = true;
    let done = false;
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      this.deviceConnected = false;
      this.deviceBusy = false;
    }, 6000);
    try {
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      const connected = await bridge.connected();
      if (done) return;
      this.deviceConnected = connected;
    } catch (_) {
      if (!done) this.deviceConnected = false;
    } finally {
      done = true;
      clearTimeout(timer);
      this.deviceBusy = false;
    }
  }

  private recentInstalledJobs(): InstallJob[] {
    return this.installedJobs.filter((job: InstallJob, index: number, jobs: InstallJob[]) =>
      job.bundleName.length === 0 || jobs.findIndex((entry: InstallJob) =>
        entry.bundleName === job.bundleName) === index);
  }

  private managementInstalledJobs(): InstallJob[] {
    return this.allInstalledJobs().filter((installed: InstallJob) =>
      !this.pendingJobs.some((pending: InstallJob) =>
        (installed.appId > 0 && pending.appId === installed.appId) ||
        (installed.bundleName.length > 0 && (pending.bundleName === installed.bundleName ||
          pending.catalogBundleName === installed.bundleName))));
  }

  private olderInstalledJobs(bundleName: string, newestId: string): InstallJob[] {
    return this.installedJobs.filter((job: InstallJob) =>
      job.bundleName === bundleName && job.id !== newestId);
  }

  private toggleInstallHistory(bundleName: string): void {
    this.expandedInstallBundles = this.expandedInstallBundles.includes(bundleName) ?
      this.expandedInstallBundles.filter((name: string) => name !== bundleName) :
      this.expandedInstallBundles.concat([bundleName]);
  }

  private refreshLocalTimeline(): void {
    this.localTimelineView = LocalInstallTimeline.present(this.installTasks, this.localJobId, Date.now());
    if (this.localTimelineView.running) this.startStageTicker();
    else this.stopStageTicker();
  }

  /** 计时器只更新活动任务的用时，阶段变化由统一任务订阅推送。 */
  private startStageTicker(): void {
    if (this.stageTicker !== -1) return;
    this.stageTicker = setInterval(() => this.refreshLocalTimeline(), 1000);
  }

  private stopStageTicker(): void {
    if (this.stageTicker !== -1) {
      clearInterval(this.stageTicker);
      this.stageTicker = -1;
    }
  }

  private forgetJob(job: InstallJob): void {
    AlertDialog.show({
      title: '移除记录',
      message: '只移除「' + this.jobTitle(job) + ' · 版本 ' + this.versionLabel(job) +
        '」这一条记录，不会卸载应用。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '移除', action: async () => {
        try {
          const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
          await store.forget(job.id);
          await this.loadJobs();
        } catch (error) {
          this.jobsError = errorText(error);
        }
      } }
    });
  }

  /**
   * 刷新已安装列表：与设备对一次账，顺手清掉设备上已经没有的记录。
   *
   * 应用可能在系统设置里被卸载；轻启只记着自己装过，于是管理页会一直留着
   * 一条永远打不开的记录。这里逐条问设备：
   *   · 确认已卸载 → 移除该条记录
   *   · 连接失败   → 整体放弃，绝不把「连不上」当成「已卸载」
   */
  private async refreshInstalled(): Promise<void> {
    if (this.syncBusy) return;
    this.syncBusy = true;
    this.syncMessage = '正在刷新…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const bridge = new HdcDeviceBridge(context);
      if (!await bridge.connected()) {
        this.syncMessage = '无线调试未连接，没能刷新。已安装记录保持不变。';
        return;
      }
      const store = await JobStore.open(context);
      const candidates = this.allInstalledJobs().filter((job: InstallJob) =>
        job.bundleName.length > 0);
      const bundles: string[] = [];
      for (const job of candidates) {
        if (!bundles.includes(job.bundleName)) bundles.push(job.bundleName);
      }
      if (bundles.length === 0) {
        this.syncMessage = '没有需要刷新的记录。';
        return;
      }
      const present: string[] = [];
      const missing: string[] = [];
      for (const bundle of bundles) {
        try {
          if (await bridge.isInstalled(bundle)) present.push(bundle);
          else missing.push(bundle);
        } catch (_) {
          // 单条查询失败（例如设备刚断开）按「不确定」处理，不删记录
          present.push(bundle);
        }
      }
      if (missing.length === 0) {
        this.syncMessage = '已刷新，与设备一致（' + present.length + ' 个应用）。';
        return;
      }
      for (const job of candidates) {
        if (missing.includes(job.bundleName)) await store.forget(job.id);
      }
      this.forgetInstalledVersions();
      this.syncMessage = '已移除 ' + missing.length +
        ' 个设备上已卸载的记录：' + missing.join('、');
    } catch (error) {
      this.syncMessage = '刷新失败：' + errorText(error);
    } finally {
      this.syncBusy = false;
      await this.loadJobs();
    }
  }

  private async recoverDownloads(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const pending = await store.listPending();
      let attempted = 0;
      for (const job of pending) {
        if (attempted >= 2) break;
        if (job.stage !== InstallStage.DOWNLOADING &&
          job.stage !== InstallStage.WAITING_NETWORK) continue;
        if (job.stage === InstallStage.WAITING_NETWORK &&
          Date.now() - job.updatedAt < retryDelayMs(job.attempt)) continue;
        attempted++;
        try {
          await JobScheduler.runDownload(context, store, job);
        } catch (_) {
          // The persisted task and last error remain visible in Management.
        }
        await this.loadJobs();
      }
    } catch (_) {
      // The normal Management error state reports database initialization issues.
    }
  }

  private async pickLocalHap(): Promise<void> {
    this.localBusy = true;
    this.localMessage = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const job = await LocalImport.pickAndImport(context, store);
      this.localJobId = job.id;
      this.localInfoJob = job;
      try {
        this.localFileSize = (fileIo.statSync(job.cachePath).size / (1024 * 1024)).toFixed(1) + ' MB';
      } catch (_) { this.localFileSize = ''; }
      await this.loadLocalIcon(job);
      this.refreshLocalTimeline();
      this.localMessage = '已导入 ' + job.bundleName + ' · ' +
        (job.versionName.length > 0 ? job.versionName : String(job.versionCode)) +
        '，正在准备安装';
      await this.loadJobs();
      await this.continueInstall(job);
    } catch (error) {
      if (!String(error).includes('未选择 HAP')) this.localMessage = String(error);
    } finally {
      this.localBusy = false;
    }
  }

  private async continueInstall(job: InstallJob): Promise<void> {
    if (this.activeJobId.length > 0 || this.jobRunning(job.id)) return;
    this.activeJobId = job.id;
    this.resumeJobId = job.id;
    let installed = false;

    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const runner = new JobRunner(store,
        new NativeJobRuntime(context, store, this.signedIn ? this.account : undefined,
          new HdcDeviceBridge(context)));
      const result = await runner.run(job.id);
      if (result.stage === InstallStage.WAITING_DEVICE) {
        this.reconnectMessage = '';
        this.showReconnect = true;
      } else if (result.stage === InstallStage.WAITING_ACCOUNT) {
        this.jobsError = '请先在「我的」登录华为开发者账号';
      } else if (result.stage === InstallStage.WAITING_CONFIRMATION) {
        this.confirmDataLoss(result);
      } else if (result.stage === InstallStage.INSTALLED) {
        installed = true;
        this.jobsError = '';
        // 完成状态由时间轴卡片顶部的「安装完成」表达，这里不再另设一行
        this.localMessage = '';
      } else {
        this.jobsError = result.lastError;
        this.localMessage = result.lastError;
      }
    } catch (error) {
      if (String(error).includes('安装任务已取消')) return;
      // 超时只结束了「等待」，旧执行还在收尾（锁没放）。把这件事说出来，
      // 否则用户立刻点重试会收到「正在执行」，看起来像卡住了。
      const suffix = JobScheduler.stillFinishing(job.id) ?
        '（本次执行仍在后台收尾，请等它结束后再重试）' : '';
      this.jobsError = errorText(error) + suffix;
      this.localMessage = this.jobsError;
    } finally {
      if (this.activeJobId === job.id) this.activeJobId = '';
      await this.loadJobs();
      if (installed && !this.queueDraining) this.drainInstallQueue();
    }
  }

  private confirmDataLoss(job: InstallJob): void {
    const message = LocalBundles.isSelfBundle(job.bundleName) ?
      '继续会先卸载轻启·安装器，再安装新版。登录状态、本地安装记录、无线调试配对和本地签名材料会清除；签名身份会在卸载前备份。是否继续？' :
      '系统无法保留数据覆盖更新。继续会先卸载旧版，再安装新版；该应用的缓存、设置和登录状态都会清除。是否继续？';
    AlertDialog.show({
      title: '需要卸载旧版',
      message: message,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '清除数据并安装', action: async () => {
        try {
          const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
          const installed = await new HdcDeviceBridge(getContext(this) as common.UIAbilityContext)
            .installedSigningIdentity(job.bundleName);
          if (!installed) throw new Error('无法核对当前安装身份，请连接无线调试后重试');
          const approved = await store.approveDataLoss(job.id, installed);
          await this.continueInstall(approved);
        } catch (error) { this.jobsError = errorText(error); }
      } }
    });
  }

  /**
   * 主动释放设备调试链路。
   *
   * 不打扰用户：不需要确认，也不重新探测设备（探测本身就会重新占链路）。
   * 断开后下次安装/查询会自动重连，配对信息仍然有效。
   */
  private releaseDeviceLink(): void {
    const dropped = HdcDeviceBridge.releaseDevice();
    this.deviceConnected = false;
    this.deviceMessage = dropped ? '已释放调试链路' : '当前没有占用中的调试链路';
    setTimeout(() => { this.deviceMessage = ''; }, 4000);
  }

  private async reconnect(): Promise<void> {
    this.reconnectBusy = true;
    this.reconnectMessage = '正在连接，请在系统弹窗中信任本机';
    try {
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      if (!await bridge.connect(Number(this.reconnectPort.trim()))) {
        this.reconnectMessage = '未连上此端口，请核对无线调试页显示的端口';
        return;
      }
      this.showReconnect = false;
      this.reconnectMessage = '';
      this.deviceConnected = true;
      this.forgetInstalledVersions();
      // 先读取完整目录对应的实际安装状态，再判断是否还要继续先前的安装。
      const bundles = this.updateApps().map((app: CatalogApp) => app.latestAsset?.bundleName ?? '')
        .filter((name: string) => name.length > 0);
      await this.confirmCatalogVersionsViaDevice(bundles);
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      const job = await store.get(this.resumeJobId);
      if (job && job.stage !== InstallStage.INSTALLED) await this.continueInstall(job);
    } catch (error) {
      this.reconnectMessage = errorText(error);
    } finally {
      this.reconnectBusy = false;
    }
  }

  @Builder
  private heading(title: string, subtitle: string = '', horizontalInset: number = PAGE_INSET) {
    Column({ space: 3 }) {
      Text(title).fontSize(29).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
      if (subtitle.length > 0) {
        Text(subtitle).fontSize(12).fontColor(this.colors().textSecondary)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: horizontalInset, right: horizontalInset, top: 20, bottom: 16 })
  }

  @Builder
  private discoverPage() {
    Column() {
      // Refresh 放在最外层：嵌在 if/else 里时下拉手势不会被它接管。
      // 加载态与错误态改为列表项，列表本身始终存在。
      Refresh({ refreshing: $$this.catalogRefreshing }) {
        List({ space: 0 }) {
            // 标题与搜索框放在列表**里面**，跟着一起滚。
            //
            // 放在列表外面时它们固定占着顶部：下方列表只剩中间一段能滚，看起来就是
            // 「上下各被一块挡住」。管理页一直把 heading 作为列表项，这里对齐同样的
            // 做法，整页一起滚、卡片也能占满整屏。
            ListItem() {
              Row() {
                Column({ space: 5 }) {
                  Text('HARMONYOS').fontSize(10).fontWeight(FontWeight.Bold)
                    .fontColor(this.colors().accent).letterSpacing(2)
                  // 副标题与大标题同行、下对齐
                  Row({ space: 9 }) {
                    Text('发现').fontSize(30).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
                    Text('值得安装的应用').fontSize(12).fontColor(this.colors().textSecondary)
                      .padding({ bottom: 5 })
                  }.alignItems(VerticalAlign.Bottom)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').padding({ top: 20, bottom: 14 })
            }.width('100%').padding({ left: PAGE_INSET, right: PAGE_INSET })
            if (this.needsInstallScan) {
              ListItem() {
                Row({ space: 12 }) {
                  Column({ space: 4 }) {
                    Text('识别本机已安装应用').fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(this.colors().text)
                    Text('连接一次无线调试，已有侧载应用会显示打开或更新')
                      .fontSize(11).fontColor(this.colors().textSecondary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Button('识别').height(36).fontSize(12)
                    .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
                    .borderRadius(11).onClick(() => this.openInstallScan())
                }.width('100%').padding(14).backgroundColor(this.colors().surface).borderRadius(16)
              }.width('100%').padding({ left: PAGE_INSET, right: PAGE_INSET, bottom: 12 })
            }
            // 搜索框常驻：输入即搜（带防抖），没有单独的搜索按钮
            ListItem() {
              Row({ space: 9 }) {
                TextInput({ placeholder: '搜索应用名或仓库', text: this.searchText })
                  .layoutWeight(1).height(44).fontSize(14)
                  .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
                  .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
                  .onChange((value: string) => this.onSearchInput(value))
                  .onSubmit(() => this.applySearch())
                if (this.searchText.length > 0) {
                  Text('✕').fontSize(15).fontColor(this.colors().textTertiary)
                    .width(34).height(44).textAlign(TextAlign.Center)
                    .onClick(() => this.clearSearch())
                }
              }.width('100%').padding({ bottom: 10 })
            }.width('100%').padding({ left: PAGE_INSET, right: PAGE_INSET })
            if (this.activeQuery.length > 0) {
              ListItem() {
                Text('搜索「' + this.activeQuery + '」· ' + this.catalogTotal + ' 个结果')
                  .fontSize(11).fontColor(this.colors().textTertiary)
                  .width('100%').maxLines(1)
                  .padding({ bottom: 8 })
              }.width('100%').padding({ left: PAGE_INSET, right: PAGE_INSET })
            }
            if (this.catalogLoading && !this.catalogRefreshing) {
              ListItem() {
                Row() { LoadingProgress().width(30).height(30) }
                  .width('100%').justifyContent(FlexAlign.Center).padding({ top: 36 })
              }
            } else if (this.catalogError.length > 0) {
              ListItem() {
                Column({ space: 12 }) {
                  Text('暂时无法读取应用').fontSize(17).fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().text)
                  Text('检查网络后再试一次').fontSize(12).fontColor(this.colors().textSecondary)
                  Text('下拉可重新加载').fontSize(12).fontColor(this.colors().accent)
                }.padding(25).backgroundColor(this.colors().surface).borderRadius(20)
                  .width('88%').margin({ top: 18 })
              }.width('100%')
            } else if (this.apps.length === 0) {
              ListItem() {
                Column({ space: 10 }) {
                  Text(this.activeQuery.length > 0 ? '没有匹配的应用' : '还没有上架的应用')
                    .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
                  Text(this.activeQuery.length > 0 ?
                    '换个关键词试试，或清除搜索看全部应用' :
                    '在「管理」页的「我上架的应用」里可以从 GitHub Release 添加')
                    .fontSize(12).fontColor(this.colors().textSecondary).textAlign(TextAlign.Center)
                }.width('100%').padding(26).backgroundColor(this.colors().surface).borderRadius(20)
              }
            }
            ForEach(this.displayApps(), (app: CatalogApp) => {
              ListItem() {
                Column() {
                  if (app.stars > 100) {
                  // 与普通卡**同结构**：一个 Row（图标 + 文字列 + 操作按钮）。
                  // 只换背景与文字颜色 —— 之前排成「图标行 + 标签行」两行，
                  // 结构不同，高度自然对不上，怎么调尺寸都还高。
                  Stack({ alignContent: Alignment.TopStart }) {
                    // 每张卡有自己的画布，分页/列表复用时不会只剩第一张有星点。
                    FeaturedCardStars({ appId: app.id, tier: this.featuredTier(app.stars) })
                    Row({ space: 14 }) {
                      if (this.iconFor(app.id)) {
                        Image(this.iconFor(app.id)).width(62).height(62).borderRadius(17)
                      } else {
                        Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                          .fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                          .width(62).height(62).textAlign(TextAlign.Center)
                          .backgroundColor(this.colors().surface).borderRadius(17)
                      }
                      Column({ space: 5 }) {
                        Text(app.displayName).fontSize(17).fontWeight(FontWeight.Bold)
                          .fontColor('#FFFFFF').maxLines(1)
                        Text(app.summary).fontSize(12)
                          .fontColor('#E5ECFF').maxLines(1)
                        Row({ space: 7 }) {
                          // 浅蓝底配**蓝字**：底色是 accentSoft（浅），文字再用 onAccent
                          // （为深色底准备的白/近黑）就会浅底浅字，几乎看不见。
                          // 与普通卡的 tag 用同一组配色，对比度才够。
                          Text(app.category).fontSize(10).fontWeight(FontWeight.Medium)
                            .fontColor('#FFFFFF')
                            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                            .backgroundColor('#32FFFFFF').borderRadius(6)
                          if (this.latestVersionTag(app).length > 0) {
                            Text(this.latestVersionTag(app)).fontSize(10).fontColor('#FFFFFF')
                              .maxLines(1).constraintSize({ maxWidth: 88 })
                              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                              .backgroundColor('#32FFFFFF').borderRadius(6)
                          }
                          Text((this.featuredTier(app.stars) === 3 ? '✦ ' : '★ ') + app.stars)
                            .fontSize(11).fontWeight(FontWeight.Medium)
                            .fontColor(this.featuredTier(app.stars) >= 2 ? '#FFE4A8' : '#FFFFFF')
                            .maxLines(1)
                        }
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        .onClick(() => this.openDetail(app.id))
                      this.catalogCardAction(app, true)
                    }.width('100%').padding(15)
                  }.width('100%').backgroundColor('#214FD0')
                    .linearGradient({ angle: 120, colors: this.featuredColors(app.stars) })
                    .borderRadius(19)
                    .clip(true)
                    .margin({ bottom: 10 })
                  } else {
                    Column() {
                      Row({ space: 14 }) {
                        if (this.iconFor(app.id)) {
                          Image(this.iconFor(app.id)).width(62).height(62).borderRadius(17)
                        } else {
                          Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                            .fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                            .width(62).height(62).textAlign(TextAlign.Center)
                            .backgroundColor(this.colors().accentSoft).borderRadius(17)
                        }
                        Column({ space: 5 }) {
                          Text(app.displayName).fontSize(17).fontWeight(FontWeight.Bold)
                            .fontColor(this.colors().text).maxLines(1)
                          Text(app.summary).fontSize(12).fontColor(this.colors().textSecondary).maxLines(1)
                          Row({ space: 7 }) {
                            Text(app.category).fontSize(10).fontColor(this.colors().accent)
                              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                              .backgroundColor(this.colors().accentSoft).borderRadius(6)
                            if (this.latestVersionTag(app).length > 0) {
                              Text(this.latestVersionTag(app)).fontSize(10).fontColor(this.colors().textSecondary)
                                .maxLines(1).constraintSize({ maxWidth: 88 })
                                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                                .backgroundColor(this.colors().fill).borderRadius(6)
                            }
                            Text('★ ' + app.stars).fontSize(11)
                              .fontColor(this.colors().textTertiary).maxLines(1)
                          }
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                          .onClick(() => this.openDetail(app.id))
                        this.catalogCardAction(app)
                      }.width('100%').padding(15)
                    }.width('100%').backgroundColor(this.colors().surface).borderRadius(19)
                      .margin({ bottom: 10 })
                  }
                }.width('100%').padding({ left: PAGE_INSET, right: PAGE_INSET })
              }
            }, (app: CatalogApp) => String(app.id) + ':' + app.stars + ':' +
              app.category + ':' + app.displayName + ':' + app.iconRev + ':' +
              (app.latestAsset?.sha256 ?? '') + ':' + (app.latestAsset?.versionCode ?? 0))
            // 目录按服务端分页续取：滚到底自动加载下一页。
            if (this.apps.length < this.catalogTotal) {
              ListItem() {
                Row({ space: 9 }) {
                  LoadingProgress().width(19).height(19)
                  Text(this.catalogMoreBusy ? '正在加载更多…' :
                    '还有 ' + String(this.catalogTotal - this.apps.length) + ' 个应用')
                    .fontSize(12).fontColor(this.colors().textSecondary)
                }.width('100%').justifyContent(FlexAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              }
            }
            // 底部留白给悬浮的导航条让位。用列表项而不是列表内边距：内边距会挤在
            // 滚动区里、内容不满一屏时看着像一块空白，列表项则跟着内容走。
            ListItem() {
              Row().width('100%').height(110)
            }
        }.width('100%')
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .onReachEnd(() => this.loadMoreApps())
        }
        // 只给 layoutWeight(1)：标题与搜索已移进列表，这里撑满 Column 剩余高度即可。
        .width('100%').layoutWeight(1)
        .onRefreshing(() => this.pullRefreshCatalog())
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private localPage() {
    Scroll() {
      Column() {
        this.heading('本地安装')
        Column({ space: 0 }) {
          Column({ space: 10 }) {
            if (this.jobIcon(this.localInfoJob)) {
              Image(this.jobIcon(this.localInfoJob)).width(64).height(64).borderRadius(18)
            } else {
              Text('HAP').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                .width(58).height(58).textAlign(TextAlign.Center)
                .backgroundColor(this.colors().accentSoft).borderRadius(18)
            }
            Text(this.localJobId.length > 0 ? this.jobTitle(this.localInfoJob) : '从文件安装')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text).maxLines(2)
            if (this.localJobId.length > 0) {
              Text('版本 ' + this.versionLabel(this.localInfoJob) +
                (this.localFileSize.length > 0 ? ' · ' + this.localFileSize : ''))
                .fontSize(13).fontColor(this.colors().textSecondary).maxLines(1)
              Text(this.localInfoJob.bundleName).fontSize(11).fontColor(this.colors().textTertiary)
                .maxLines(2).textAlign(TextAlign.Center)
              Text('版本代码 ' + this.localInfoJob.versionCode + ' · 模块 ' + this.localInfoJob.moduleName)
                .fontSize(11).fontColor(this.colors().textTertiary).maxLines(2).textAlign(TextAlign.Center)
            }
          }.width('100%').alignItems(HorizontalAlign.Center)
            .margin({ bottom: 22 })

          Button(this.localBusy ? '安装进行中…' :
            (this.localJobId.length > 0 ? '选择其他 HAP 文件' : '选择 HAP 文件'))
            .height(48).enabled(!this.localBusy).width('100%')
            .fontSize(15).fontWeight(FontWeight.Medium)
            .backgroundColor(this.colors().accent).borderRadius(15)
            .onClick(() => this.pickLocalHap())

        }.alignItems(HorizontalAlign.Start).padding(22)
          .width('100%').backgroundColor(this.colors().surface).borderRadius(22)
        // 安装流程时间轴：读取 → 核对 → 签名 → 安装
        if (this.localTimelineView.visible) {
          this.localTimeline()
        }
      }.width('100%').padding({ left: 24, right: 24, bottom: 110 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Off)
      // Scroll 默认把内容垂直居中，内容不满一屏时会浮在中间
      .align(Alignment.Top)
      .backgroundColor(this.colors().bg)
  }

  /** 直接读取响应式视图，避免 @Builder 值参数与 ForEach 闭包保留旧任务。 */
  @Builder
  private localTimeline() {
    Column({ space: 12 }) {
      Row() {
        Text('安装流程').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        Text(this.localTimelineView.version).fontSize(11).fontColor(this.colors().textTertiary)
      }.width('100%')
      Row({ space: 8 }) {
        Text(this.localTimelineView.title).fontSize(12).fontColor(this.colors().textSecondary)
          .layoutWeight(1).maxLines(1)
        Text(this.localTimelineView.status).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.localTimelineView.tone === 'success' ? this.colors().success :
            (this.localTimelineView.tone === 'warning' ? this.colors().danger : this.colors().accent))
          .maxLines(2)
      }.width('100%')
      ForEach(this.localTimelineView.steps, (step: LocalTimelineStep) => {
        Row({ space: 11 }) {
          if (step.indicator === 'running') {
            LoadingProgress().width(17).height(17)
          } else {
            Text(step.indicator === 'done' ? '✓' : '!').fontSize(11).fontColor(this.colors().onAccent)
              .width(17).height(17).textAlign(TextAlign.Center)
              .backgroundColor(step.indicator === 'done' ? this.colors().success : this.colors().danger)
              .borderRadius(9)
          }
          Column({ space: 2 }) {
            Text(step.label).fontSize(13).fontColor(this.colors().text).maxLines(1)
            if (step.timing.length > 0) {
              Text(step.timing).fontSize(10).fontColor(this.colors().textTertiary).maxLines(1)
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
      }, (step: LocalTimelineStep) => step.key)
      if (this.localTimelineView.message.length > 0) {
        Text(this.localTimelineView.message).fontSize(11).fontColor(this.colors().danger)
          .width('100%').maxLines(3)
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(18)
      .backgroundColor(this.colors().surface).borderRadius(20).margin({ top: 18 })
  }

  @Builder
  private managePage() {
    Column() {
      List({ space: 11 }) {
        ListItem() { this.heading('管理', '', 0) }
        if (this.updateCatalogBusy || this.updateCatalogError.length > 0) {
          ListItem() {
            Text(this.updateCatalogBusy ? '正在检查应用更新…' : this.updateCatalogError + ' · 点此重试')
              .fontSize(12).fontColor(this.colors().textSecondary).width('100%').padding(10)
              .onClick(() => this.loadUpdateCatalog())
          }
        }
        if (this.pendingJobs.length > 0) {
          ListItem() {
            Row({ space: 8 }) {
              Text('安装队列').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
              Text(String(this.pendingJobs.length)).fontSize(12).fontColor(this.colors().accent)
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(this.colors().accentSoft).borderRadius(7)
            }.width('100%').padding({ top: 3, bottom: 6 })
          }
          ForEach(this.pendingJobs, (job: InstallJob) => {
            ListItem() {
              Row({ space: 12 }) {
                if (this.jobIcon(job)) {
                  Image(this.jobIcon(job)).width(44).height(44).borderRadius(12)
                } else {
                  Text(this.jobTitle(job).substring(0, 1)).fontSize(18).fontColor(this.colors().accent)
                    .width(44).height(44).textAlign(TextAlign.Center)
                    .backgroundColor(this.colors().accentSoft).borderRadius(12)
                }
                Column({ space: 5 }) {
                  Text(this.jobTitle(job)).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().text).maxLines(1)
                  Text('版本 ' + this.versionLabel(job) + ' · ' + this.taskJobLabel(job))
                    .fontSize(11).fontColor(this.colors().accent).maxLines(2)
                  if (!this.jobRunning(job.id) && job.lastError.length > 0) {
                    Text(job.lastError).fontSize(11).fontColor(this.colors().textTertiary).maxLines(2)
                  }
                  if (job.stage === InstallStage.INSTALLING && this.jobRunning(job.id)) {
                    Text('取消后停止后续步骤，系统已接收的安装可能仍会完成')
                      .fontSize(10).fontColor(this.colors().textTertiary).maxLines(2)
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Column({ space: 7 }) {
                  if (!this.jobRunning(job.id) && job.stage !== InstallStage.QUEUED) {
                    Button('继续安装').height(31).fontSize(11).fontColor(this.colors().onAccent)
                      .backgroundColor(this.colors().accent).borderRadius(10)
                      .enabled(this.activeJobId.length === 0 && this.signedIn &&
                        !this.cancellingJobs.includes(job.id))
                      .onClick(() => this.continueInstall(job))
                  }
                  Button(this.cancellingJobs.includes(job.id) ? '清理中…' : '取消')
                    .height(31).fontSize(11).fontColor(this.colors().danger)
                    .backgroundColor(this.colors().dangerSoft).borderRadius(10)
                    .enabled(!this.cancellingJobs.includes(job.id))
                    .onClick(() => this.cancelInstall(job))
                }
              }.width('100%').padding(15).backgroundColor(this.colors().surface).borderRadius(16)
            }
          }, (job: InstallJob) => job.id)
        }
        if (this.signedIn) {
          ListItem() {
            Row() {
              Text('我上架的应用').fontSize(19).fontWeight(FontWeight.Bold)
                .fontColor(this.colors().text).layoutWeight(1)
              // 与「已安装」那里同一个刷新图标：转圈时不给再点
              if (this.myAppsBusy) {
                LoadingProgress().width(20).height(20)
              } else {
                Text('↻').fontSize(19).fontColor(this.colors().accent)
                  .width(32).height(32).textAlign(TextAlign.Center)
                  .onClick(() => this.loadMyApps())
              }
            }.width('100%').padding({ top: 3, bottom: 6 })
          }
          // 上架入口：从发现页搬到这里，与「我上架的应用」同处一块
          ListItem() {
            Row({ space: 12 }) {
              Text('＋').fontSize(22).fontColor(this.colors().accent)
                .width(42).height(42).textAlign(TextAlign.Center)
                .backgroundColor(this.colors().accentSoft).borderRadius(13)
              Column({ space: 3 }) {
                Text('上架新应用').fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().text).maxLines(1)
                Text('从 GitHub Release 添加一个 HAP')
                  .fontSize(11).fontColor(this.colors().textTertiary).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text('›').fontSize(20).fontColor(this.colors().textTertiary)
            }.width('100%').padding({ left: 12, right: 12, top: 11, bottom: 11 })
              .backgroundColor(this.colors().surface).borderRadius(15)
              .onClick(() => this.openSubmitSheet())
          }
          if (this.myAppsMessage.length > 0) {
            ListItem() {
              Text(this.myAppsMessage).fontSize(12).fontColor(this.colors().danger)
            }
          }
          if (this.myApps.length === 0 && this.myAppsMessage.length === 0) {
            ListItem() {
              Text('还没有上架应用 · 点上面的「上架新应用」添加')
                .fontSize(12).fontColor(this.colors().textTertiary)
                .width('100%').padding({ top: 6, bottom: 8 })
            }
          }
          ForEach(this.myApps, (app: CatalogApp) => {
            ListItem() {
              Row({ space: 12 }) {
                if (this.iconFor(app.id)) {
                  Image(this.iconFor(app.id)).width(42).height(42).borderRadius(11)
                } else {
                  Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                    .fontSize(18).fontColor(this.colors().accent).textAlign(TextAlign.Center)
                    .width(42).height(42).backgroundColor(this.colors().accentSoft).borderRadius(11)
                }
                Column({ space: 4 }) {
                  Text(app.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().text).maxLines(1)
                  Text(app.category + ' · ' + app.publisherName).fontSize(11)
                    .fontColor(this.colors().textTertiary).maxLines(1)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  .onClick(() => router.pushUrl({ url: 'pages/Detail', params: { id: app.id } }))
                Button('配置')
                  .height(31).fontSize(11).fontColor(this.colors().accent)
                  .backgroundColor(this.colors().accentSoft).borderRadius(10)
                  .enabled(this.removingId === 0 && !this.configBusy)
                  .onClick(() => this.openAppConfig(app))
              }.width('100%').padding(15).backgroundColor(this.colors().surface).borderRadius(16)
            }
          }, (app: CatalogApp) => String(app.id) + ':' + app.category + ':' +
            app.displayName + ':' + app.iconRev)
        }
        // 中断任务恢复入口：只在确实有未完成任务时出现，无任务不占版面。
        if (this.jobsError.length > 0) {
          ListItem() {
            Text(this.jobsError).fontSize(12)
              .fontColor(this.colors().danger).width('100%').padding(13)
              .backgroundColor(this.colors().dangerSoft).borderRadius(15)
          }
        }
        if (this.managementInstalledJobs().length > 0) {
          ListItem() {
            Row() {
              Text('已安装').fontSize(19).fontWeight(FontWeight.Bold)
                .fontColor(this.colors().text).layoutWeight(1)
              // 刷新：与设备核对一遍，顺手清掉设备上已经卸载的记录。
              // 按钮本身就是状态——转圈时不给再点。
              if (this.syncBusy) {
                LoadingProgress().width(20).height(20)
              } else {
                Text('↻').fontSize(19).fontColor(this.colors().accent)
                  .width(32).height(32).textAlign(TextAlign.Center)
                  .onClick(() => this.refreshInstalled())
              }
            }.width('100%').padding({ top: 18, bottom: 4 })
          }
          if (this.syncMessage.length > 0) {
            ListItem() {
              Text(this.syncMessage).fontSize(11).fontColor(this.colors().textTertiary)
                .width('100%').maxLines(3).padding({ bottom: 4 })
            }
          }
          ForEach(this.managementInstalledJobs(), (job: InstallJob) => {
            ListItem() {
              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  if (this.jobIcon(job)) {
                    Image(this.jobIcon(job)).width(46).height(46).borderRadius(13)
                  } else {
                    Text(this.jobTitle(job).length > 0 ? this.jobTitle(job).substring(0, 1) : '应')
                      .fontSize(19).fontColor(this.colors().accent).textAlign(TextAlign.Center)
                      .width(46).height(46).backgroundColor(this.colors().accentSoft).borderRadius(13)
                  }
                  Column({ space: 4 }) {
                    Text(this.jobTitle(job)).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(this.colors().text).maxLines(1)
                    Text(this.jobStatusLine(job))
                      .fontSize(11)
                      .fontColor(this.activeJobId === job.id ? this.colors().accent :
                        (this.updateFor(job.bundleName) !== undefined ? this.colors().accent :
                          this.colors().textTertiary))
                      .maxLines(2)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    .onClick(() => this.openJobDetails(job))
                  if (this.updateFor(job.bundleName) !== undefined) {
                    Button(this.taskPending(this.updateFor(job.bundleName)?.appId ?? 0,
                      job.bundleName) ? '已加入队列' : '更新')
                      .height(34).fontSize(12).fontColor(this.colors().onAccent)
                      .backgroundColor(this.colors().accent).borderRadius(11)
                      .onClick(() => {
                        const target = this.updateFor(job.bundleName);
                        if (target !== undefined) this.startUpdate(job, target);
                      })
                  } else {
                    Button('打开').height(34).fontSize(12)
                      .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
                      .borderRadius(11).onClick(() => this.openInstalled(job))
                  }
                }.width('100%')
                if (this.olderInstalledJobs(job.bundleName, job.id).length > 0) {
                  Row() {
                    Text((this.expandedInstallBundles.includes(job.bundleName) ? '收起' : '查看') +
                      '过往安装 · ' + this.olderInstalledJobs(job.bundleName, job.id).length)
                      .fontSize(11).fontColor(this.colors().textSecondary)
                      .onClick(() => this.toggleInstallHistory(job.bundleName))
                  }.width('100%')
                }
                if (this.expandedInstallBundles.includes(job.bundleName)) {
                  ForEach(this.olderInstalledJobs(job.bundleName, job.id), (older: InstallJob) => {
                    Row({ space: 8 }) {
                      Text('版本 ' + this.versionLabel(older)).fontSize(11)
                        .fontColor(this.colors().textTertiary).layoutWeight(1)
                    }.width('100%').padding({ top: 8 })
                  }, (older: InstallJob) => older.id)
                }
              }.alignItems(HorizontalAlign.Start).width('100%')
                .padding(15).backgroundColor(this.colors().surface).borderRadius(17)
                // 移除记录收进长按，避免右上一排动作按钮把标题挤变形。
                .gesture(LongPressGesture().onAction(() => this.forgetJob(job)))
            }
          }, (job: InstallJob) => job.id)
        }
        // 为悬浮导航留出可滚走的尾部空间，不缩小列表的触摸/显示区域。
        ListItem() { Row().height(110).width('100%') }
      }.padding({ left: 24, right: 24 })
        .width('100%').height('100%')
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private reconnectSheet() {
    Column({ space: 15 }) {
      Row() {
        Text(this.resumeJobId.length > 0 ? '连接无线调试' : '识别本机应用')
          .fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        Text('×').fontSize(26).fontColor(this.colors().textSecondary)
          .onClick(() => { if (!this.reconnectBusy) this.showReconnect = false; })
      }.width('100%')
      Text(this.resumeJobId.length > 0 ? '任务已保存。连接后会从刚才的步骤继续。' :
        '首次连接后会识别已经侧载的应用，并将状态缓存到本机，避免重复安装。可以关闭此窗口，稍后在发现页识别。')
        .fontSize(13).fontColor(this.colors().textSecondary).width('100%')
      Button('打开无线调试设置').height(42).width('100%')
        .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
        .onClick(() => new HdcDeviceBridge(getContext(this) as common.UIAbilityContext)
          .openWirelessSettings())
      TextInput({ placeholder: '输入无线调试端口', text: this.reconnectPort })
        .type(InputType.Number).height(48)
        .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
        .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
        .onChange((value: string) => { this.reconnectPort = value; })
      Button(this.reconnectBusy ? '正在连接…' :
        (this.resumeJobId.length > 0 ? '连接并继续安装' : '连接并识别'))
        .height(48).width('100%').enabled(!this.reconnectBusy)
        .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
        .onClick(() => this.reconnect())
      if (this.reconnectMessage.length > 0) {
        Text(this.reconnectMessage).fontSize(12).fontColor(this.colors().textSecondary)
          .width('100%').maxLines(3)
      }
    }.padding(21).width('90%').backgroundColor(this.colors().surface).borderRadius(23)
  }

  @Builder
  private appConfigSheet() {
    Column({ space: 16 }) {
      Row() {
        Text('应用配置').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
          .layoutWeight(1)
        Text('×').fontSize(27).fontColor(this.colors().textSecondary)
          .onClick(() => { if (!this.configBusy && this.removingId === 0) this.showAppConfig = false; })
      }.width('100%')
      Text(this.configApp.displayName).fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(this.colors().text).maxLines(2).width('100%')
      Text('软件分类').fontSize(13).fontColor(this.colors().textSecondary)
      if (this.configCategories.length > 0) {
        Select(this.configCategories.map((category: string) => {
          return { value: category } as SelectOption;
        }))
          .selected(this.configCategories.indexOf(this.configCategory))
          .value(this.configCategory).font({ size: 14 }).fontColor(this.colors().text)
          .optionFontColor(this.colors().text).selectedOptionFontColor(this.colors().accent)
          .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
            .fontColor([this.colors().textSecondary]).fontSize(14))
          .selectedOptionBgColor(this.colors().accentSoft).optionBgColor(this.colors().surface)
          .menuBackgroundColor(this.colors().surface).menuBackgroundBlurStyle(BlurStyle.NONE).backgroundColor(this.colors().fill).width('100%')
          .enabled(!this.configBusy && this.removingId === 0)
          .onSelect((index: number) => { this.configCategory = this.configCategories[index] ?? ''; })
      }
      if (this.configMessage.length > 0) {
        Text(this.configMessage).fontSize(12).fontColor(this.colors().danger).maxLines(3)
      }
      Button(this.configBusy ? '处理中…' : '保存配置').width('100%').height(46)
        .fontColor(this.colors().onAccent).backgroundColor(this.colors().accent).borderRadius(14)
        .enabled(!this.configBusy && this.removingId === 0 &&
          this.configCategories.includes(this.configCategory))
        .onClick(() => this.saveAppConfig())
      Button(this.removingId === this.configApp.id ? '下架中…' : '下架应用')
        .width('100%').height(42).fontColor(this.colors().danger)
        .backgroundColor(this.colors().dangerSoft).borderRadius(14)
        .enabled(!this.configBusy && this.removingId === 0)
        .onClick(() => this.removeMyApp(this.configApp))
    }.alignItems(HorizontalAlign.Start).width('92%').padding(22)
      .backgroundColor(this.colors().surface).borderRadius(24)
  }

  @Builder
  private submitSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('上架应用').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        Text('×').fontSize(27).fontColor(this.colors().textSecondary)
          .onClick(() => { if (!this.submitBusy) this.showSubmit = false; })
      }.width('100%')
      TextInput({ placeholder: '作者/仓库，或 gitee.com/作者/仓库', text: this.submitUrl })
        .height(48).onChange((value: string) => { this.submitUrl = value; })
        .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
        .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
      Button(this.submitBusy && this.submitDraft.token.length === 0 ? '检查中…' : '检查 Release')
        .width('100%').enabled(!this.submitBusy && this.submitUrl.trim().length > 0)
        .onClick(() => this.prepareSubmit())
      if (this.submitDraft.token.length > 0) {
        Text(this.submitDraft.displayName).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor(this.colors().text).width('100%')
        Text('选择 HAP').fontSize(13).fontColor(this.colors().textSecondary).width('100%')
        ForEach(this.submitDraft.choices, (choice: SubmitChoice) => {
          Row({ space: 8 }) {
            Text(this.submitAsset === choice.name ? '◉' : '○')
              .fontSize(20).fontColor(this.colors().accent)
            Column({ space: 3 }) {
              Text(choice.displayName.length > 0 ? choice.displayName : choice.name)
                .fontSize(14).fontColor(this.colors().text).maxLines(1)
              Text(choice.name + ' · ' + choice.versionName)
                .fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding(10).backgroundColor(this.colors().fill)
            .borderRadius(12).onClick(() => { this.submitAsset = choice.name; })
        }, (choice: SubmitChoice) => choice.name)
        Text('选择分类').fontSize(13).fontColor(this.colors().textSecondary).width('100%')
        // 滑动选择框：分类较多时比一排芯片更好点，也不会挤成两行。
        Select(this.submitDraft.categories.map((category: string) => {
          return { value: category } as SelectOption;
        }))
          .selected(this.submitCategoryIndex)
          .value(this.submitCategory.length > 0 ? this.submitCategory : '选择分类')
          .font({ size: 14 })
          .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
          .optionFont({ size: 13 })
          // Font 类型没有 color，文字色要单独设
          .fontColor(this.colors().text)
          .optionFontColor(this.colors().text).selectedOptionFontColor(this.colors().accent)
          .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
            .fontColor([this.colors().textSecondary]).fontSize(14))
          .selectedOptionBgColor(this.colors().accentSoft)
          .optionBgColor(this.colors().surface)
          .menuBackgroundColor(this.colors().surface).menuBackgroundBlurStyle(BlurStyle.NONE)
          .backgroundColor(this.colors().fill)
          .width('100%')
          .enabled(!this.submitBusy)
          .onSelect((index: number) => {
            this.submitCategoryIndex = index;
            this.submitCategory = this.submitDraft.categories[index] ?? '';
          })
        if (this.submitStateLabel().length > 0) {
          Text(this.submitStateLabel()).fontSize(11)
            .fontColor(this.submitExisting === Index.SUBMIT_STATE_OTHER ?
              this.colors().danger : this.colors().textSecondary)
            .width('100%').maxLines(3)
        }
        Button(this.submitBusy ? (this.submitExisting === Index.SUBMIT_STATE_MINE ?
          '更新中…' : '上架中…') :
          (this.submitExisting === Index.SUBMIT_STATE_MINE ? '确认更新已上架应用' : '确认上架'))
          .width('100%')
          .enabled(!this.submitBusy && this.submitAsset.length > 0 &&
            this.submitCategory.length > 0 &&
            this.submitExisting !== Index.SUBMIT_STATE_OTHER)
          .onClick(() => this.confirmSubmit())
      }
      if (this.submitMessage.length > 0) {
        Text(this.submitMessage).fontSize(12).fontColor(this.colors().textBody)
          .width('100%').maxLines(3)
      }
    }.alignItems(HorizontalAlign.Start).width('92%').padding(20)
      .backgroundColor(this.colors().surface).borderRadius(24)
  }

  @Builder
  private minePage() {
    Column() {
      // 卡片是 88% 宽，标题用同样的宽度才对齐（padding 不支持百分比，用宽度表达）
      Column() { this.heading('我的', '', 0) }
        .width('88%').align(Alignment.TopStart)
      Scroll() {
        Column({ space: 16 }) {
          // ── 华为开发者身份 ──
          Column({ space: 15 }) {
            Row({ space: 14 }) {
              if (this.signedIn && this.account.avatarUrl.length > 0) {
                Image(this.account.avatarUrl).width(58).height(58).borderRadius(29)
              } else {
                Text(this.signedIn ? this.account.label.substring(0, 1) : '华')
                  .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                  .width(58).height(58).textAlign(TextAlign.Center)
                  .backgroundColor(this.colors().accentSoft).borderRadius(29)
              }
              Column({ space: 5 }) {
                Text(this.signedIn ? this.account.label : '华为开发者账号')
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
                Text(this.sessionNotice.length > 0 ? this.sessionNotice :
                (this.signedIn ? '开发者身份已连接' : '登录后即可上架和评价'))
                  .fontSize(12).fontColor(this.colors().textSecondary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              // 已登录时退出收成一个图标，比一整条按钮简洁；点一下仍会二次确认
              if (this.signedIn) {
                // 用基础箭头转 180° 得到「←]」这种退出符号：系统符号名在 SDK 里
                // 查不到，字符想保证各机型都能渲染，基础箭头最稳。
                Text('→').fontSize(19).fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().textSecondary)
                  .rotate({ angle: 180 })
                  .width(38).height(38).textAlign(TextAlign.Center)
                  .backgroundColor(this.colors().fill).borderRadius(12)
                  .onClick(() => this.confirmSignOut())
              }
            }.width('100%')
            if (this.loginMessage.length > 0) {
              Text(this.loginMessage).fontSize(12).fontColor(this.colors().textSecondary)
                .maxLines(3).width('100%')
            }
            if (!this.signedIn) {
              Button(this.loginBusy ? '等待浏览器授权…' : '登录华为开发者账号')
                .height(43).backgroundColor(this.colors().accent)
                .fontColor(this.colors().onAccent)
                .borderRadius(14).enabled(!this.loginBusy).width('100%')
                .onClick(() => this.login())
            }
          }.alignItems(HorizontalAlign.Start).padding(20)
            .width('100%').backgroundColor(this.colors().surface).borderRadius(22)

          // ── 证书管理：展示当前证书本体 + 操作 ──
          Text('证书管理').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).width('100%').padding({ left: 4 })
          Column({ space: 14 }) {
            Row({ space: 12 }) {
              Text('证')
                .fontSize(18).fontColor(this.colors().accent).textAlign(TextAlign.Center)
                .width(44).height(44).backgroundColor(this.colors().accentSoft).borderRadius(12)
              Column({ space: 4 }) {
                Text(this.certLabel.length > 0 ? this.certLabel : '调试证书')
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().text).maxLines(1)
                Text(this.certId.length > 0 ? '证书 ID ' + this.certId : '尚未取回证书')
                  .fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
                if (this.certExpiry.length > 0) {
                  Text('到期 ' + this.certExpiry)
                    .fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
                }
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(this.certReady ? '已配对' : '待申请')
                .fontSize(11)
                .fontColor(this.certReady ? this.colors().success : this.colors().textSecondary)
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .backgroundColor(this.certReady ? this.colors().successSoft : this.colors().fill)
                .borderRadius(8)
            }.width('100%')
            Text(this.identityMessage.length > 0 ? this.identityMessage :
              (this.signedIn ? '正在核对账号现有调试证书…' : '登录后自动复用或申请本机签名证书'))
              .fontSize(11).fontColor(this.colors().textTertiary).maxLines(3).width('100%')
            // 备份没成功就说出来：本机私钥只有这一份，用户有权在重置前知道它没有副本。
            if (this.backupWarning.length > 0) {
              Text(this.backupWarning)
                .fontSize(11).fontColor(this.colors().danger).maxLines(4).width('100%')
            }
            // 还没有可用证书时给出唯一的申请入口：复用优先，确无可用证书才占槽位。
            if (this.signedIn && !this.certReady) {
              Button(this.identityBusy ? '正在准备…' :
                (this.certLastSlotConfirmed ? '占用最后槽位并申请' : '获取调试证书'))
                .height(42).width('100%').fontSize(13)
                .backgroundColor(this.certLastSlotConfirmed ? this.colors().danger : this.colors().accent)
                .fontColor(this.colors().onAccent).borderRadius(12)
                .enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
            // 证书快到期时提前重建：过期后签名会直接被设备拒绝。
            if (this.certReady && this.certExpiringSoon) {
              Text('证书将于 ' + this.certExpiry + ' 到期，建议现在重建')
                .fontSize(11).fontColor(this.colors().danger).maxLines(2).width('100%')
              Button(this.identityBusy ? '正在重建…' :
                (this.certLastSlotConfirmed ? '占用最后槽位并重建' : '重建签名身份'))
                .height(38).width('100%').fontSize(12)
                .backgroundColor(this.certLastSlotConfirmed ? this.colors().danger : this.colors().accentSoft)
                .fontColor(this.certLastSlotConfirmed ? this.colors().onAccent : this.colors().accent)
                .borderRadius(12).enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
            Row({ space: 10 }) {
              Button(this.identityBusy ? '重置中…' : '证书重置')
                .height(38).fontSize(12).layoutWeight(1)
                .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
                .borderRadius(12).enabled(!this.identityBusy && this.signedIn)
                .onClick(() => this.resetCertificate())
              Button('管理 AGC 证书')
                .height(38).fontSize(12).layoutWeight(1)
                .backgroundColor(this.colors().fill).fontColor(this.colors().textSecondary)
                .borderRadius(12)
                .onClick(() => {
                  this.showCertSheet = true;
                  this.loadCertRows();
                })
            }.width('100%')
            if (this.certMessage.length > 0) {
              Text(this.certMessage).fontSize(11).fontColor(this.colors().danger)
                .maxLines(2).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).padding(20)
            .width('100%').backgroundColor(this.colors().surface).borderRadius(22)

          // ── 设备连接：已连接只占一行；断线时才给连接按钮 ──
          Text('设备连接').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).width('100%').padding({ left: 4 })
          Column({ space: 13 }) {
            Row({ space: 10 }) {
              Text(this.deviceBusy ? '◌' : (this.deviceConnected ? '✓' : '!'))
                .fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor(this.deviceConnected ? this.colors().success :
                  (this.deviceBusy ? this.colors().textTertiary : this.colors().danger))
              Text(this.deviceBusy ? '正在检测…' :
                (this.deviceConnected ? '无线调试已连接' : '无线调试未连接'))
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
                .layoutWeight(1)
              if (this.deviceConnected) {
                // 已连接就一行，不再显示 UDID；旁边给一个主动释放的出口
                Button('释放')
                  .height(34).fontSize(12).fontColor(this.colors().textSecondary)
                  .backgroundColor(this.colors().fill).borderRadius(11)
                  .onClick(() => this.releaseDeviceLink())
              } else if (!this.deviceBusy) {
                Button('连接')
                  .height(34).fontSize(12).fontColor(this.colors().onAccent)
                  .backgroundColor(this.colors().accent).borderRadius(11)
                  .onClick(() => { this.reconnectPort = ''; this.showReconnect = true; })
              }
            }.width('100%')
            if (this.deviceMessage.length > 0) {
              Text(this.deviceMessage).fontSize(11).fontColor(this.colors().accent)
                .width('100%')
            }
          }.alignItems(HorizontalAlign.Start).padding(18)
            .width('100%').backgroundColor(this.colors().surface).borderRadius(22)

          Text('轻启·安装器').fontSize(12).fontColor(this.colors().textTertiary)
            .margin({ top: 14, bottom: 8 })
        }.width('88%').padding({ top: 4 })
      }.layoutWeight(1).width('100%').height('100%').align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  /**
   * 启动加载页：检查登录态期间显示，替代原来的「先闪一下登录页」。
   * 只有确认需要登录时才切到 loginGate。
   */
  @Builder
  private startupSplash() {
    Column({ space: 22 }) {
      Column({ space: 6 }) {
        Text('轻启').fontSize(38).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
        Text('安装器').fontSize(13).fontColor(this.colors().textTertiary).letterSpacing(4)
      }.alignItems(HorizontalAlign.Center)
      LoadingProgress().width(28).height(28).color(this.colors().accent)
      Text('正在检查登录状态…').fontSize(12).fontColor(this.colors().textTertiary)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors().bg)
  }

  /**
   * 登录闸门：未登录时盖住整个应用。
   *
   * 安装链路必须用用户自己的 AGC 调试证书在本机重签，证书与设备授权
   * 都挂在华为开发者账号下 —— 没登录进来的话，商店能看但一个也装不了，
   * 不如直接挡在门口说清楚。
   */
  @Builder
  private loginGate() {
    Column({ space: 20 }) {
      Column({ space: 8 }) {
        Text('轻启·安装器').fontSize(30).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text)
        Text('用你自己的证书，把 HarmonyOS 应用装到本机')
          .fontSize(13).fontColor(this.colors().textSecondary).textAlign(TextAlign.Center)
      }.alignItems(HorizontalAlign.Center)

      Column({ space: 10 }) {
        Text('为什么必须先登录').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.colors().text).width('100%')
        Text('HarmonyOS 的安装包必须包含本机设备标识。安装时轻启会用你账号下的 ' +
          'AGC 调试证书与设备授权，在本机重新签名后再装到这台设备。' +
          '证书、设备授权与上架记录都绑定在华为开发者账号上。')
          .fontSize(12).fontColor(this.colors().textSecondary).lineHeight(19).width('100%')
      }.alignItems(HorizontalAlign.Start).padding(18).width('100%')
        .backgroundColor(this.colors().surface).borderRadius(18)

      Column({ space: 10 }) {
          Button(this.loginBusy ? '等待浏览器授权…' : '登录华为开发者账号')
            .height(48).width('100%').fontSize(15)
            .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
            .borderRadius(14).enabled(!this.loginBusy)
            .onClick(() => this.login())
          if (this.loginMessage.length > 0) {
            Text(this.loginMessage).fontSize(12).fontColor(this.colors().danger)
              .textAlign(TextAlign.Center).maxLines(3).width('100%')
          }
        Text('登录会打开浏览器，完成后自动回到轻启')
          .fontSize(11).fontColor(this.colors().textTertiary)
      }.width('100%')
    }.width('100%').height('100%').padding({ left: 28, right: 28 })
      .justifyContent(FlexAlign.Center).backgroundColor(this.colors().bg)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      // 每个 Tab 一对「线性 + 实心」系统符号：选中态既换形也换色。
      // 之前「发现」和「管理」共用 square_grid_2x2，且只给了 normal。
      TabContent() { this.discoverPage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.compass_circle'))
            .fontColor([this.colors().tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.compass_circle_fill'))
            .fontColor([this.colors().accent]).fontSize(23)
        }, '发现').iconStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle })
          .labelStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle }))
      TabContent() { this.localPage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.folder'))
            .fontColor([this.colors().tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.folder_fill'))
            .fontColor([this.colors().accent]).fontSize(23)
        }, '本地').iconStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle })
          .labelStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle }))
      TabContent() { this.managePage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.square_stack_3d'))
            .fontColor([this.colors().tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.square_stack_3d_fill'))
            .fontColor([this.colors().accent]).fontSize(23)
        }, '管理').iconStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle })
          .labelStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle }))
      TabContent() { this.minePage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.person'))
            .fontColor([this.colors().tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.person_fill'))
            .fontColor([this.colors().accent]).fontSize(23)
        }, '我的').iconStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle })
          .labelStyle({ selectedColor: this.colors().accent, unselectedColor: this.colors().tabIdle }))
    }
    .barMode(BarMode.Fixed)
    .vertical(false)
    .barOverlap(true)
    // lightColor 原本是饱和蓝，被 IMMERSIVE 材质压成一坨暗色 —— 底部那块
    // "暗区"。改成随主题的卡片色，材质才是正常的玻璃感。
    .barFloatingStyle({
      lightColor: this.colors().surface,
      barSideMargin: 12,
      // 系统导航栏已隐藏，底部不再有安全区，6 会让导航条贴着屏幕边缘。
      barBottomMargin: 20,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      const leavingLocal = this.currentTab === 1 && index !== 1;
      this.currentTab = index;
      // 离开「本地」页就把侧载进度收起来：那是「这一次安装」的过程，装完再回来
      // 还挂着上一次的流程卡片没有意义。清掉选中项，下次导入才会重新出现。
      if (leavingLocal) this.resetLocalTimeline();
      if (index === 2) { this.loadJobs(); this.loadMyApps(); this.loadUpdateCatalog(); }
      if (index === 3) {
        // 设备状态探完再扫「商店已安装」——扫描依赖 connected 与 installedVersion
        this.checkDevice().then(() => this.refreshCatalogInstallState());
      }
    })
    .width('100%').height('100%')
    if (this.showAppConfig) {
      Column() {
        Scroll() { this.appConfigSheet() }
          .width('100%').constraintSize({ maxHeight: '84%' })
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
    }
    if (this.showSubmit) {
      Column() {
        Scroll() { this.submitSheet() }
          .width('100%').constraintSize({ maxHeight: '84%' })
      }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
    }
    if (this.showReconnect) {
      Column() { this.reconnectSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
    }
    if (this.showCertSheet) {
      Column() { this.certSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
    }
    // 最上层三态互斥：检查登录态时显示加载页，确认未登录才显示登录页。
    // 之前把两者混在一个页面里，检查期间会先把登录页的标题和说明卡
    // 画出来再跳走，看着就是「闪一下登录页」。
    if (!this.accountChecked) {
      this.startupSplash()
    } else if (!this.signedIn) {
      this.loginGate()
    }
    }
  }
}
