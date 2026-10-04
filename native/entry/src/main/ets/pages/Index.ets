import { InstalledInspection } from '../data/InstalledInspection';
import { InstalledSigningExpiry } from '../jobs/InstalledSigningExpiry';
import { DiscoverHeader, DiscoverMotion, DiscoverRefreshIndicator } from '../components/DiscoverHeader';
import { DiscoverTopAction } from '../components/DiscoverTopAction';
import { RepositoryStats } from '../components/RepositoryStats';
import { CatalogAppTitle } from '../components/CatalogAppTitle';
import { ListDataSource } from '../data/ListDataSource';
import { RenewalDialog } from '../components/RenewalDialog';
import { LocalProfileDialog } from '../components/LocalProfileDialog';
import { appendCatalogPage, shouldPrefetchCatalog } from '../data/CatalogPaging';
import { ReleaseChannelRegistry } from '../data/ReleaseChannelRegistry';
import { InstallConfirmation } from '../jobs/InstallConfirmation';
import { InstallCertificatePrompt } from '../components/InstallCertificatePrompt';
import { CatalogInstallIdentity } from '../jobs/CatalogInstallIdentity';
import { ClassifiedFailure } from '../data/ServiceFailure';
import { AccountService } from '../data/AccountService';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { InstallReconnect } from '../jobs/InstallReconnect';
import { InstallTaskState, InstallTaskSnapshot } from '../jobs/InstallTaskState';
import { router, promptAction, SymbolGlyphModifier, LengthMetrics } from '@kit.ArkUI';
import { HdsTabs, hdsMaterial, HdsNavigation, HdsNavigationTitleMode,
  TitleBarStyleOptions, DividerShowType } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { FailureKind, InstallJob, InstallStage, StageMark } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { LegacyInstalledMigration } from '../jobs/LegacyInstalledMigration';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { JobScheduler } from '../jobs/JobScheduler';
import { isPending } from '../jobs/RecoveryPlanner';
import { retryDelayMs } from '../jobs/RecoveryPlanner';
import { LocalTool,LocalTools } from '../data/LocalTools';
import { LocalBundles } from '../jobs/LocalBundles';
import { InstalledAppRegistry, InstalledDeviceApp } from '../jobs/InstalledAppRegistry';
import { PackageArchive } from '../jobs/PackageArchive';
import { CatalogApp } from '../data/CatalogApp';
import { CatalogCache, CachedIcon } from '../data/CatalogCache';
import { InstalledIconCache } from '../data/InstalledIconCache';
import { ManagementAction, ManagementActions } from '../data/ManagementActions';
import { ReleaseInfo, HapAsset } from '../data/ReleaseInfo';
import { StoreClient } from '../data/StoreClient';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { DevEcoLogin } from '../data/DevEcoLogin';
import { LocalSigningIdentity, SigningIdentityRecovery, EnrollmentOptions, EnrollmentOutcome } from '../data/SigningIdentity';
import { AgcClient } from '../data/AgcClient';
import { SubmitDraft, SubmitChoice } from '../data/StoreActions';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout, StoreTopStyle } from '../theme/StoreDesign';
import { StoreSelect } from '../theme/StoreSelect';


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
  versionName: string = '';
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

/** Each featured card owns its canvas. Sharing one context between ListItems
 * makes later cards lose their stars when ArkUI recycles the list. */
@Component
struct FeaturedCardStars {
  @Prop appId: number = 0;
  @Prop tier: number = 1;
  @Prop cardHeight: number = 92;
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
    if (this.tier >= 2) {
      // 光晕先铺底，再绘制星点；渐变在画布内收敛，不留下圆形轮廓。
      const glow = this.ctx.createRadialGradient(w * 0.96, h * 0.12, 0,
        w * 0.96, h * 0.12, Math.max(w * 0.7, h * 1.8));
      glow.addColorStop(0, this.tier === 3 ? 'rgba(255,225,170,0.20)' :
        'rgba(223,209,255,0.16)');
      glow.addColorStop(0.45, this.tier === 3 ? 'rgba(255,225,170,0.07)' :
        'rgba(223,209,255,0.05)');
      glow.addColorStop(1, 'rgba(255,255,255,0)');
      this.ctx.fillStyle = glow;
      this.ctx.fillRect(0, 0, w, h);
    }
    const count = this.tier === 3 ? 48 : this.tier === 2 ? 34 : 24;
    const gold = this.tier >= 2;
    for (let i = 0; i < count; i++) {
      const x = (this.hash(this.appId, i * 4 + 1) % 10000) / 10000 * w;
      const y = (this.hash(this.appId, i * 4 + 2) % 10000) / 10000 * h;
      const radius = 0.5 + (this.hash(this.appId, i * 4 + 3) % 100) / 100 *
        (this.tier === 3 ? 2.7 : 2.0);
      const alpha = 0.10 + (this.hash(this.appId, i * 4 + 4) % 100) / 100 * 0.30;
      this.ctx.beginPath();
      this.ctx.arc(x, y, radius, 0, Math.PI * 2);
      this.ctx.fillStyle = gold ? 'rgba(255,226,166,' + alpha.toFixed(2) + ')' :
        'rgba(255,255,255,' + alpha.toFixed(2) + ')';
      this.ctx.fill();
    }
  }


  build() {
    Canvas(this.ctx).width('100%').height(this.cardHeight)
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => this.paint())
      .onSizeChange(() => this.paint())
  }
}

@Entry
@Component
struct Index {
  // 每个颜色使用点通过 colors() 读取此状态，主题变化会更新对应组件。
  @StorageProp('darkMode') darkMode: boolean = false;
  @StorageProp('statusBarInset') statusBarInset: number = 0;
  @State private discoverTitleHeight: number = 88;
  @State private discoverMotion: DiscoverMotion = new DiscoverMotion();
  @State private discoverCanRefresh: boolean = true;
  @State private discoverShowTop: boolean = false;
  @State private topActionEpoch: number = 0;
  private discoverScroller: Scroller = new Scroller();
  private managementScroller: Scroller = new Scroller();
  private localScroller: Scroller = new Scroller();
  private mineScroller: Scroller = new Scroller();
  @State private viewportWidth: number = 0;
  @State private featuredHeights: Map<number, number> = new Map();
  @State private currentTab: number = 0;
  @State @Watch('syncManagementRows') private pendingJobs: InstallJob[] = [];
  @State @Watch('syncManagementRows') private installedJobs: InstallJob[] = [];
  /** 商店目录里、本机已安装但非轻启安装的应用（无 job 记录）。 */
  @State @Watch('syncManagementRows') private storeInstalled: InstallJob[] = [];
  @State @Watch('syncManagementRows') private deviceInstalled: InstallJob[] = [];
  @State private installedLocalOnly: boolean = false;
  @State @Watch('syncManagementRows') private signingExpiries: Map<string, number> = new Map();
  @State @Watch('syncManagementRows') private signingExpiryEstimates: Map<string, number> = new Map();
  @State private bulkUpdating: boolean = false;
  private expiryReadToken: number = 0;
  private deviceInventoryFlight: Promise<void> | undefined = undefined;
  private deviceInventoryAt: number = 0;
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
  @State @Watch('syncManagementRows') private installedDisplay: Map<string, VersionCacheEntry> = new Map();
  @StorageProp('releaseChannelRevision') @Watch('onReleaseChannelsChanged') private releaseChannelRevision: number = 0;
  @State private needsInstallScan: boolean = false;
  @StorageProp('wirelessLinkRevision') @Watch('onWirelessLinkChanged') private wirelessLinkRevision: number = 0;
  @StorageProp('wirelessDebugRestoring') @Watch('onWirelessLinkChanged') private wirelessDebugRestoring: boolean = false;
  @StorageProp('signingIdentityRevision') @Watch('onSigningIdentityChanged') private signingIdentityRevision: number = 0;
  @State private pageVisible: boolean = true;
  private initialScanDismissed: boolean = false;
  private catalogProbePending: string[] = [];
  private catalogProbeNames: string[] = [];
  private catalogProbeFlight: Promise<void> | undefined = undefined;
  private refreshConnectionWaiter: ((connected: boolean) => void) | undefined = undefined;
  private catalogRefreshConnectionCancelled: boolean = false;
  private refreshOpeningSettings: boolean = false;
  /** 入队写库中的应用；只锁住被重复点击的那张卡。 */
  @State private enqueuingAppIds: number[] = [];
  private queueRecoveryReady: boolean = false;
  @State private installTasks: InstallTaskSnapshot[] = [];
  @State private showRenewal: boolean = false;
  @State private renewalTarget: InstallJob = new InstallJob();
  @State private renewalSourceAppId: number = 0;
  @State private renewalExistingJobId: string = '';
  @State private renewalPreparing: string[] = [];
  private installSubscription: number = -1;
  private installJobsRevision: number = -1;
  private confirmationSubscription: number = -1;
  private reconnectSubscription: number = -1;
  /** 与设备核对卸载状态。 */
  @State private syncBusy: boolean = false;
  @State private syncMessage: string = '';
  /** 自动刷新只持有请求锁，不改变管理列表布局。 */
  private myAppsBusy: boolean = false;
  @State private myAppsRefreshing: boolean = false;
  @State private myAppsLoaded: boolean = false;
  /** 「设备连接」卡片里的一次性提示（如「已释放调试链路」）。 */
  @State private deviceMessage: string = '';
  @State private cancellingJobs: string[] = [];
  @State @Watch('syncDiscoverRows') private apps: CatalogApp[] = [];
  private discoverRows: ListDataSource<CatalogApp> = new ListDataSource<CatalogApp>(
    (app: CatalogApp): string => String(app.id), (app: CatalogApp): string => JSON.stringify(app));
  @State private appIcons: AppIcon[] = [];
  /** 管理页按需保留图标，不随发现页搜索或首屏刷新清空。 */
  @State private managementIcons: AppIcon[] = [];
  private managementIconFlights: Map<string, Promise<void>> = new Map();
  private managementIconBatchFlight?: Promise<void>;
  private managementIconPending: boolean = false;
  /** 本轮首屏加载到的图标字节，攒起来一次性写缓存。 */
  private catalogIconFlights: Map<string, Promise<CachedIcon | undefined>> = new Map();
  /** 本地 HAP 的包内图标，按任务 ID 缓存。 */
  @State private localIcons: LocalIcon[] = [];
  @State private localAppNames: Map<string, string> = new Map();
  private deviceIconRequested: Set<string> = new Set();
  @State private catalogError: string = '';
  @State private catalogLoading: boolean = true;
  /** 服务端目录分页：catalogPage 是已加载到的页码，catalogTotal 是服务端总数。 */
  @State private catalogPage: number = 0;
  @State private catalogTotal: number = 0;
  @State private catalogMoreBusy: boolean = false;
  @State private catalogMoreError: string = '';
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
  @State private showCardActions: boolean = false;
  @State private cardActionTitle: string = '';
  @State private cardActionLabels: string[] = [];
  @State private cardDestructiveIndex: number = -1;
  private cardActionResolver?: (index: number) => void;
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
  private submitGeneration: number = 0;
  @State private submitAssets: string[] = [];
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
  @State @Watch('syncManagementRows') private myApps: CatalogApp[] = [];
  @State private myAppsMessage: string = '';
  @State private removingId: number = 0;
  @State private showAppConfig: boolean = false;
  @State private configApp: CatalogApp = new CatalogApp();
  @State private configCategories: string[] = [];
  @State private configCategory: string = '';
  @State private configBusy: boolean = false;
  @State private configMessage: string = '';
  @State private configSourceUrl: string = '';
  @State private configSourceDraft: SubmitDraft = new SubmitDraft();
  @State private configSourceRemove: boolean = false;
  @State private configSourceMessage: string = '';
  @State private configSourceChecking: boolean = false;
  @State private configSourceExpanded: boolean = false;
  @State private uninstallingBundle: string = '';
  private configSourceGeneration: number = 0;
  @State @Watch('onReconnectVisibilityChanged') private showReconnect: boolean = false;
  @State private reconnectPort: string = '';
  @State private reconnectBusy: boolean = false;
  @State private reconnectMessage: string = '';
  @State private resumeJobId: string = '';
  @State @Watch('syncManagementRows') private updates: UpdateTarget[] = [];
  /** 更新目录独立于发现页的搜索和分页，整轮获取成功才替换。 */
  @State @Watch('syncManagementRows') private updateCatalog: CatalogApp[] = [];
  @State @Watch('syncManagementRows') private updateCatalogReady: boolean = false;
  private queueRows: ListDataSource<InstallJob> = new ListDataSource<InstallJob>(
    (job: InstallJob): string => job.id, (job: InstallJob): string => JSON.stringify(job));
  private onlineInstalledRows: ListDataSource<InstallJob> = new ListDataSource<InstallJob>(
    (job: InstallJob): string => job.id, (job: InstallJob): string => JSON.stringify(job));
  private offlineInstalledRows: ListDataSource<InstallJob> = new ListDataSource<InstallJob>(
    (job: InstallJob): string => job.id, (job: InstallJob): string => JSON.stringify(job));
  private publishedRows: ListDataSource<CatalogApp> = new ListDataSource<CatalogApp>(
    (app: CatalogApp): string => String(app.id), (app: CatalogApp): string => JSON.stringify(app));
  @State private queueRowCount: number = 0;
  @State private onlineInstalledCount: number = 0;
  @State private offlineInstalledCount: number = 0;
  private managementRowsTimer: number = -1;
  private updateCatalogBusy: boolean = false;
  @State private updateCatalogError: string = '';
  @State private deviceConnected: boolean = false;
  @State private deviceBusy: boolean = false;
  @State private certReady: boolean = false;
  @State private certLabel: string = '';
  @State private certId: string = '';
  @State private certExpiry: string = '';
  @State private certMessage: string = '';
  @State private showCertSheet: boolean = false;
  @State private showCertificatePrompt: boolean = false;
  @State private certificatePromptDismiss: number = 0;
  @State private showLocalProfiles: boolean = false;
  @State private certRows: CertRow[] = [];
  @State private certSheetBusy: boolean = false;
  @State private certSheetMessage: string = '';
  @State private certDeleting: string = '';
  @State private certUsing: string = '';
  /** 到期后才显示重建入口；有效期内不重复提示。 */
  @State private certExpired: boolean = false;
  /** 只剩最后一个槽位时的二次确认：为 true 才会真的申请。 */
  /** 左滑后等待确认删除的证书 ID。 */
  @State private certConfirmDelete: string = '';

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  private pageInset(): number { return StoreLayout.inset(this.viewportWidth); }

  private onReleaseChannelsChanged(): void {
    this.syncDiscoverRows();
    if (this.pageVisible) this.refreshCatalogInstallState();
    else {
      this.syncDetectedInstalled();
      this.checkInstalledUpdates();
    }
  }

  /** 渲染只读本机观察；主动刷新/安装完成后的查询仍读取真实系统状态。 */
  private displayInstalledVersion(bundleName: string): number {
    const displayed = this.installedDisplay.get(bundleName);
    const confirmed = InstalledAppRegistry.version(bundleName);
    if (confirmed >= 0 && InstalledAppRegistry.observedAt(bundleName) > (displayed?.at ?? 0)) return confirmed;
    return displayed?.version ?? confirmed;
  }

  private syncDiscoverScroll(): void {
    const distance = this.discoverMotion.scroll(this.discoverScroller.currentOffset().yOffset,
      this.discoverTitleHeight);
    const refresh = distance <= 0.5;
    const showTop = distance > 240;
    if (refresh !== this.discoverCanRefresh) this.discoverCanRefresh = refresh;
    if (showTop !== this.discoverShowTop) this.discoverShowTop = showTop;
  }

  private revealDiscoverTop(): void {
    // 使用列表真实起点，HdsNavigation 与安全区会改变 offset 基准。
    this.discoverMotion.reachStart(this.discoverScroller.currentOffset().yOffset);
    if (!this.discoverCanRefresh) this.discoverCanRefresh = true;
    if (this.discoverShowTop) this.discoverShowTop = false;
  }

  private backToDiscoverTop(): void {
    this.discoverScroller.scrollEdge(Edge.Top);
    this.revealDiscoverTop();
  }

  private rememberFeaturedHeight(appId: number, height: number): void {
    if (!Number.isFinite(height) || height <= 0 ||
      Math.abs((this.featuredHeights.get(appId) ?? 92) - height) < 1) return;
    const heights = new Map(this.featuredHeights);
    heights.set(appId, height);
    this.featuredHeights = heights;
  }

  private animateOverlay(change: () => void): void {
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, change);
  }

  aboutToAppear(): void {
    InstallCoordinator.configure(getContext(this) as common.UIAbilityContext);
    this.observeReconnect();
    this.observeInstallTasks();
    InstalledAppRegistry.load(getContext(this) as common.UIAbilityContext)
      .then(() => { this.syncDeviceInstalled(); this.refreshCatalogInstallState(); });
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
    this.pageVisible = true;
    // 系统在路由离开时关闭 Popup。重新创建其锚点，避免缓存页面仍绑定旧的已隐藏 Popup。
    this.topActionEpoch++;
    this.refreshOpeningSettings = false;
    this.observeReconnect();
    this.observeInstallTasks();
    this.drainInstallQueue();
    this.syncViewedCatalog();
    this.syncManagementRows();
    this.refreshCatalogInstallState();
    if (this.currentTab === Index.TAB_MANAGE) { this.scanDeviceInstalled(); this.syncManagementIcons(); this.loadSigningExpiries(); }
    this.reconcileInterruptedInstalls().then(() => this.reconcileStuckJobs());
  }

  private syncViewedCatalog(): void {
    const viewed = StoreClient.consumeViewedApps();
    if (viewed.length === 0) return;
    const merge = (rows: CatalogApp[]): CatalogApp[] => rows.map((row: CatalogApp) => {
      const fresh = viewed.find((app: CatalogApp) => app.id === row.id);
      return fresh !== undefined && JSON.stringify(row) !== JSON.stringify(fresh) ? fresh : row;
    });
    const visible = merge(this.apps);
    const catalog = merge(this.updateCatalog);
    if (visible.some((row: CatalogApp, i: number) => row !== this.apps[i])) this.apps = visible;
    if (catalog.some((row: CatalogApp, i: number) => row !== this.updateCatalog[i])) this.updateCatalog = catalog;
    // 新图标到位后替换旧像素，读取期间保留原图标。
    for (const app of viewed) {
      const current = this.appIcons.find((icon: AppIcon) => icon.id === app.id);
      if (current?.rev !== app.iconRev && this.apps.some((row: CatalogApp) => row.id === app.id)) {
        this.loadAppIcon(new StoreClient(getContext(this) as common.UIAbilityContext), app, this.activeQuery);
      }
    }
  }

  aboutToDisappear(): void {
    this.dismissCardActions(-1);
    this.configSourceGeneration++;
    this.expiryReadToken++;
    this.pageVisible = false;
    this.completeRefreshConnection(false);
    InstallConfirmation.unsubscribe(this.confirmationSubscription);
    this.confirmationSubscription = -1;
    InstallReconnect.unsubscribe(this.reconnectSubscription);
    this.reconnectSubscription = -1;
    InstallTaskState.unsubscribe(this.installSubscription);
    this.installSubscription = -1;
    if (this.managementRowsTimer !== -1) clearTimeout(this.managementRowsTimer);
    this.managementRowsTimer = -1;
    // 页面离开时取消搜索防抖，避免定时器在后台空转
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
        AccountService.configure(context);
        const refreshed = await AccountService.refresh(saved);
        this.account = refreshed;
        this.sessionNotice = '';
      } catch (error) {
        // 断网 / 账号服务 5xx 时不要把用户踢回登录页：本地账号还在，
        // 沿用已保存的登录态，等下次启动或操作时再校验。
        if ((error as ClassifiedFailure).failureKind !== FailureKind.NETWORK) throw new Error(String(error));
        this.account = saved;
        this.sessionNotice = '账号服务暂时不可用，正在使用本地登录态';
      }
      this.signedIn = true;
      this.loginMessage = '';
      InstallCoordinator.conditionReady(context, InstallStage.WAITING_ACCOUNT);
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
      InstallCoordinator.conditionReady(context, InstallStage.WAITING_ACCOUNT);
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
    this.myAppsLoaded = false;
    this.myAppsMessage = '';
    this.myAppsRefreshing = false;
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
      // 过期材料仅用于展示，不能当作可用身份或上传为有效备份。
      const displayed = identity ?? await SigningIdentityRecovery.load(
        getContext(this) as common.UIAbilityContext, account, true);
      if (this.signedIn && this.account.userId === account.userId) {
        this.certReady = identity !== undefined;
        // 复用成功是正常状态，不需要一行说明文字；这个字段继续用于报错与
        // 需要用户动作的提示（未配对、重置失败等）。
        this.identityMessage = displayed ? '' :
          '安装时会自动准备调试证书，也可在此提前获取';
        if (displayed !== undefined) await this.loadCertificateDetail(displayed);
        else this.clearCertificateDetail();
        if (identity !== undefined) await this.syncIdentityToCloud(getContext(this) as common.UIAbilityContext, identity);
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
    this.applyCertificateDetail(identity);
    try {
      const rows = await new AgcClient(this.account).certificates();
      const row = rows.find((item: Record<string, Object>) =>
        String(item['id'] ?? '') === identity.certId);
      if (row === undefined || this.certId !== identity.certId) return;
      const name = String(row['certName'] ?? '');
      if (name.length > 0) this.certLabel = name;
      const seconds = Index.expirySeconds(row['expireTime']);
      if (seconds > 0) {
        this.certExpiry = Index.formatDay(seconds);
        this.certExpired = seconds <= Math.floor(Date.now() / 1000);
      }
    } catch (_) {
      // 离线时只显示本机记录的名称与到期时间
    }
  }

  /** 安装器自动申请证书后立即反映本机材料，不为刷新界面再请求 AGC。 */
  private async onSigningIdentityChanged(): Promise<void> {
    if (!this.signedIn) return;
    const account = this.account;
    const revision = this.signingIdentityRevision;
    const identity = await SigningIdentityRecovery.load(getContext(this) as common.UIAbilityContext, account);
    const displayed = identity ?? await SigningIdentityRecovery.load(
      getContext(this) as common.UIAbilityContext, account, true);
    if (!this.signedIn || this.account.userId !== account.userId ||
      revision !== this.signingIdentityRevision) return;
    this.certReady = identity !== undefined;
    if (identity !== undefined) {
      this.applyCertificateDetail(identity);
      if (!this.identityBusy) this.identityMessage = '';
      // 材料准备成功也是条件变化；等待账号/证书的旧任务无须重启应用才继续。
      InstallCoordinator.conditionReady(getContext(this) as common.UIAbilityContext,
        InstallStage.WAITING_ACCOUNT).catch(() => {});
    } else {
      if (displayed !== undefined) this.applyCertificateDetail(displayed);
      else this.clearCertificateDetail();
    }
  }

  private applyCertificateDetail(identity: LocalSigningIdentity): void {
    this.certId = identity.certId;
    this.certLabel = identity.certName;
    this.certExpired = false;
    if (identity.certExpiry > 0) {
      this.certExpiry = Index.formatDay(identity.certExpiry);
      this.certExpired = identity.certExpiry <= Math.floor(Date.now() / 1000);
    } else {
      this.certExpiry = '';
    }
  }

  private clearCertificateDetail(): void {
    this.certId = ''; this.certLabel = ''; this.certExpiry = ''; this.certExpired = false;
  }

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
   * 申请额度由 AGC 判定，避免本机固定数量误拦截。
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
      options.renewBeforeSeconds = this.certExpired ? Math.floor(Date.now() / 1000) : 0;
      const result = await SigningIdentityRecovery.enroll(context, account, options);
      if (!this.signedIn || this.account.userId !== account.userId) return;
      this.certReady = true;
      await this.loadCertificateDetail(result.identity);
      await this.syncIdentityToCloud(context, result.identity);
      const label = this.certLabel.length > 0 ? this.certLabel : result.identity.certId;
      this.identityMessage = result.outcome === EnrollmentOutcome.CREATED ?
        '已申请并配对新的调试证书「' + label + '」，签名材料已保存在本机' :
        '已复用账号现有调试证书「' + label + '」，未占用新槽位';
    } catch (error) {
      if (!this.signedIn || this.account.userId !== account.userId) return;
      const message = errorText(error);
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
    const account = this.account;
    if (identity.accountId !== account.userId) return false;
    try {
      const pem = fileIo.readTextSync(identity.privateKeyPath);
      await new StoreClient(context).publishSigningIdentity(identity.certId, pem, account);
      if (this.account.userId !== account.userId) return false;
      if (this.backupWarning.length > 0) this.backupWarning = '';
      return true;
    } catch (error) {
      if (this.account.userId !== account.userId) return false;
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
          this.certExpired = false;
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
    this.identityMessage = '正在核对并取回本机证书…';
    try {
      // 按本机证书取回备份；缺少备份时先同步已经配对的本机材料。
      await SigningIdentityRecovery.reset(
        getContext(this) as common.UIAbilityContext, this.account);
    } catch (error) {
      this.identityMessage = errorText(error);
      this.identityBusy = false;
      return;
    }
    // 重新读取已核验的材料，刷新界面状态。
    this.certReady = false;
    this.certId = '';
    this.certLabel = '';
    this.certExpiry = '';
    this.certExpired = false;
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
    Column({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([this.colors().onAccent])
      Text(this.certDeleting === row.id ? '删除中…' : '删除')
        .fontSize(13).fontColor(this.colors().onAccent).fontWeight(FontWeight.Medium)
        .maxLines(1)
    }
    .width(64).height('100%').margin({ left: 8 }).justifyContent(FlexAlign.Center)
    .backgroundColor(this.certDeleting === row.id ? this.colors().textTertiary : this.colors().danger)
    .borderRadius(14).enabled(this.certDeleting.length === 0)
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
        StoreIconButton({ action: () => { this.animateOverlay(() => { this.showCertSheet = false; }); } })
      }.width('100%')
      Text('安装时用与本机私钥配对的那张证书重签。')
        .fontSize(11).fontColor(this.colors().textTertiary)
        .lineHeight(17).width('100%')
      if (this.certSheetBusy) {
        Row({ space: 10 }) {
          LoadingProgress().width(18).height(18)
          Text('正在读取…').fontSize(12).fontColor(this.colors().textSecondary)
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
      } else if (this.certRows.length === 0) {
        Column({ space: 8 }) {
          Text('账号暂无调试证书').fontSize(14).fontColor(this.colors().text)
          Text('安装时会自动获取本机签名证书').fontSize(12)
            .fontColor(this.colors().textSecondary)
        }.width('100%').padding({ top: 24, bottom: 24 })
          .backgroundColor(this.colors().fill).borderRadius(16)
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
                  Button(row.inUse ? '已使用' : this.certUsing === row.id ? '配对中…' : '使用')
                    .height(44).width(72).fontSize(12)
                    .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
                    .borderRadius(8).enabled(this.certUsing.length === 0)
                    .onClick(() => { if (!row.inUse) this.useCertificate(row); })
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
                actionAreaDistance: 72
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
              .height(44).fontSize(12).layoutWeight(1)
              .backgroundColor(this.colors().danger).fontColor(this.colors().onAccent)
              .borderRadius(11).enabled(this.certDeleting.length === 0)
              .onClick(() => {
                const target = this.certRows.find((item: CertRow) =>
                  item.id === this.certConfirmDelete);
                this.certConfirmDelete = '';
                if (target !== undefined) this.deleteCertificate(target);
              })
            Button('取消')
              .height(44).fontSize(12).layoutWeight(1)
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
      Button(this.certSheetBusy ? '读取中…' : '刷新列表')
        .width('100%').height(44).fontSize(13)
        .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
        .borderRadius(12).enabled(!this.certSheetBusy)
        .onClick(() => this.loadCertRows())
    }.padding(24).width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
      .backgroundColor(this.colors().surface).borderRadius(28)
      .transition(TransitionEffect.translate({ y: 16 }))
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
    return this.catalogPage > 0 && this.catalogPage * Index.CATALOG_PAGE_SIZE < this.catalogTotal &&
      !this.catalogLoading && !this.catalogMoreBusy;
  }

  private async loadApps(reset: boolean = true, rescanInstalled: boolean = false): Promise<void> {
    if (reset) {
      this.catalogLoading = true;
    } else if (!this.catalogHasMore()) {
      return;
    }
    this.catalogMoreBusy = true;
    this.catalogMoreError = '';
    // 输入即搜时请求会重叠：只认最后一次发出的那一个，先到的旧响应直接丢弃，
    // 否则「搜 quiet」的慢响应会盖掉「搜 quietstart」的结果。
    const token = ++this.catalogToken;
    const query = this.activeQuery;
    const nextPage = reset ? 1 : this.catalogPage + 1;
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      const requestStartedAt = Date.now();
      const page = await client.listApps(nextPage, Index.CATALOG_PAGE_SIZE,
        'discover', query);
      await ReleaseChannelRegistry.restore(getContext(this) as common.UIAbilityContext);
      console.info('Catalog read: page=' + nextPage + ' elapsedMs=' + (Date.now() - requestStartedAt));
      if (token !== this.catalogToken || query !== this.activeQuery) return;
      // 先加载的页在后，追加时按 id 去重，避免上架/删除后翻页出现重复项。
      const previous: CatalogApp[] = reset ? [] : this.apps;
      const appended = appendCatalogPage(previous, page.items);
      const fresh = appended.slice(previous.length);
      this.apps = appended;
      // 只保留仍在列表里、且本轮不需要重新拉取的图标：
      // 重置整表会把缓存刚恢复的图标一起清掉，看起来像图标丢了。
      if (reset) {
        const keep = new Set<number>(page.items.map((app: CatalogApp) => app.id));
        this.appIcons = this.appIcons.filter((entry: AppIcon) =>
          keep.has(entry.id) && page.items.some((app: CatalogApp) =>
            app.id === entry.id && app.iconRev.length > 0 && app.iconRev === entry.rev));
      }
      // 目录先提交，图标下载、解码和缓存都不占用刷新动画。
      const cacheablePage = reset && this.activeQuery.length === 0;
      this.catalogPage = nextPage;
      this.catalogTotal = page.total;
      this.catalogError = '';
      // 目录变了就重算「装没装」，卡片按钮跟着更新
      const channels = ReleaseChannelRegistry.refreshTargets(getContext(this) as common.UIAbilityContext,
        reset ? this.apps : fresh, rescanInstalled);
      if (rescanInstalled) await channels;
      const recognition = this.refreshCatalogInstallState(rescanInstalled, reset ? undefined : fresh);
      // 只缓存干净的第一页：缓存与分页混在一起会得到半新半旧的列表
      if (cacheablePage) {
        const context = getContext(this) as common.UIAbilityContext;
        CatalogCache.save(context, page.items, page.rawItems);
      }
      this.loadCatalogIcons(client, reset ? this.apps : fresh, query, cacheablePage);
      // 主动下拉等待本轮真实识别完成；启动、搜索和翻页继续异步识别。
      if (rescanInstalled) await recognition;
    } catch (error) {
      if (token !== this.catalogToken || query !== this.activeQuery) return;
      if (reset) this.catalogError = errorText(error);
      else this.catalogMoreError = errorText(error);
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
  private static readonly REFRESH_MIN_VISIBLE_MS: number = 250;
  /** 超过这个星数用大卡。 */
  private static readonly STARRED_MIN_STARS: number = 100;

  private async pullRefreshCatalog(): Promise<void> {
    if (this.catalogRefreshBusy) return;
    this.catalogRefreshBusy = true;
    this.catalogRefreshing = true;
    this.catalogRefreshConnectionCancelled = false;
    const startedAt = Date.now();
    try {
      // 只读取服务端已有目录；GitHub 采集由服务端周期任务或详情页主动检查负责。
      await this.loadApps(true, true);
      this.loadUpdateCatalog();
    } finally {
      const elapsed = Date.now() - startedAt;
      if (elapsed < Index.REFRESH_MIN_VISIBLE_MS) {
        await new Promise<void>((resolve) =>
          setTimeout(resolve, Index.REFRESH_MIN_VISIBLE_MS - elapsed));
      }
      this.catalogRefreshBusy = false;
      this.catalogRefreshing = false;
      console.info('Catalog refresh complete: elapsedMs=' + (Date.now() - startedAt));
    }
  }

  /** 只有设备明确确认卸载才清理旧记录；批量扫描统一由 confirm 方法调度。 */
  private async reconcileCatalogInstallState(bundleNames: string[],
    versions: Map<string, number>): Promise<void> {
    const display = new Map(this.installedDisplay);
    for (const name of bundleNames) {
      const version = versions.get(name);
      if (version !== undefined && version <= 0) continue;
      const entry = new VersionCacheEntry(); entry.version = version ?? 0;
      entry.versionName = InstalledAppRegistry.versionName(name, entry.version);
      display.set(name, entry);
    }
    const missing = bundleNames.filter((name: string) => !versions.has(name));
    const dropped = this.installedJobs.filter((job: InstallJob) =>
      job.bundleName.length > 0 && missing.includes(job.bundleName));
    this.installedJobs = this.installedJobs.filter((job: InstallJob) =>
      !missing.includes(job.bundleName));
    const next = new Map(this.installedVersions);
    for (const app of this.updateApps()) {
      const name = (app.latestAsset ?? this.installedAssets(app)[0])?.bundleName ?? '';
      if (!bundleNames.includes(name)) continue;
      const version = versions.get(name);
      if (version === undefined) next.set(app.id, 0);
      else if (version > 0) next.set(app.id, version);
      // 包存在但版本查询失败时保留原值，不能误判为未装。
    }
    this.installedDisplay = display;
    this.installedVersions = next;
    this.syncDetectedInstalled();
    this.checkInstalledUpdates();
    if (dropped.length > 0) {
      this.forgetInstalledVersions();
      try {
        const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
        for (const job of dropped) await store.forget(job.id);
      } catch (error) {
        console.error('StarHub dropping uninstalled records failed: ' + errorText(error));
      }
    }
  }

  private loadMoreApps(): void {
    if (!this.catalogHasMore() || this.catalogMoreError.length > 0) return;
    this.loadApps(false);
  }

  private prefetchCatalog(lastVisible: number): void {
    if (shouldPrefetchCatalog(this.apps.length, this.catalogTotal, this.catalogPage,
      Index.CATALOG_PAGE_SIZE, lastVisible, this.catalogLoading || this.catalogMoreBusy,
      this.catalogMoreError.length > 0)) this.loadMoreApps();
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

  /** 同查询、同图标修订只下载一次；翻页和重复刷新共用尚未完成的请求。 */
  private async loadCatalogIcons(client: StoreClient, apps: CatalogApp[], query: string,
    cacheable: boolean): Promise<void> {
    const records: CachedIcon[] = [];
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < apps.length && query === this.activeQuery) {
        const app = apps[cursor++];
        if (this.iconFor(app.id) !== undefined || app.iconRev.length === 0) continue;
        const key = app.id + ':' + app.iconRev + ':' + query;
        let load = this.catalogIconFlights.get(key);
        if (load === undefined) {
          load = this.loadAppIcon(client, app, query);
          this.catalogIconFlights.set(key, load);
          load.then(() => this.catalogIconFlights.delete(key));
        }
        const record = await load;
        if (record !== undefined) records.push(record);
      }
    };
    // 下载和 PixelMap 解码都限制为四路，避免一页的图标同时争抢滚动帧。
    await Promise.all([worker(), worker(), worker(), worker()]);
    if (!cacheable || query !== this.activeQuery) return;
    const current = records.filter((record: CachedIcon | undefined) =>
      record !== undefined && this.apps.some((app: CatalogApp) =>
        String(app.id) === record.id && app.iconRev === record.rev)) as CachedIcon[];
    if (current.length > 0) {
      await CatalogCache.saveIcons(getContext(this) as common.UIAbilityContext, current);
    }
  }

  private isCurrentCatalogIcon(app: CatalogApp, query: string): boolean {
    return query === this.activeQuery && this.apps.some((row: CatalogApp) =>
      row.id === app.id && row.iconRev === app.iconRev);
  }

  private async loadAppIcon(client: StoreClient, app: CatalogApp,
    query: string): Promise<CachedIcon | undefined> {
    try {
      if (app.iconRev.length === 0 || app.iconUrl.length === 0) return undefined;
      let bytes: ArrayBuffer | undefined;
      for (let attempt = 0; attempt < 2; attempt++) {
        if (!this.isCurrentCatalogIcon(app, query)) return undefined;
        try { bytes = await client.appIconBytes(app); }
        catch (_) { bytes = undefined; }
        if (bytes !== undefined) break;
      }
      if (bytes === undefined || !this.isCurrentCatalogIcon(app, query)) return undefined;
      const source = image.createImageSource(bytes);
      try {
        const pixels = await source.createPixelMap({ desiredSize: { width: 192, height: 192 } });
        if (!this.isCurrentCatalogIcon(app, query) ||
          this.appIcons.some((icon: AppIcon) => icon.id === app.id && icon.rev === app.iconRev)) {
          await pixels.release();
          return undefined;
        }
        const icon = new AppIcon();
        icon.id = app.id;
        icon.rev = app.iconRev;
        icon.pixels = pixels;
        this.appIcons = this.appIcons.filter((old: AppIcon) => old.id !== app.id).concat([icon]);
        if (CatalogCache.iconWithinLimit(bytes)) {
          const record = new CachedIcon();
          record.id = String(app.id);
          record.rev = app.iconRev;
          record.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
          return record;
        }
        return undefined;
      } finally {
        await source.release();
      }
    } catch (_) {
      return undefined;
    }
  }

  /**
   * 先用缓存把界面画出来。
   *
   * 缓存里的图标是上次存下的字节，直接解码成 PixelMap；解码失败的条目等
   * 后台刷新时再补。只缓存第一页，所以这里拿到的就是"上次干净的第一页"。
   */
  private async loadCatalogFromCache(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await ReleaseChannelRegistry.restore(context);
    const cached = await CatalogCache.load(context);
    if (cached.length === 0) return;
    // 期间已经拿到新数据就不要用旧数据覆盖
    if (this.apps.length > 0 || this.activeQuery.length > 0) return;
    this.apps = appendCatalogPage([], cached);
    this.catalogTotal = Math.max(this.catalogTotal, cached.length);
    this.refreshCatalogInstallState();
    this.catalogLoading = false;
    const icons = await CatalogCache.loadIcons(context, cached);
    icons.forEach((bytes: ArrayBuffer, id: number) => {
      try {
        const source = image.createImageSource(bytes);
        source.createPixelMap({ desiredSize: { width: 192, height: 192 } }).then((pixels: image.PixelMap) => {
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
        }).finally(() => source.release()).catch((e: Object) => {
        });
      } catch (e) {
      }
    });
  }

  private iconFor(id: number): image.PixelMap | undefined {
    return this.appIcons.find((entry: AppIcon) => entry.id === id)?.pixels;
  }

  private managementIconApps(): CatalogApp[] {
    const selected = new Map<number, CatalogApp>();
    for (const job of this.allInstalledJobs().concat(this.pendingJobs)) {
      const app = this.catalogForJob(job) ?? (job.appId > 0 ? this.catalogApp(job.appId) : undefined);
      if (app !== undefined) selected.set(app.id, app);
    }
    for (const app of this.myApps) selected.set(app.id, app);
    return Array.from(selected.values());
  }

  private managedIconFor(app: CatalogApp): image.PixelMap | undefined {
    const saved = this.managementIcons.find((icon: AppIcon) => icon.id === app.id);
    const visible = this.appIcons.find((icon: AppIcon) => icon.id === app.id);
    return (saved?.rev === app.iconRev ? saved?.pixels : undefined) ??
      (visible?.rev === app.iconRev ? visible?.pixels : undefined) ?? saved?.pixels;
  }

  private isCurrentManagementIcon(app: CatalogApp): boolean {
    return this.managementIconApps().some((row: CatalogApp) => row.id === app.id && row.iconRev === app.iconRev);
  }

  private async loadManagementIcon(client: StoreClient, app: CatalogApp): Promise<void> {
    if (app.iconRev.length === 0 || !this.isCurrentManagementIcon(app)) return;
    const existing = this.managementIcons.find((icon: AppIcon) => icon.id === app.id && icon.rev === app.iconRev);
    if (existing !== undefined) return;
    const shared = this.appIcons.find((icon: AppIcon) => icon.id === app.id && icon.rev === app.iconRev);
    if (shared !== undefined) {
      this.managementIcons = this.managementIcons.filter((icon: AppIcon) => icon.id !== app.id).concat([shared]);
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const cached = await CatalogCache.loadIcons(context, [app]);
    // 缓存损坏时继续尝试网络；失败时保留旧像素，下一次进入或刷新可重试。
    for (let attempt = 0; attempt < 3; attempt++) {
      if (!this.isCurrentManagementIcon(app)) return;
      try {
        const bytes = attempt === 0 ? cached.get(app.id) :
          (app.iconUrl.length > 0 ? await client.appIconBytes(app) : undefined);
        if (bytes === undefined) continue;
        const source = image.createImageSource(bytes);
        try {
          const pixels = await source.createPixelMap({ desiredSize: { width: 192, height: 192 } });
          if (!this.isCurrentManagementIcon(app)) { await pixels.release(); return; }
          const icon = new AppIcon(); icon.id = app.id; icon.rev = app.iconRev; icon.pixels = pixels;
          this.managementIcons = this.managementIcons.filter((old: AppIcon) => old.id !== app.id).concat([icon]);
          if (attempt > 0 && CatalogCache.iconWithinLimit(bytes)) {
            const record = new CachedIcon(); record.id = String(app.id); record.rev = app.iconRev;
            record.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
            await CatalogCache.saveIcons(context, [record]);
          }
          return;
        } finally { await source.release(); }
      } catch (_) {}
    }
  }

  private loadManagementIcons(): Promise<void> {
    if (this.managementIconBatchFlight !== undefined) {
      this.managementIconPending = true;
      return this.managementIconBatchFlight;
    }
    this.managementIconBatchFlight = this.runManagementIconBatches().finally(() => {
      this.managementIconBatchFlight = undefined;
    });
    return this.managementIconBatchFlight;
  }

  private async runManagementIconBatches(): Promise<void> {
    do {
      this.managementIconPending = false;
      const apps = this.managementIconApps();
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      let cursor = 0;
      const worker = async (): Promise<void> => {
        while (cursor < apps.length) {
          const app = apps[cursor++];
          const key = app.id + ':' + app.iconRev;
          let flight = this.managementIconFlights.get(key);
          if (flight === undefined) {
            flight = this.loadManagementIcon(client, app).catch(() => {});
            this.managementIconFlights.set(key, flight);
            flight.then(() => this.managementIconFlights.delete(key));
          }
          await flight;
        }
      };
      await Promise.all([worker(), worker(), worker(), worker()]);
    } while (this.managementIconPending);
  }

  private syncManagementIcons(): void {
    if (this.currentTab === Index.TAB_MANAGE) this.loadManagementIcons().catch(() => {});
  }

  /** 已安装条目的图标：商店应用用目录图标，本地 HAP 用包内图标。 */
  private jobIcon(job: InstallJob): image.PixelMap | undefined {
    const app = this.catalogForJob(job);
    return (app === undefined ? undefined : this.managedIconFor(app)) ??
      this.localIcons.find((entry: LocalIcon) => entry.jobId === job.id ||
        entry.jobId === 'device-' + job.bundleName)?.pixels;
  }

  /**
   * 从本地 HAP 里取出应用图标。
   *
   * 商店的图标来自服务器，本地导入的包没有这一层，只能读包内的
   * `resources/base/media/<app.icon>`。读不到就保持文字占位，不算错误。
   */
  private async loadLocalIcon(job: InstallJob): Promise<void> {
    if (this.localIcons.some((entry: LocalIcon) => entry.jobId === job.id)) return;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (job.cachePath.length > 0 && fileIo.accessSync(job.cachePath)) {
        const identity = await PackageArchive.inspect(job.cachePath);
        if (identity.displayName.length > 0) { const names = new Map(this.localAppNames); names.set(job.id, identity.displayName); this.localAppNames = names; }
      }
      let bytes = await InstalledIconCache.load(context, job.bundleName, job.versionCode);
      if (bytes === undefined && job.cachePath.length > 0 && fileIo.accessSync(job.cachePath)) {
        bytes = await PackageArchive.icon(job.cachePath);
        if (bytes !== undefined) await InstalledIconCache.save(context, job.bundleName, job.versionCode, bytes);
      }
      if (bytes === undefined) return;
      const source = image.createImageSource(bytes);
      try {
        const pixels = await source.createPixelMap({ desiredSize: { width: 192, height: 192 } });
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
      job.appId <= 0);
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
      case InstallStage.WAITING_CERTIFICATE: return '等待释放调试证书名额';
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
      const liveName = this.currentInstalledView(job).versionName;
      if (liveName.length > 0) return liveName;
    }
    if (job.versionName.length > 0) return job.versionName;
    // 旧记录（加 version_name 字段之前装的）没有版本名。直接显示 versionCode 会
    // 得到 2026092902 这种看着像日期的数字，所以依次退两步。
    const app = this.catalogForJob(job);
    if (app !== undefined) {
      const direct = this.assetForBundle(app, job.bundleName, job.assetName);
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
          this.installedAssets(app).some((asset: HapAsset) => asset.bundleName === job.bundleName)).length > 1;
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
    if (app && app.displayName.length > 0) {
      const asset = this.installedAssets(app).find((item: HapAsset) => item.bundleName === job.bundleName);
      return app.displayName + (/^HiCar[-_.]/i.test(asset?.name ?? job.assetName) ? ' · HiCar' : '');
    }
    if (job.bundleName === 'com.tonghongxiang.hapstore.nativepreview' ||
      job.bundleName === 'com.tonghongxiang.hapstore') return '轻启·安装器';
    const label = InstalledAppRegistry.displayName(job.bundleName);
    if (label.length > 0) return label;
    if (job.sourceUrl === 'device') return job.assetName || job.bundleName;
    if (job.sourceUrl === 'local' && this.localAppNames?.get(job.id)) return this.localAppNames.get(job.id) ?? '';
    if (job.sourceUrl === 'local' && job.bundleName.length > 0) {
      const parts = job.bundleName.split('.');
      return parts[parts.length - 1] + ' · 本地应用';
    }
    const name = job.assetName.replace(/\.hap$/i, '').replace(/[-_]/g, ' ');
    return name.length > 0 ? name : job.bundleName;
  }

  private localProfileTitle(bundleName: string): string {
    if (bundleName === 'com.tonghongxiang.hapstore' ||
      bundleName === 'com.tonghongxiang.hapstore.nativepreview') return '轻启·安装器';
    const app = this.apps.concat(this.myApps, this.updateCatalog).find((item: CatalogApp) =>
      item.latestAsset?.bundleName === bundleName ||
      item.latestAssets.some((asset: HapAsset) => asset.bundleName === bundleName));
    return app?.displayName || InstalledAppRegistry.displayName(bundleName) || bundleName;
  }

  private async loadMyApps(showProgress: boolean = false): Promise<void> {
    if (!this.signedIn) return;
    // 手动刷新复用正在进行的请求，进度始终占用标题右侧原有的固定位置。
    if (showProgress) this.myAppsRefreshing = true;
    if (this.myAppsBusy) return;
    this.myAppsBusy = true;
    try {
      const apps = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .myApps(this.account);
      if (JSON.stringify(apps) !== JSON.stringify(this.myApps)) this.myApps = apps;
      this.syncManagementIcons();
      this.myAppsLoaded = true;
      this.myAppsMessage = '';
    } catch (error) {
      this.myAppsMessage = errorText(error);
    } finally {
      this.myAppsBusy = false;
      this.myAppsRefreshing = false;
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
    const generation = ++this.submitGeneration;
    if (!this.signedIn) {
      this.submitMessage = '请先在「我的」登录华为开发者账号';
      return;
    }
    this.submitBusy = true;
    this.submitMessage = '正在检查安装包…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      // 上架前先刷新一次自己的上架列表，否则刚上架/刚删除的判断会用到旧数据。
      try { this.myApps = await new StoreClient(context).myApps(this.account); } catch (_) {}
      if (generation !== this.submitGeneration || !this.showSubmit) return;
      const draft = await new StoreClient(context).prepareSubmit(this.submitUrl.trim(), this.account);
      if (generation !== this.submitGeneration || !this.showSubmit) return;
      this.submitDraft = draft;
      const deadline = Date.now() + 300000;
      while (this.submitDraft.inspectionStatus !== 'ready') {
        this.submitMessage = '正在后台解压并检查 APP / HAP 清单…';
        await new Promise<void>((resolve) => setTimeout(resolve, 2000));
        if (generation !== this.submitGeneration || !this.showSubmit) return;
        if (Date.now() > deadline) throw new Error('安装包仍在后台检查，可稍后再次检查仓库');
        const status = await new StoreClient(context).submitStatus(this.submitDraft, this.account);
        if (generation !== this.submitGeneration || !this.showSubmit) return;
        this.submitDraft = status;
      }
      this.submitAssets = this.submitDraft.choices.length > 0 ? [this.submitDraft.choices[0].name] : [];
      const categories = this.submitDraft.categories;
      this.submitCategory = this.submitDraft.suggestedCategory;
      const index = categories.indexOf(this.submitCategory);
      this.submitCategoryIndex = index >= 0 ? index : 0;
      this.submitCategory = categories.length > 0 ? categories[this.submitCategoryIndex] : '';
      this.classifySubmitRepo(this.submitDraft);
      this.submitMessage = this.submitDraft.choices.length + ' 个安装包可选择，请确认上架内容';
    } catch (error) {
      if (generation !== this.submitGeneration || !this.showSubmit) return;
      this.submitDraft = new SubmitDraft();
      this.submitExisting = Index.SUBMIT_STATE_NEW;
      this.submitMessage = errorText(error);
    } finally {
      if (generation === this.submitGeneration) this.submitBusy = false;
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
        .confirmSubmit(this.submitDraft, this.submitAssets, this.submitCategory, this.account);
      const wasUpdate = this.submitExisting === Index.SUBMIT_STATE_MINE;
      this.animateOverlay(() => { this.showSubmit = false; });
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
          this.animateOverlay(() => { this.showAppConfig = false; });
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
    this.configSourceGeneration++;
    this.configSourceUrl = app.secondaryRepo.length > 0 ? 'https://github.com/' + app.secondaryRepo : '';
    this.configSourceExpanded = app.secondaryRepo.length > 0;
    this.configSourceDraft = new SubmitDraft();
    this.configSourceRemove = false;
    this.configSourceMessage = '';
    this.configSourceChecking = false;
    this.configMessage = '';
    this.configCategories = [];
    this.animateOverlay(() => { this.showAppConfig = true; });
    this.configBusy = true;
    try {
      this.configCategories = await new StoreClient(getContext(this) as common.UIAbilityContext).categories();
    } catch (error) { this.configMessage = errorText(error); }
    finally { this.configBusy = false; }
  }

  private async saveAppConfig(): Promise<void> {
    if (this.configBusy || !this.configCategories.includes(this.configCategory) ||
      (this.configSourceChanged() && this.configSourceDraft.token.length === 0 && !this.configSourceRemove)) return;
    this.configBusy = true;
    this.configMessage = '';
    try {
      const saved = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .configureMyApp(this.configApp.id, this.configCategory, this.account,
          this.configSourceDraft.token, this.configSourceRemove);
      if (saved.category !== this.configCategory) {
        throw new Error('服务器未保存所选分类，请重试');
      }
      if ((this.configSourceDraft.token.length > 0 && saved.secondaryRepo.toLowerCase() !==
          this.configSourceDraft.repo.toLowerCase()) || (this.configSourceRemove && saved.secondaryRepo.length > 0)) {
        throw new Error('服务器未保存子仓配置，请先更新服务端');
      }
      await ReleaseChannelRegistry.refreshTargets(getContext(this) as common.UIAbilityContext, [saved], true);
      // Keep both already-open lists in sync immediately. The subsequent fetch
      // also catches changes made from another device.
      this.myApps = this.myApps.map((app: CatalogApp) => app.id === saved.id ? saved : app);
      this.apps = this.apps.map((app: CatalogApp) => app.id === saved.id ? saved : app);
      this.animateOverlay(() => { this.showAppConfig = false; });
      await this.loadMyApps();
      await this.loadApps();
    } catch (error) { this.configMessage = errorText(error); }
    finally { this.configBusy = false; }
  }

  private configSourceChanged(): boolean {
    const original = this.configApp.secondaryRepo.length > 0 ?
      'https://github.com/' + this.configApp.secondaryRepo.toLowerCase() : '';
    return this.configSourceUrl.trim().replace(/\/+$/, '').toLowerCase() !== original;
  }

  private async checkAppSource(): Promise<void> {
    if (this.configBusy || this.configSourceUrl.trim().length === 0) return;
    const generation = ++this.configSourceGeneration;
    this.configBusy = true;
    this.configSourceChecking = true;
    this.configSourceDraft = new SubmitDraft();
    this.configSourceMessage = '正在检查子仓安装包…';
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      let draft = await client.prepareAppSource(this.configApp.id, this.configSourceUrl.trim(), this.account);
      const deadline = Date.now() + 300000;
      while (draft.inspectionStatus !== 'ready') {
        if (generation !== this.configSourceGeneration || !this.showAppConfig) return;
        this.configSourceMessage = '正在后台解析安装包并核验包名…';
        await new Promise<void>((resolve) => setTimeout(resolve, 2000));
        if (generation !== this.configSourceGeneration || !this.showAppConfig) return;
        if (Date.now() > deadline) throw new Error('检查仍在后台进行，请稍后再点检查');
        draft = await client.submitStatus(draft, this.account);
      }
      if (generation !== this.configSourceGeneration || !this.showAppConfig) return;
      const bundles = this.configApp.latestAssets.map((asset: HapAsset) => asset.bundleName);
      const matches = draft.choices.filter((choice: SubmitChoice) =>
        choice.bundleName.length > 0 && bundles.includes(choice.bundleName));
      if (matches.length === 0) throw new Error('子仓安装包与主仓包名不一致，无法关联');
      this.configSourceDraft = draft;
      this.configSourceRemove = false;
      this.configSourceMessage = '包名核验通过：' + matches.map((choice: SubmitChoice) =>
        choice.bundleName).filter((bundle: string, index: number, all: string[]) =>
        all.indexOf(bundle) === index).join('、') + '。保存后关联。';
    } catch (error) {
      if (generation === this.configSourceGeneration) this.configSourceMessage = errorText(error);
    } finally {
      if (generation === this.configSourceGeneration) {
        this.configBusy = false;
        this.configSourceChecking = false;
      }
    }
  }

  private async cancelInstall(job: InstallJob): Promise<void> {
    if (this.cancellingJobs.includes(job.id)) return;
    this.cancellingJobs = this.cancellingJobs.concat([job.id]);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await JobScheduler.cancel(context, await JobStore.open(context), job);
      if (this.resumeJobId === job.id) {
        this.resumeJobId = '';
        this.animateOverlay(() => { this.showReconnect = false; });
      }
      this.jobsError = '';
      await this.loadJobs();
      this.refreshCatalogInstallState();
      this.drainInstallQueue();
    } catch (error) { this.jobsError = errorText(error); }
    finally { this.cancellingJobs = this.cancellingJobs.filter((id: string) => id !== job.id); }
  }

  private latestVersionTag(app: CatalogApp): string {
    if (ReleaseChannelRegistry.apply(app).channelUnavailable) return '暂无预览版';
    const version = ReleaseChannelRegistry.apply(app).latestAsset?.versionName.trim() ?? '';
    if (version.length > 0) return /^v/i.test(version) ? version : 'v' + version;
    // 缺少解析版本时才回退 Release 名称，不把 versionCode 当可读版本号。
    return ReleaseChannelRegistry.apply(app).latestName.trim();
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
            job.lastError = '安装尚未完成，左滑卡片继续安装';
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
        job.lastError = '上次安装中断，左滑卡片继续安装';
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

  onPageHide(): void {
    this.pageVisible = false;
    // 路由缓存中的首页不跟随下载进度重绘；执行与队列仍由 Coordinator 持有。
    if (this.installSubscription >= 0) InstallTaskState.unsubscribe(this.installSubscription);
    this.installSubscription = -1;
    if (this.refreshConnectionWaiter !== undefined && !this.refreshOpeningSettings) {
      this.completeRefreshConnection(false);
      if (this.resumeJobId.length === 0) this.showReconnect = false;
    }
    InstallConfirmation.deactivate(this.confirmationSubscription);
    InstallReconnect.deactivate(this.reconnectSubscription);
  }

  private observeReconnect(): void {
    if (this.confirmationSubscription === -1) {
      this.confirmationSubscription = InstallConfirmation.subscribe((id: string) => {
        if (!id) return;
        JobStore.open(getContext(this) as common.UIAbilityContext).then(async (store: JobStore) => {
          const job = await store.get(id);
          if (!job || job.stage !== InstallStage.WAITING_CONFIRMATION ||
            !InstallConfirmation.isOwner(this.confirmationSubscription) || !InstallConfirmation.isRequested(id)) return;
          InstallConfirmation.clear(id);
          this.confirmDataLoss(job);
        }).catch(() => {});
      });
    }
    InstallConfirmation.activate(this.confirmationSubscription);
    if (this.reconnectSubscription === -1) {
      this.reconnectSubscription = InstallReconnect.subscribe((jobId: string) => {
        if (jobId.length > 0) {
          this.resumeJobId = jobId;
          this.reconnectMessage = '';
          this.animateOverlay(() => { this.showReconnect = true; });
        } else if (this.resumeJobId.length > 0) {
          this.animateOverlay(() => { this.showReconnect = false; });
        }
      });
    }
    InstallReconnect.activate(this.reconnectSubscription);
  }

  private observeInstallTasks(): void {
    if (this.installSubscription !== -1) return;
    this.installSubscription = InstallTaskState.subscribe((rows: InstallTaskSnapshot[]) => {
      this.installTasks = rows;
      const revision = InstallTaskState.jobRevision();
      if (this.installJobsRevision !== revision) {
        this.installJobsRevision = revision;
        this.pendingJobs = rows.map((row: InstallTaskSnapshot) => row.job).filter((job: InstallJob) =>
          job.stage !== InstallStage.INSTALLED && job.stage !== InstallStage.TERMINAL_ERROR)
          .sort((a: InstallJob, b: InstallJob) => this.queueTime(a) - this.queueTime(b));
      }
      const installed = rows.map((row: InstallTaskSnapshot) => row.job).filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLED);
      const previous = this.installedJobs.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',');
      const current = installed.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',');
      if (previous !== current) {
        this.installedJobs = installed;
        this.loadSigningExpiries();
        this.forgetInstalledVersions();
        this.refreshCatalogInstallState();
        this.checkInstalledUpdates();
      }
      if (this.queueRecoveryReady && this.signedIn && rows.some((row: InstallTaskSnapshot) =>
        row.job.stage === InstallStage.QUEUED) && !rows.some((row: InstallTaskSnapshot) => row.running)) {
        this.drainInstallQueue();
      }
    });
  }

  private taskForApp(appId: number, bundleName: string = ''): InstallTaskSnapshot | undefined {
    const active = InstallTaskState.activeForApp(this.installTasks, appId, bundleName);
    if (active !== undefined) return active;
    const app = this.catalogApp(appId);
    const asset = app === undefined ? undefined : (bundleName.length > 0 ?
      this.assetForBundle(app, bundleName) : app.latestAsset);
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

  private indicatorTask(appId: number, bundleName: string, jobId: string): InstallTaskSnapshot | undefined {
    return jobId.length > 0 ? this.installTasks.find((row: InstallTaskSnapshot) => row.job.id === jobId) :
      this.taskForApp(appId, bundleName);
  }

  private indicatorDeterminate(appId: number, bundleName: string, jobId: string): boolean {
    const row = this.indicatorTask(appId, bundleName, jobId);
    return row !== undefined && row.running && InstallTaskState.determinate(row);
  }

  private indicatorPercent(appId: number, bundleName: string, jobId: string): number {
    return this.indicatorTask(appId, bundleName, jobId)?.percent ?? 0;
  }

  private indicatorLabel(appId: number, bundleName: string, jobId: string): string {
    const row = this.indicatorTask(appId, bundleName, jobId);
    return row === undefined ? '准备' : InstallTaskState.compactLabel(row);
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

  private async loadJobs(): Promise<void> {
    try {
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      InstallTaskState.seed(await store.listAll());
      this.jobsError = '';
      this.syncLocalIcons();
      this.syncManagementIcons();
      this.refreshCatalogInstallState();
      this.checkInstalledUpdates();
      this.loadSigningExpiries();
    } catch (error) {
      this.jobsError = errorText(error);
    }
  }

  /** Display FIFO position using the original enqueue timestamp. */
  private queueTime(job: InstallJob): number {
    return job.stageHistory[0]?.at ?? job.updatedAt;
  }

  /** 只自动处理排队项；需要用户连接、确认或手动重试的任务保持原状态。 */
  private async drainInstallQueue(): Promise<void> {
    if (!this.queueRecoveryReady) return;
    await InstallCoordinator.recovered(getContext(this) as common.UIAbilityContext);
  }

  /** 以包名合并设备清单、商店识别与安装历史；明确已卸载的记录不参与展示。 */
  private allInstalledJobs(): InstallJob[] {
    const seen = new Set<string>();
    return this.recentInstalledJobs().concat(this.storeInstalled, this.deviceInstalled ?? [])
      .filter((job: InstallJob) => {
        if (job.bundleName.length === 0 || seen.has(job.bundleName) ||
          this.displayInstalledVersion(job.bundleName) === 0) return false;
        seen.add(job.bundleName);
        return true;
      })
      .map((job: InstallJob) => this.currentInstalledView(job));
  }

  private syncDeviceInstalled(): void {
    this.deviceInstalled = InstalledAppRegistry.sideloadedApps().map((app: InstalledDeviceApp) => {
      const job = new InstallJob();
      job.id = 'device-' + app.bundleName; job.bundleName = app.bundleName;
      job.assetName = app.displayName; job.sourceUrl = 'device';
      job.versionCode = app.versionCode; job.versionName = app.versionName;
      job.moduleName = app.moduleName; job.mainAbility = app.abilityName;
      job.stage = InstallStage.INSTALLED;
      return job;
    });
    for (const job of this.deviceInstalled) {
      const resource = InstalledAppRegistry.iconResource(job.bundleName);
      const key = job.bundleName + ':' + job.versionCode + ':' + (resource?.id ?? 0) + ':' +
        (resource?.moduleName ?? '');
      if (job.mainAbility.length === 0 || this.deviceIconRequested.has(key)) continue;
      this.deviceIconRequested.add(key);
      LocalBundles.installedIcon(getContext(this) as common.UIAbilityContext, job.bundleName,
        job.mainAbility).then((pixels: image.PixelMap | undefined) => {
        if (pixels === undefined) return;
        const icon = new LocalIcon(); icon.jobId = job.id; icon.pixels = pixels;
        this.localIcons = this.localIcons.filter((row: LocalIcon) => row.jobId !== job.id).concat([icon]);
      });
    }
  }

  /** 自动扫描只在管理页且已有链路时运行；手动核对可尝试保存端口，失败保留缓存。 */
  private scanDeviceInstalled(force: boolean = false): Promise<void> {
    if (this.deviceInventoryFlight !== undefined) return this.deviceInventoryFlight;
    if (!force && (!HdcDeviceBridge.deviceLinked() ||
      Date.now() - this.deviceInventoryAt < Index.VERSION_TTL_MS ||
      this.installTasks.some((task: InstallTaskSnapshot) => task.running))) return Promise.resolve();
    const context = getContext(this) as common.UIAbilityContext;
    const names = this.allInstalledJobs().map((job: InstallJob) => job.bundleName);
    this.deviceInventoryFlight = new HdcDeviceBridge(context).sideloadedApps(names).then(() => {
      this.deviceInventoryAt = Date.now();
      const display = new Map(this.installedDisplay);
      for (const name of names.concat(InstalledAppRegistry.sideloadedApps().map((app: InstalledDeviceApp) => app.bundleName))) {
        const version = InstalledAppRegistry.version(name);
        if (version < 0) continue;
        const row = new VersionCacheEntry(); row.version = version;
        row.versionName = InstalledAppRegistry.versionName(name, version); row.at = Date.now();
        display.set(name, row);
      }
      this.installedDisplay = display;
      this.syncDeviceInstalled();
      this.loadSigningExpiries();
      this.syncLocalIcons();
      this.refreshCatalogInstallState();
      if (force) this.syncMessage = '已核对本机侧载应用';
    }).catch((error: Object) => {
      if (force) this.syncMessage = '未能完成核对：' + errorText(error) + '，保留已知应用';
    }).finally(() => { this.deviceInventoryFlight = undefined; });
    return this.deviceInventoryFlight;
  }

  /** 主列表展示设备当前版本；安装历史原样保留，外部更新不改写旧记录。 */
  private currentInstalledView(job: InstallJob): InstallJob {
    const version = this.displayInstalledVersion(job.bundleName);
    if (version <= 0) return job;
    const observed = this.installedDisplay.get(job.bundleName);
    const versionName = (observed?.version === version ? observed.versionName : '') ||
      InstalledAppRegistry.versionName(job.bundleName, version);
    if (version === job.versionCode && (versionName.length === 0 ||
      versionName === job.versionName)) return job;
    const view = JSON.parse(JSON.stringify(job)) as InstallJob;
    view.versionCode = version;
    view.versionName = versionName.length > 0 ? versionName :
      (version === job.versionCode ? job.versionName : '');
    return view;
  }

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
   * 发现和管理共用细圆环；无法精确计量的阶段使用活动指示。
   */
  @Builder
  private taskIndicator(appId: number, bundleName: string, jobId: string,
    featured: boolean = false, size: number = 48) {
    // 用稳定任务 ID 读取实时快照，避免列表复用时保留旧进度。
    Stack({ alignContent: Alignment.Center }) {
      if (this.indicatorDeterminate(appId, bundleName, jobId)) {
        Progress({ value: this.indicatorPercent(appId, bundleName, jobId), total: 100, type: ProgressType.Ring })
          .width(size).height(size).color(featured ? '#FFFFFF' : this.colors().accent)
          .backgroundColor(featured ? '#38FFFFFF' : this.colors().border)
          .style({ strokeWidth: 2.5, enableSmoothEffect: true })
      } else {
        Progress({ value: 0, total: 100, type: ProgressType.Ring })
          .width(size).height(size).color(featured ? '#FFFFFF' : this.colors().accent)
          .backgroundColor(featured ? '#38FFFFFF' : this.colors().border)
          .style({ strokeWidth: 2.5, status: this.indicatorTask(appId, bundleName, jobId) === undefined ||
            this.indicatorTask(appId, bundleName, jobId)?.running ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING })
      }
      Text(this.indicatorLabel(appId, bundleName, jobId)).fontSize(11).fontWeight(FontWeight.Medium)
        .fontColor(featured ? '#FFFFFF' : this.colors().accent).maxLines(1)
    }.width(size).height(size)
  }

  @Builder
  private catalogCardAction(app: CatalogApp, featured: boolean = false) {
    Column() {
      if (this.taskPending(app.id, (app.latestAsset ?? this.installedAssets(app)[0])?.bundleName ?? '')) {
        Column() {
          this.taskIndicator(app.id, (app.latestAsset ?? this.installedAssets(app)[0])?.bundleName ?? '', '', featured)
        }.width(StoreLayout.cardActionWidth).padding({ top: 2, bottom: 2 })
          .onClick(() => { this.currentTab = Index.TAB_MANAGE; })
      } else if (this.enqueuingAppIds.includes(app.id)) {
        Column() { this.taskIndicator(app.id, (app.latestAsset ?? this.installedAssets(app)[0])?.bundleName ?? '', '', featured) }.width(StoreLayout.cardActionWidth)
      } else if (app.channelUnavailable) {
        Button('暂无预览版', { type: ButtonType.Normal }).width(StoreLayout.cardWideActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(12)
          .fontColor(featured ? '#DAE6FF' : this.colors().textTertiary)
          .backgroundColor(featured ? '#22FFFFFF' : this.colors().fill).borderRadius(StoreLayout.cardActionRadius).enabled(false)
      } else if (this.installedBundleOf(app.id).length > 0) {
        if (this.updateForApp(app.id) !== undefined) {
          Button('更新', { type: ButtonType.Normal })
            .width(StoreLayout.cardActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(13)
            .fontColor(featured ? '#25448A' : this.colors().onAccent)
            .backgroundColor(featured ? '#F0FFFFFF' : this.colors().accent).borderRadius(StoreLayout.cardActionRadius)
            .onClick(() => this.installFromCatalog(app))
        } else {
          Button('打开', { type: ButtonType.Normal })
            .width(StoreLayout.cardActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(13)
            .fontColor(featured ? '#25448A' : this.colors().accent)
            .backgroundColor(featured ? '#F0FFFFFF' : this.colors().accentSoft)
            .borderRadius(StoreLayout.cardActionRadius)
            .onClick(() => this.openCatalogApp(app))
        }
      } else if (!this.catalogInstallable(app.id)) {
        Button('查看', { type: ButtonType.Normal }).width(StoreLayout.cardActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(13)
          .fontColor(featured ? '#25448A' : this.colors().accent)
          .backgroundColor(featured ? '#F0FFFFFF' : this.colors().accentSoft).borderRadius(StoreLayout.cardActionRadius)
          .onClick(() => this.openDetail(app.id))
      } else if (this.installedVersionOf(app.id) < 0) {
        // 权限不足且无线调试未连接时，状态无法核实；不能让用户永远卡在检查按钮。
        // 允许先下载并准备任务，设备连接在真正需要授权/安装时再处理。
        Button('安装/更新', { type: ButtonType.Normal }).width(StoreLayout.cardWideActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(12)
          .fontColor(featured ? '#25448A' : this.colors().onAccent)
          .backgroundColor(featured ? '#F0FFFFFF' : this.colors().accent).borderRadius(StoreLayout.cardActionRadius)
          .onClick(() => this.installFromCatalog(app))
      } else {
        Button('安装', { type: ButtonType.Normal })
          .width(StoreLayout.cardActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(13)
          .fontColor(featured ? '#25448A' : this.colors().onAccent)
          .backgroundColor(featured ? '#F0FFFFFF' : this.colors().accent).borderRadius(StoreLayout.cardActionRadius)
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
    this.submitGeneration++;
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
    this.submitAssets = [];
    this.animateOverlay(() => { this.showSubmit = true; });
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
  private async installFromCatalog(app: CatalogApp, selected?: HapAsset): Promise<void> {
    if (this.enqueuingAppIds.includes(app.id) ||
      this.taskPending(app.id, selected?.bundleName ?? (app.latestAsset ?? this.installedAssets(app)[0])?.bundleName ?? '')) return;
    // ForEach 的点击闭包可能还持有上一轮卡片；与「更新」判断使用同一份当前目录。
    const asset = selected ?? this.catalogApp(app.id)?.latestAsset;
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
    const installedVersion = selected === undefined ? this.installedVersionOf(app.id) :
      LocalBundles.installedVersion(asset.bundleName);
    if (installedVersion >= asset.versionCode && asset.versionCode > 0) {
      this.checkInstalledUpdates();
      return;
    }
    this.enqueuingAppIds = this.enqueuingAppIds.concat([app.id]);
    this.jobsError = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const job = await store.enqueue(app.id, asset.name, asset.url, asset.sha256,
        asset.mirrorUrls, asset.versionName, asset.bundleName, asset.versionCode);
      if (job.stage === InstallStage.INSTALLED) {
        // Explicit reinstall after an external uninstall must re-enter the FIFO.
        job.stage = InstallStage.QUEUED; job.stageHistory = []; job.lastError = '';
        await store.save(job);
      }
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
  private refreshCatalogInstallState(rescanInstalled: boolean = false,
    addedApps?: CatalogApp[]): Promise<void> {
    const startedAt = Date.now();
    const next = addedApps === undefined ? new Map<number, number>() : new Map(this.installedVersions);
    const unresolved = new Set<string>();
    const versions = new Map<string, number>();
    const display = new Map(this.installedDisplay);
    let systemKnown = 0;
    const targets = addedApps === undefined ? this.updateApps() :
      addedApps.map((app: CatalogApp) => ReleaseChannelRegistry.apply(app));
    for (const app of targets) {
      const candidates = this.installedAssets(app);
      for (const candidate of candidates) {
        if (candidate.bundleName.length === 0 || versions.has(candidate.bundleName)) continue;
        const live = LocalBundles.liveInstalledVersion(candidate.bundleName);
        if (LocalBundles.isKnown(live)) systemKnown++;
        const version = LocalBundles.isKnown(live) ? live : InstalledAppRegistry.version(candidate.bundleName);
        versions.set(candidate.bundleName, version);
        if (LocalBundles.isKnown(version)) {
          const entry = new VersionCacheEntry(); entry.version = version; entry.at = Date.now();
          entry.versionName = version > 0 ? (LocalBundles.isKnown(live) ?
            LocalBundles.installedVersionName(candidate.bundleName, version) :
            InstalledAppRegistry.versionName(candidate.bundleName, version)) : '';
          display.set(candidate.bundleName, entry);
        }
        if (!LocalBundles.isKnown(live) && (rescanInstalled || !LocalBundles.isKnown(version))) {
          unresolved.add(candidate.bundleName);
        }
      }
      const asset = app.latestAsset ?? this.installedAssets(app)[0];
      if (asset === undefined || asset.bundleName.length === 0) continue;
      const version = versions.get(asset.bundleName) ?? -1;
      if (version > 0) {
        next.set(app.id, version);
        continue;
      }
      // 只有「确认没装」才能就此收手；「无法核实」需要退一步问设备。
      if (!LocalBundles.isKnown(version)) {
        next.set(app.id, this.installedVersions.get(app.id) ?? -1);
      } else {
        next.set(app.id, 0);
      }
    }
    this.installedDisplay = display;
    this.installedVersions = next;
    this.syncDetectedInstalled();
    this.checkInstalledUpdates();
    console.info('InstalledApps dispatch: unique=' + versions.size + ' systemKnown=' +
      systemKnown + ' wireless=' + unresolved.size + ' elapsedMs=' + (Date.now() - startedAt));
    if (unresolved.size > 0) return this.confirmCatalogVersionsViaDevice(Array.from(unresolved));
    this.updateInstallScanPrompt();
    return this.catalogProbeFlight ?? Promise.resolve();
  }

  /** 初次没有设备快照时，先识别外部侧载应用；用户仍可稍后连接并浏览目录。 */
  private updateInstallScanPrompt(): void {
    this.needsInstallScan = this.updateApps().some((app: CatalogApp) =>
      (app.latestAsset?.bundleName.length ?? 0) > 0 && this.installedVersionOf(app.id) < 0);
    if (!this.needsInstallScan || !this.updateCatalogReady || !this.accountChecked ||
      !this.signedIn || this.catalogProbeBusy || this.wirelessDebugRestoring || this.initialScanDismissed ||
      InstalledAppRegistry.hasCatalogSnapshot() || this.showReconnect || this.showSubmit ||
      this.showAppConfig || this.activeJobId.length > 0 || this.pendingJobs.length > 0) return;
    this.openInstallScan();
  }

  private openInstallScan(): void {
    if (this.reconnectBusy || this.catalogProbeBusy || this.wirelessDebugRestoring) return;
    this.initialScanDismissed = true;
    this.resumeJobId = '';
    this.reconnectMessage = '';
    this.animateOverlay(() => { this.showReconnect = true; });
  }

  /**
   * 系统查询被拒（权限不足）时，退一步问设备。
   *
   * HDC 的 `bm dump` 不需要任何权限，是这种情况下唯一可靠的来源。问到了就补进
   * `installedVersions`；问不到就什么都不做 —— 卡片宁可少显示一次「已安装」，
   * 也不能谎报「未安装」，那会让用户把已经装好的应用再装一遍。
   */
  @State private catalogProbeBusy: boolean = false;

  onWirelessLinkChanged(): void {
    if (!this.pageVisible || this.wirelessDebugRestoring) return;
    if (HdcDeviceBridge.deviceLinked()) {
      this.refreshCatalogInstallState(true);
      if (this.currentTab === Index.TAB_MANAGE) this.scanDeviceInstalled();
    }
    else this.updateInstallScanPrompt();
  }

  private confirmCatalogVersionsViaDevice(bundleNames: string[]): Promise<void> {
    if (this.catalogProbeFlight !== undefined) {
      // 共用同一个完成信号；新包加入下一批，已经在读的包不重复查询。
      const additional = bundleNames.filter((name: string) => !this.catalogProbeNames.includes(name));
      this.catalogProbePending = this.catalogProbePending.concat(additional)
        .filter((name: string, index: number, all: string[]) => all.indexOf(name) === index);
      return this.catalogProbeFlight;
    }
    if (bundleNames.length === 0) return Promise.resolve();
    this.catalogProbeBusy = true;
    this.catalogProbeFlight = this.runCatalogVersionProbes(bundleNames).finally(() => {
      this.catalogProbeBusy = false;
      this.catalogProbeNames = [];
      this.catalogProbeFlight = undefined;
      this.updateInstallScanPrompt();
    });
    return this.catalogProbeFlight;
  }

  /** 完成信号涵盖所有合并进来的批次，避免下拉在补查结束前收回。 */
  private async runCatalogVersionProbes(bundleNames: string[]): Promise<void> {
    let names = Array.from(new Set<string>(bundleNames));
    let scanVerified = true;
    const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
    while (names.length > 0) {
      this.catalogProbeNames = names;
      try {
        const versions = await bridge.installedBundleVersions(names, (_checked: number, _total: number,
          name: string = '', version: number = -1) => {
          if (name.length > 0 && version >= 0) this.applyDetectedCatalogVersion(name, version);
        });
        if (versions === undefined) {
          if (!HdcDeviceBridge.deviceLinked() && await this.waitForRefreshConnection()) continue;
          scanVerified = false;
        } else {
          const reconcileStartedAt = Date.now();
          await this.reconcileCatalogInstallState(names, versions);
          await this.reconcileDetectedJobs(versions);
          scanVerified = scanVerified && names.every((name: string) =>
            !versions.has(name) || (versions.get(name) ?? 0) > 0);
          console.info('InstalledApps reconcile: elapsedMs=' + (Date.now() - reconcileStartedAt));
          if (!HdcDeviceBridge.deviceLinked() && await this.waitForRefreshConnection()) continue;
        }
      } catch (_) {
        // 不可核实不等于未安装，保持最后一次已知状态。
        if (!HdcDeviceBridge.deviceLinked() && await this.waitForRefreshConnection()) continue;
        scanVerified = false;
      }
      if (this.catalogProbePending.length === 0 && scanVerified && this.updateCatalogReady &&
        this.updateApps().every((app: CatalogApp) =>
          (app.latestAsset?.bundleName.length ?? 0) === 0 || this.installedVersionOf(app.id) >= 0)) {
        try {
          await InstalledAppRegistry.markCatalogSnapshot(getContext(this) as common.UIAbilityContext);
        } catch (_) {
          // 落盘失败不阻塞页面，下次启动仍会重新核对。
        }
      }
      // 落盘期间也可能收到新包，必须在最后一个 await 后再取下一批。
      names = this.catalogProbePending;
      this.catalogProbePending = [];
    }
  }

  /** 批量识别已自动尝试保存端口；失败后由连接弹窗唤醒同一轮刷新。 */
  private waitForRefreshConnection(): Promise<boolean> {
    if (!this.catalogRefreshBusy || !this.pageVisible || this.catalogRefreshConnectionCancelled) {
      return Promise.resolve(false);
    }
    return new Promise<boolean>((resolve: (connected: boolean) => void) => {
      this.refreshConnectionWaiter = resolve;
      this.initialScanDismissed = true;
      if (!this.showReconnect && !this.showCertificatePrompt) this.resumeJobId = '';
      this.reconnectMessage = '自动重连未成功，连接后继续刷新';
      this.animateOverlay(() => { this.showReconnect = true; });
    });
  }

  private completeRefreshConnection(connected: boolean): void {
    const waiting = this.refreshConnectionWaiter;
    this.refreshConnectionWaiter = undefined;
    if (waiting !== undefined) {
      if (!connected) this.catalogRefreshConnectionCancelled = true;
      waiting(connected);
    }
  }

  private async openReconnectSettings(): Promise<void> {
    this.refreshOpeningSettings = this.refreshConnectionWaiter !== undefined;
    try {
      await new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).openWirelessSettings();
    } catch (error) {
      this.refreshOpeningSettings = false;
      this.reconnectMessage = errorText(error);
    }
  }

  private applyDetectedCatalogVersion(bundleName: string, version: number): void {
    const next = new Map(this.installedVersions);
    const display = new Map(this.installedDisplay);
    const entry = new VersionCacheEntry(); entry.version = version; entry.at = Date.now();
    entry.versionName = InstalledAppRegistry.versionName(bundleName, version);
    display.set(bundleName, entry); this.installedDisplay = display;
    let wasInstalled = false;
    for (const app of this.updateApps()) {
      if ((app.latestAsset ?? this.installedAssets(app)[0])?.bundleName === bundleName) {
        if ((next.get(app.id) ?? 0) > 0) wasInstalled = true;
        next.set(app.id, version);
      }
    }
    this.installedVersions = next;
    // 未安装包只需更新卡片；不要为每个缺席包重算整张管理列表。
    if (version > 0 || wasInstalled) {
      this.syncDetectedInstalled(bundleName);
      this.checkInstalledUpdates();
    }
  }

  /** 外部安装条目来自设备，而不是伪造一条本安装器的安装历史。 */
  private syncDetectedInstalled(bundleName: string = ''): void {
    const found: InstallJob[] = bundleName.length === 0 ? [] :
      this.storeInstalled.filter((job: InstallJob) => job.bundleName !== bundleName);
    const seen = new Set<string>();
    for (const app of this.updateApps()) {
      for (const asset of this.installedAssets(app)) {
        if (bundleName.length > 0 && asset.bundleName !== bundleName) continue;
        if (asset.bundleName.length === 0 || seen.has(asset.bundleName)) continue;
        const detected = this.displayInstalledVersion(asset.bundleName);
        const version = LocalBundles.isKnown(detected) ? detected :
          (app.latestAsset?.bundleName === asset.bundleName ? this.installedVersions.get(app.id) ?? -1 : -1);
        if (version <= 0) continue;
        seen.add(asset.bundleName);
        const job = new InstallJob();
        job.id = 'store-' + app.id + '-' + asset.bundleName;
        job.appId = app.id;
        job.bundleName = asset.bundleName;
        job.assetName = asset.name;
        job.versionCode = version;
        job.versionName = version === asset.versionCode ? asset.versionName : '';
        job.stage = InstallStage.INSTALLED;
        found.push(job);
      }
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
    return (this.updateCatalogReady ? this.updateCatalog : this.apps)
      .map((app: CatalogApp) => ReleaseChannelRegistry.apply(app));
  }

  private catalogApp(appId: number): CatalogApp | undefined {
    const management = (this.updateCatalogReady ? this.updateCatalog : this.apps)
      .find((app: CatalogApp) => app.id === appId);
    const visible = this.apps.find((app: CatalogApp) => app.id === appId);
    const app = management === undefined ? visible : visible === undefined ? management :
      ((visible.latestAsset?.versionCode ?? 0) > (management.latestAsset?.versionCode ?? 0) ? visible : management);
    return app === undefined ? undefined : ReleaseChannelRegistry.apply(app);
  }

  private installedAssets(app: CatalogApp): HapAsset[] {
    return app.knownAssets !== undefined && app.knownAssets.length > 0 ? app.knownAssets : this.latestAssets(app);
  }

  private latestAssets(app: CatalogApp): HapAsset[] {
    return app.latestAssets !== undefined && app.latestAssets.length > 0 ? app.latestAssets :
      (app.latestAsset !== undefined ? [app.latestAsset] : []);
  }

  private assetForBundle(app: CatalogApp, bundleName: string, preferredName: string = ''): HapAsset | undefined {
    const choices = this.latestAssets(app).filter((asset: HapAsset) => asset.bundleName === bundleName);
    const exact = choices.find((asset: HapAsset) => asset.name === preferredName);
    // Several variants may share a bundle name. A renamed file must not silently switch variants.
    if (exact !== undefined) return exact;
    return preferredName.length > 0 && choices.length > 1 ? undefined : choices[0];
  }

  /** 已有线上来源保持来源；纯本地安装仅在包名唯一匹配时自动关联。 */
  private catalogForJob(job: InstallJob): CatalogApp | undefined {
    if (job.bundleName.length === 0) return undefined;
    const matches = this.updateApps().filter((app: CatalogApp) =>
      this.installedAssets(app).some((asset: HapAsset) => asset.bundleName === job.bundleName));
    if (job.appId > 0) {
      const exact = matches.find((app: CatalogApp) => app.id === job.appId);
      if (exact !== undefined) return exact;
      // 来源已记录，但异步采集尚未补齐目录身份：仍属于商店安装，不能归到离线侧载。
      return this.updateApps().find((app: CatalogApp) => app.id === job.appId &&
        this.installedAssets(app).every((asset: HapAsset) => asset.bundleName.length === 0));
    }
    // 首屏只有部分目录，不能据此认定同包名来源唯一。
    return this.updateCatalogReady && matches.length === 1 ? matches[0] : undefined;
  }

  private featuredTier(stars: number): number {
    return stars >= 10000 ? 3 : stars >= 1000 ? 2 : stars > Index.STARRED_MIN_STARS ? 1 : 0;
  }

  private featuredColors(stars: number): Array<[string, number]> {
    const tier = this.featuredTier(stars);
    if (tier === 3) return [['#09152D', 0], ['#17365E', 0.58], ['#563968', 1]];
    if (tier === 2) return [['#302758', 0], ['#4E438C', 0.58], ['#604279', 1]];
    return [['#204BC0', 0], ['#3263D5', 0.58], ['#426BD3', 1]];
  }

  /**
   * 星级排序只在新页提交时执行，追加后保持已有卡片位置，避免分页造成滚动跳跃。
   */
  private displayApps(): CatalogApp[] {
    return this.apps.map((app: CatalogApp) => ReleaseChannelRegistry.apply(app));
  }

  private syncDiscoverRows(): void {
    this.discoverRows.update(this.displayApps());
    this.syncManagementRows();
  }

  private openJobDetails(job: InstallJob): void {
    const app = this.catalogForJob(job);
    if (job.stage === InstallStage.INSTALLED) {
      InstalledInspection.selectedIcon = this.jobIcon(job);
      const selection = InstalledInspection.selection(this.currentInstalledView(job), this.jobTitle(job), this.renewalAppId(job));
      router.pushUrl({ url: 'pages/InstalledDetail', params: { selection: JSON.stringify(selection) } });
    } else if (app !== undefined) router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
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
      if (JSON.stringify(collected) !== JSON.stringify(this.updateCatalog)) this.updateCatalog = collected;
      this.updateCatalogReady = true;
      this.updateCatalogError = '';
      ReleaseChannelRegistry.refreshTargets(getContext(this) as common.UIAbilityContext, collected);
      this.refreshCatalogInstallState();
      this.syncManagementIcons();
    } catch (error) {
      this.updateCatalogError = '更新检查未完成：' + errorText(error);
    } finally {
      this.updateCatalogBusy = false;
    }
  }

  /** 按真实包名关联本地安装，不能拿 appId=0 或显示名称当身份。 */
  private catalogBundleName(appId: number): string {
    const app = this.catalogApp(appId);
    const asset = app?.latestAsset ?? (app === undefined ? undefined : this.installedAssets(app)[0]);
    if (asset !== undefined && asset.bundleName.length > 0) return asset.bundleName;
    return CatalogInstallIdentity.bundle(appId, asset, this.allInstalledJobs());
  }

  private catalogInstallable(appId: number): boolean {
    const asset = this.catalogApp(appId)?.latestAsset;
    return asset !== undefined && asset.bundleName.length > 0 && asset.url.length > 0;
  }

  private installedVersionOf(appId: number): number {
    const bundleName = this.catalogBundleName(appId);
    if (bundleName.length === 0) return -1;
    const local = this.displayInstalledVersion(bundleName);
    if (LocalBundles.isKnown(local)) return local;
    const detected = this.installedVersions.get(appId);
    if (detected !== undefined && detected >= 0) return detected;
    const job = this.allInstalledJobs().find((item: InstallJob) => item.bundleName === bundleName);
    return job !== undefined ? job.versionCode : -1;
  }

  private installedBundleOf(appId: number): string {
    if (this.installedVersionOf(appId) <= 0) return '';
    return this.catalogBundleName(appId);
  }

  private installedJobFor(appId: number): InstallJob | undefined {
    const bundleName = this.installedBundleOf(appId);
    if (bundleName.length === 0) return undefined;
    return this.allInstalledJobs().find((item: InstallJob) =>
      item.bundleName === bundleName);
  }

  /** 本机版本落后于目录最新版本时给「更新」。 */
  private updateForApp(appId: number, bundleName: string = '', preferredName: string = ''): UpdateTarget | undefined {
    const app = this.catalogApp(appId);
    if (app === undefined) return undefined;
    const asset = bundleName.length > 0 ? this.assetForBundle(app, bundleName, preferredName) : app.latestAsset;
    if (asset === undefined) return undefined;
    const deviceVersion = this.displayInstalledVersion(asset.bundleName);
    const recorded = this.allInstalledJobs().find((job: InstallJob) => job.bundleName === asset.bundleName);
    const installed = LocalBundles.isKnown(deviceVersion) ? deviceVersion :
      (recorded?.versionCode ?? (bundleName.length === 0 ? this.installedVersionOf(appId) : -1));
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
      const target = this.updateForApp(app.id, job.bundleName, job.assetName);
      if (target !== undefined && !found.some((item: UpdateTarget) => item.bundleName === target.bundleName)) found.push(target);
    }
    this.updates = found;
  }

  private updateFor(bundleName: string): UpdateTarget | undefined {
    return this.updates.find((item: UpdateTarget) => item.bundleName === bundleName);
  }

  private installedActionLabel(job: InstallJob): string {
    if (this.uninstallingBundle === job.bundleName) return '卸载中';
    return this.updateFor(job.bundleName) !== undefined ? '更新' : '打开';
  }

  private managementVersion(job: InstallJob): string {
    const version = this.versionLabel(job);
    return version.length > 0 ? (/^v/i.test(version) ? version : 'v' + version) : '';
  }

  private renewalLabel(job: InstallJob): string {
    return InstalledSigningExpiry.label(this.signingExpiries.get(job.bundleName) ?? 0,
      this.signingExpiryEstimates.get(job.bundleName) ?? 0,
      job.installedUpdateTime || InstalledAppRegistry.installationTime(job.bundleName, job.versionCode) ||
        job.stageHistory.find((mark) => mark.stage === InstallStage.INSTALLED)?.at || job.updatedAt);
  }

  private renewalDeadline(job: InstallJob): number {
    return InstalledSigningExpiry.displayExpiry(this.signingExpiries.get(job.bundleName) ?? 0,
      this.signingExpiryEstimates.get(job.bundleName) ?? 0,
      job.installedUpdateTime || InstalledAppRegistry.installationTime(job.bundleName, job.versionCode) ||
        job.stageHistory.find((mark) => mark.stage === InstallStage.INSTALLED)?.at || job.updatedAt);
  }

  private renewalDueSoon(job: InstallJob): boolean {
    return InstalledSigningExpiry.dueSoon(this.signingExpiries.get(job.bundleName) ?? 0);
  }

  private async loadSigningExpiries(): Promise<void> {
    const token = ++this.expiryReadToken;
    const next = new Map<string, number>();
    const installed = this.allInstalledJobs();
    for (const job of installed) {
      const expiry = await InstalledSigningExpiry.read(job.bundleName, job.versionCode, this.installedJobs);
      if (token !== this.expiryReadToken) return;
      next.set(job.bundleName, expiry);
    }
    const unresolved = installed.filter((job: InstallJob) => !(next.get(job.bundleName) ?? 0));
    const materials = await InstalledSigningExpiry.estimateMaterials(getContext(this) as common.UIAbilityContext,
      unresolved.map((job: InstallJob) => job.bundleName));
    if (token !== this.expiryReadToken) return;
    const estimates = new Map<string, number>();
    for (const job of unresolved) estimates.set(job.bundleName,
      InstalledSigningExpiry.estimate(job.bundleName, job.versionCode, materials,
        job.installedUpdateTime || job.stageHistory.find((mark) => mark.stage === InstallStage.INSTALLED)?.at || job.updatedAt));
    if (JSON.stringify(Array.from(next.entries())) !== JSON.stringify(Array.from(this.signingExpiries.entries()))) {
      this.signingExpiries = next;
    }
    if (JSON.stringify(Array.from(estimates.entries())) !== JSON.stringify(Array.from(this.signingExpiryEstimates.entries()))) {
      this.signingExpiryEstimates = estimates;
    }
  }

  private renewalAppId(job: InstallJob): number {
    // An inspected successful online install remains a renewal source even
    // while the catalog's current package identity is missing or has changed.
    if (job.appId > 0 && /^https:\/\//.test(job.sourceUrl)) return job.appId;
    return this.catalogForJob(job)?.id ?? 0;
  }

  private renewInstalled(job: InstallJob): void {
    if (this.uninstallingBundle === job.bundleName) return;
    const pending = this.pendingRenewal(job.bundleName);
    if (pending !== undefined || this.renewalPreparing.includes(job.bundleName)) {
      this.openRenewal(job, pending?.appId ?? this.renewalAppId(job));
      return;
    }
    const appId = this.renewalAppId(job);
    if (appId <= 0) { this.openRenewal(job, 0); return; }
    AlertDialog.show({
      title: '选择续签方式',
      message: '商店自动续签会获取当前已安装版本的原包；也可以自行选择同包名、同版本的 HAP 或 APP。优先保留应用数据，无法保留时会另行确认。',
      buttons: [
        { value: '商店自动续签', action: () => this.openRenewal(job, appId) },
        { value: '自选 HAP 包续签', action: () => this.openRenewal(job, 0) },
        { value: '取消', action: () => {} }
      ]
    });
  }

  private openRenewal(job: InstallJob, appId: number): void {
    // The installed version may have changed while the confirmation was open.
    const current = this.allInstalledJobs().find((item: InstallJob) => item.bundleName === job.bundleName);
    if (current === undefined) { this.jobsError = '应用状态已变化，请刷新后重试'; return; }
    this.renewalTarget = current;
    this.renewalSourceAppId = appId;
    this.renewalExistingJobId = this.pendingRenewal(current.bundleName)?.id ?? '';
    this.showRenewal = true;
  }

  private pendingRenewal(bundle: string): InstallJob | undefined {
    return this.pendingJobs.find((job: InstallJob) => job.bundleName === bundle && job.renewalRequestedAt > 0);
  }

  private renewalButtonLabel(job: InstallJob): string {
    if (this.pendingRenewal(job.bundleName) !== undefined || this.renewalPreparing.includes(job.bundleName)) return '续签中';
    return this.renewalAppId(job) > 0 ? '续签' : '手动续签';
  }

  onBackPress(): boolean {
    if (this.showCertificatePrompt) { this.certificatePromptDismiss++; return true; }
    if (this.showLocalProfiles) {
      this.animateOverlay(() => { this.showLocalProfiles = false; });
      return true;
    }
    if (this.showCardActions) { this.dismissCardActions(-1); return true; }
    if (this.showCertSheet) {
      this.animateOverlay(() => { this.showCertSheet = false; });
      return true;
    }
    if (this.showReconnect) {
      if (!this.reconnectBusy) {
        this.completeRefreshConnection(false);
        InstallReconnect.clear(this.resumeJobId);
        this.animateOverlay(() => { this.showReconnect = false; });
      }
      return true;
    }
    if (this.showRenewal) { this.showRenewal = false; return true; }
    if (this.showSubmit) {
      if (!this.submitBusy || this.submitDraft.inspectionStatus !== 'ready') {
        this.submitGeneration++;
        this.animateOverlay(() => { this.showSubmit = false; });
      }
      return true;
    }
    if (this.showAppConfig) {
      if ((!this.configBusy || this.configSourceChecking) && this.removingId === 0) {
        this.configSourceGeneration++;
        this.configBusy = false; this.configSourceChecking = false;
        this.animateOverlay(() => { this.showAppConfig = false; });
      }
      return true;
    }
    return false;
  }

  private async performInstalledAction(job: InstallJob): Promise<void> {
    if (this.uninstallingBundle === job.bundleName) return;
    this.checkInstalledUpdates();
    const target = this.updateFor(job.bundleName);
    if (target !== undefined) await this.startUpdate(job, target);
    else await this.openInstalled(job);
  }

  /** 下载最新版本并接上安装链路。 */
  private async startUpdate(job: InstallJob, target: UpdateTarget): Promise<void> {
    const app = this.catalogApp(target.appId);
    if (app === undefined) {
      this.jobsError = '更新来源暂不可用，请刷新应用列表';
      return;
    }
    const asset = this.assetForBundle(app, target.bundleName, target.assetName);
    if (asset === undefined) {
      this.jobsError = '该安装包已变化，请刷新后重新选择';
      return;
    }
    await this.installFromCatalog(app, asset);
  }

  private updatableInstalledJobs(): InstallJob[] {
    return this.allInstalledJobs().filter((job: InstallJob) => {
      if (this.uninstallingBundle === job.bundleName) return false;
      const target = this.updateFor(job.bundleName);
      return target !== undefined && !this.taskPending(target.appId, job.bundleName);
    });
  }

  private async updateAllInstalled(): Promise<void> {
    if (this.bulkUpdating) return;
    this.checkInstalledUpdates();
    const jobs = this.updatableInstalledJobs();
    if (jobs.length === 0) return;
    if (!this.signedIn && jobs.some((job: InstallJob) => !LocalBundles.isSelfBundle(job.bundleName))) {
      this.jobsError = '请先登录华为开发者账号，再一键更新'; this.currentTab = Index.TAB_MINE;
      return;
    }
    this.bulkUpdating = true;
    const failures: string[] = [];
    try {
      for (const job of jobs) {
        const target = this.updateFor(job.bundleName);
        if (target === undefined || this.taskPending(target.appId, job.bundleName)) continue;
        this.jobsError = '';
        try { await this.startUpdate(job, target); }
        catch (error) { this.jobsError = errorText(error); }
        if (this.jobsError) failures.push(this.jobTitle(job) + '：' + this.jobsError);
      }
      this.jobsError = failures.join('；');
    } finally { this.bulkUpdating = false; }
  }

  private managementQueueJobs(): InstallJob[] {
    const rows = (this.installTasks ?? []).map((row: InstallTaskSnapshot) => row.job);
    // Cache eviction saves old completed records too; updatedAt is not a new installation attempt.
    const requestedAt = (job: InstallJob): number => job.renewalRequestedAt > 0 ?
      job.renewalRequestedAt : (job.stageHistory?.[0]?.at ?? job.updatedAt);
    const failed = rows.filter((job: InstallJob) => job.stage === InstallStage.TERMINAL_ERROR &&
      !rows.some((other: InstallJob) => other.id !== job.id && requestedAt(other) > requestedAt(job) &&
        (job.bundleName.length > 0 ? other.bundleName === job.bundleName :
          other.appId === job.appId && other.assetName === job.assetName)));
    return this.pendingJobs.concat(failed);
  }

  private queueActions(job: InstallJob): ManagementAction[] {
    const current = this.managementQueueJobs().find((row: InstallJob) => row.id === job.id);
    if (!current || this.cancellingJobs.includes(job.id)) return [];
    return ManagementActions.queue(current, this.signedIn, this.jobRunning(current.id), this.activeJobId);
  }

  private async showQueueActions(job: InstallJob, directKey: string = ''): Promise<void> {
    const live = this.managementQueueJobs().find((item: InstallJob) => item.id === job.id);
    if (live === undefined) return;
    job = live;
    const actions = this.queueActions(job);
    if (!actions.length) return;
    try {
      const key = directKey || actions[await this.showCardActionMenu(this.jobTitle(job),
        actions.map((action: ManagementAction) => action.label), actions.length - 1)]?.key || '';
      const current = this.managementQueueJobs().find((item: InstallJob) => item.id === job.id);
      if (current === undefined || !this.queueActions(current).some((action: ManagementAction) => action.key === key)) return;
      if (key === 'cleanup') await this.cancelInstall(current);
      else if (key === 'continue') await this.continueInstall(current);
      else if (key === 'renew') this.renewInstalled(current);
      else if (key === 'login') this.currentTab = Index.TAB_MINE;
      else if (key === 'details') {
        AlertDialog.show({ title: this.jobTitle(job),
          message: '版本 ' + this.versionLabel(job) + '\n' + this.taskJobLabel(job) +
            (job.lastError ? '\n' + job.lastError : ''),
          confirm: { value: '知道了', action: () => {} } });
      }
    } catch (_) { /* Dismissing the system action menu leaves the job unchanged. */ }
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

  private installedActions(job: InstallJob): ManagementAction[] {
    if (this.uninstallingBundle.length > 0 || !this.allInstalledJobs().some((row: InstallJob) => row.bundleName === job.bundleName)) return [];
    return ManagementActions.installed(this.renewalButtonLabel(job));
  }

  private async showInstalledActions(job: InstallJob, directKey: string = ''): Promise<void> {
    if (this.uninstallingBundle.length > 0 || !this.allInstalledJobs().some((row: InstallJob) =>
      row.bundleName === job.bundleName)) return;
    try {
      const actions = this.installedActions(job);
      const key = directKey || actions[await this.showCardActionMenu(this.jobTitle(job),
        actions.map((action: ManagementAction) => action.label), 1)]?.key || '';
      const current = this.allInstalledJobs().find((row: InstallJob) => row.bundleName === job.bundleName);
      if (current === undefined || !this.installedActions(current).some((action: ManagementAction) => action.key === key)) return;
      if (key === 'renew') { this.renewInstalled(current); return; }
      if (key !== 'uninstall') return;
      job = current;
      AlertDialog.show({ title: '卸载 ' + this.jobTitle(job) + '？',
        message: '应用的本地数据、缓存和登录状态也会被删除。',
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: { value: '卸载', action: () => { this.uninstallInstalled(job); } }
      });
    } catch (_) { /* Closing the action menu changes nothing. */ }
  }

  private showCardActionMenu(title: string, labels: string[], destructiveIndex: number): Promise<number> {
    this.dismissCardActions(-1);
    this.cardActionTitle = title;
    this.cardActionLabels = labels;
    this.cardDestructiveIndex = destructiveIndex;
    return new Promise<number>((resolve: (index: number) => void) => {
      this.cardActionResolver = resolve;
      this.animateOverlay(() => { this.showCardActions = true; });
    });
  }

  private dismissCardActions(index: number): void {
    const resolve = this.cardActionResolver;
    this.cardActionResolver = undefined;
    this.animateOverlay(() => { this.showCardActions = false; });
    resolve?.(index);
  }

  private async uninstallInstalled(job: InstallJob): Promise<void> {
    if (this.uninstallingBundle.length > 0) return;
    if (job.bundleName === 'com.tonghongxiang.hapstore') {
      promptAction.showToast({ message: '请在系统应用管理中卸载安装器' });
      return;
    }
    this.uninstallingBundle = job.bundleName;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const bridge = new HdcDeviceBridge(context);
      if (!await bridge.connected()) {
        const connected = await new Promise<boolean>((resolve) => {
          this.refreshConnectionWaiter = resolve;
          this.resumeJobId = '';
          this.reconnectMessage = '连接后继续卸载 ' + this.jobTitle(job);
          this.animateOverlay(() => { this.showReconnect = true; });
        });
        if (!connected) return;
      }
      const store = await JobStore.open(context);
      if ((await store.listPending()).some((pending: InstallJob) =>
        pending.bundleName === job.bundleName || pending.catalogBundleName === job.bundleName)) {
        throw new Error('请先取消该应用的安装或续签任务');
      }
      await bridge.uninstall(job.bundleName);
      // Only a confirmed system success becomes a durable absence. Histories
      // remain intact, and a failed/closed uninstall leaves every cache intact.
      InstalledAppRegistry.remember(job.bundleName, 0);
      this.applyDetectedCatalogVersion(job.bundleName, 0);
      this.syncDeviceInstalled();
      this.jobsError = '';
      try {
        await InstalledAppRegistry.persist(context);
      } catch (error) {
        this.jobsError = '应用已卸载，本地状态保存失败：' + errorText(error);
      }
      promptAction.showToast({ message: '已卸载 ' + this.jobTitle(job) });
    } catch (error) {
      this.jobsError = '卸载未完成：' + errorText(error);
    } finally { this.uninstallingBundle = ''; }
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
    const seen = new Set<string>();
    return this.installedJobs.filter((job: InstallJob) => {
      if (job.bundleName.length === 0) return true;
      if (seen.has(job.bundleName)) return false;
      seen.add(job.bundleName);
      return true;
    });
  }

  private managementInstalledJobs(localOnly: boolean = this.installedLocalOnly): InstallJob[] {
    // 构建一次索引，避免每张卡片重复投影整个目录、遍历所有待装任务。
    const catalogBundles = new Set<string>();
    for (const app of this.updateApps()) {
      for (const asset of this.installedAssets(app)) catalogBundles.add(asset.bundleName);
    }
    const pendingBundles = new Set<string>();
    const pendingApps = new Set<number>();
    for (const pending of this.pendingJobs) {
      if (pending.renewalRequestedAt > 0) continue;
      if (pending.bundleName.length > 0) pendingBundles.add(pending.bundleName);
      if (pending.catalogBundleName.length > 0) pendingBundles.add(pending.catalogBundleName);
      if (pending.bundleName.length === 0 && pending.catalogBundleName.length === 0 && pending.appId > 0) {
        pendingApps.add(pending.appId);
      }
    }
    const installed = this.allInstalledJobs().filter((installed: InstallJob) =>
      localOnly !== catalogBundles.has(installed.bundleName) &&
      !pendingBundles.has(installed.bundleName) && !pendingApps.has(installed.appId));
    // Read each cached deadline once. Sorting never queries the device or AGC.
    const deadlines = new Map<string, number>();
    const updatable = new Set<string>();
    for (const job of installed) {
      deadlines.set(job.bundleName, this.renewalDeadline(job));
      if (this.updateFor(job.bundleName) !== undefined) updatable.add(job.bundleName);
    }
    return installed.sort((a: InstallJob, b: InstallJob) => Number(updatable.has(b.bundleName)) -
      Number(updatable.has(a.bundleName)) ||
      (deadlines.get(a.bundleName) ?? 0) - (deadlines.get(b.bundleName) ?? 0));
  }

  private syncManagementRows(): void {
    if (this.managementRowsTimer !== -1) return;
    this.managementRowsTimer = setTimeout(() => {
      this.managementRowsTimer = -1;
      this.queueRows.update(this.managementQueueJobs());
      this.onlineInstalledRows.update(this.managementInstalledJobs(false));
      this.offlineInstalledRows.update(this.managementInstalledJobs(true));
      this.publishedRows.update(this.myApps);
      this.queueRowCount = this.queueRows.totalCount();
      this.onlineInstalledCount = this.onlineInstalledRows.totalCount();
      this.offlineInstalledCount = this.offlineInstalledRows.totalCount();
    }, 0);
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

  /** 核对完整侧载清单；不把展示条目写成伪安装历史，离线保留上次观察。 */
  private async refreshInstalled(): Promise<void> {
    if (this.syncBusy) return;
    this.syncBusy = true;
    this.syncMessage = '';
    try { await this.scanDeviceInstalled(true); }
    finally { this.syncBusy = false; }
  }

  private async recoverDownloads(): Promise<void> {
    try {
      await InstallCoordinator.recovered(getContext(this) as common.UIAbilityContext);
      await this.loadJobs();
    } catch (_) {
      // Persisted errors remain available in Management.
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
      const result = await InstallCoordinator.run(context, job.id);
      if (result.stage === InstallStage.WAITING_DEVICE) {
        this.reconnectMessage = '';
        InstallReconnect.request(job.id);
      } else if (result.stage === InstallStage.WAITING_ACCOUNT) {
        this.jobsError = '请先在「我的」登录华为开发者账号';
      } else if (result.stage === InstallStage.WAITING_CONFIRMATION) {
        InstallConfirmation.request(result.id);
      } else if (result.stage === InstallStage.INSTALLED) {
        installed = true;
        this.jobsError = '';
      } else {
        this.jobsError = result.lastError;
      }
    } catch (error) {
      if (String(error).includes('安装任务已取消')) return;
      // 超时只结束了「等待」，旧执行还在收尾（锁没放）。把这件事说出来，
      // 否则用户立刻点重试会收到「正在执行」，看起来像卡住了。
      const suffix = JobScheduler.stillFinishing(job.id) ?
        '（本次执行仍在后台收尾，请等它结束后再重试）' : '';
      this.jobsError = errorText(error) + suffix;
    } finally {
      if (this.activeJobId === job.id) this.activeJobId = '';
      await this.loadJobs();
      if (installed) this.drainInstallQueue();
    }
  }

  private confirmDataLoss(job: InstallJob): void {
    const renewal = job.renewalRequestedAt > 0;
    AlertDialog.show({
      title: InstallConfirmation.dataLossTitle(renewal),
      message: InstallConfirmation.dataLossMessage(renewal, LocalBundles.isSelfBundle(job.bundleName)),
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: InstallConfirmation.dataLossAction(renewal), action: async () => {
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

  onReconnectVisibilityChanged(): void {
    if (!this.showReconnect || this.reconnectPort.length > 0) return;
    new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).savedPort().then((port: number) => {
      // 异步读取期间用户已经输入时，不覆盖输入。
      if (this.showReconnect && this.reconnectPort.length === 0 && port >= 1024 && port <= 65535) {
        this.reconnectPort = String(port);
      }
    }).catch(() => {});
  }

  private async reconnect(): Promise<void> {
    this.reconnectBusy = true;
    this.reconnectMessage = '正在连接，请在系统弹窗中信任本机';
    try {
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      if (!await bridge.connect(Number(this.reconnectPort.trim()))) {
        this.reconnectMessage = bridge.connectionFailureMessage();
        return;
      }
      this.animateOverlay(() => { this.showReconnect = false; });
      this.reconnectMessage = '';
      this.deviceConnected = true;
      this.forgetInstalledVersions();
      this.completeRefreshConnection(true);
      // 先读取完整目录对应的实际安装状态，再判断是否还要继续先前的安装。
      await this.refreshCatalogInstallState(true);
      InstallReconnect.clear(this.resumeJobId);
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      const job = await store.get(this.resumeJobId);
      if (job && job.stage !== InstallStage.INSTALLED) await this.continueInstall(job);
      InstallCoordinator.conditionReady(getContext(this) as common.UIAbilityContext, InstallStage.WAITING_DEVICE);
    } catch (error) {
      this.reconnectMessage = errorText(error);
    } finally {
      this.reconnectBusy = false;
    }
  }

  @Builder
  private heading(title: string, subtitle: string = '', horizontalInset: number = this.pageInset()) {
    Column({ space: 3 }) {
      Text(title).fontSize(29).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
      if (subtitle.length > 0) {
        Text(subtitle).fontSize(12).fontColor(this.colors().textSecondary)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: horizontalInset, right: horizontalInset, top: 20 + this.statusBarInset, bottom: 16 })
  }

  @Builder
  private discoverSearchInput() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17)
        .fontColor([this.colors().textSecondary])
      TextInput({ placeholder: '搜索应用名或仓库', text: this.searchText })
        .layoutWeight(1).height(44).fontSize(14)
        .fontColor(this.colors().text).placeholderColor(this.colors().textSecondary)
        .backgroundColor('#00000000').caretColor(this.colors().accent)
        .padding({ left: 0, right: 0 })
        .onChange((value: string) => this.onSearchInput(value))
        .onSubmit(() => this.applySearch())
      if (this.searchText.length > 0) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14)
            .fontColor([this.colors().textSecondary])
        }.width(44).height(44).backgroundColor('#00000000')
          .accessibilityText('清除搜索')
          .onClick(() => this.clearSearch())
      }
    }.width('100%').height(46).padding({ left: 13, right: 7 })
      .backgroundColor('#00000000')
  }

  private discoverTitleBarStyle(): TitleBarStyleOptions {
    return this.scrollTitleBarStyle(this.discoverTitleHeight);
  }

  private scrollTitleBarStyle(titleHeight: number): TitleBarStyleOptions {
    return StoreTopStyle.navigationStyle(titleHeight, this.statusBarInset, this.darkMode);
  }

  @Builder
  private discoverTitleBarFrame() {
    // 模糊由 HDS 标题栏执行；搜索框在其上层保持同一个输入组件，滚动不丢焦点。
    Row().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
  }

  @Builder
  private silentRefreshHeader() {
    Row().width('100%').height(0).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private discoverPage() {
    Stack({ alignContent: Alignment.Top }) {
      HdsNavigation() {
        this.discoverList()
      }.titleBar({
        style: this.discoverTitleBarStyle(),
        avoidLayoutSafeArea: true,
        content: { stackBuilder: () => this.discoverTitleBarFrame(), divider: { showType: DividerShowType.OFF } }
      }).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack).hideBackButton(true)
        .systemBarStyle({ statusBarContentColor: this.colors().text }, { statusBarContentColor: this.colors().text })
        .bindToScrollable([this.discoverScroller])
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
        .width('100%').height('100%')
      DiscoverRefreshIndicator({ motion: this.discoverMotion, refreshing: this.catalogRefreshing,
        statusInset: this.statusBarInset, titleHeight: this.discoverTitleHeight })
      DiscoverHeader({ motion: this.discoverMotion, darkMode: this.darkMode,
        active: this.pageVisible && this.currentTab === Index.TAB_DISCOVER && this.signedIn &&
          !this.showRenewal && !this.showAppConfig && !this.showSubmit && !this.showReconnect && !this.showCertificatePrompt && !this.showCertSheet &&
          !this.showCardActions && !this.showLocalProfiles,
        statusInset: this.statusBarInset, inset: this.pageInset(), titleHeight: this.discoverTitleHeight,
        onTitleSize: (height: number): void => {
          // 收起时子组件会受裁切视口约束；不能把此时的高度保存成标题自然高度。
          if (this.discoverMotion.scrollOffset === 0 && Number.isFinite(height) && height > 0 &&
            Math.abs(height - this.discoverTitleHeight) > 0.5) {
            this.discoverTitleHeight = height;
          }
        }, searchContent: (): void => this.discoverSearchInput() })
      if (this.discoverShowTop && this.pageVisible && this.currentTab === Index.TAB_DISCOVER) {
        ForEach([this.topActionEpoch], (_epoch: number) => {
          DiscoverTopAction({ darkMode: this.darkMode, inset: this.pageInset(),
            action: () => this.backToDiscoverTop() })
            .position({ left: 0, bottom: 116 })
            .hitTestBehavior(HitTestMode.None)
        }, (epoch: number) => String(epoch))
      }
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private discoverList() {
    Column() {
      // Refresh 保持稳定，标题和搜索组件位于其外部。
      // 加载态与错误态改为列表项，列表本身始终存在。
      Refresh({ refreshing: $$this.catalogRefreshing, builder: this.silentRefreshHeader }) {
        List({ space: 0, scroller: this.discoverScroller }) {
            // 占位随列表滚出；实际标题和搜索框在 Refresh 外，下拉时保持原位。
            ListItem() {
              Row().width('100%').height(this.discoverTitleHeight + 70)
                .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
            }
            if (this.activeQuery.length > 0) {
              ListItem() {
                Text('搜索「' + this.activeQuery + '」· ' + this.catalogTotal + ' 个结果')
                  .fontSize(11).fontColor(this.colors().textTertiary)
                  .width('100%').maxLines(1)
                  .padding({ bottom: 8 })
              }.width('100%').padding({ left: this.pageInset(), right: this.pageInset() })
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
            LazyForEach(this.discoverRows, (app: CatalogApp) => {
              ListItem() {
                Column() {
                  if (app.stars > 100) {
                  Stack({ alignContent: Alignment.TopStart }) {
                    // 每张卡有自己的画布，分页/列表复用时不会只剩第一张有星点。
                    FeaturedCardStars({ appId: app.id, tier: this.featuredTier(app.stars),
                      cardHeight: this.featuredHeights.get(app.id) ?? 92 })
                    Row({ space: 14 }) {
                      if (this.iconFor(app.id)) {
                        Image(this.iconFor(app.id)).width(62).height(62).borderRadius(17)
                          .onClick(() => this.openDetail(app.id))
                      } else {
                        Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                          .fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                          .width(62).height(62).textAlign(TextAlign.Center)
                          .backgroundColor(this.colors().surface).borderRadius(17)
                          .onClick(() => this.openDetail(app.id))
                      }
                      Column({ space: 5 }) {
                        CatalogAppTitle({ title: app.displayName, version: this.latestVersionTag(app),
                          color: '#FFFFFF', versionColor: this.featuredColors(app.stars)[0][0],
                          versionBackground: '#FFFFFF', active: this.pageVisible && this.currentTab === 0 })
                        Text(app.summary).fontSize(12)
                          .fontColor('#E5ECFF').maxLines(1)
                        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
                          space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(5) } }) {
                          Text(app.category).fontSize(11).fontWeight(FontWeight.Medium)
                            .fontColor('#FFFFFF')
                            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                            .backgroundColor('#32FFFFFF').borderRadius(6)
                          RepositoryStats({ stars: app.stars, downloads: app.githubDownloads,
                            color: this.featuredTier(app.stars) >= 2 ? '#FFE4A8' : '#FFFFFF',
                            tagBackground: '#20FFFFFF' })
                        }
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        .onClick(() => this.openDetail(app.id))
                      this.catalogCardAction(app, true)
                    }.width('100%').padding(15).alignItems(VerticalAlign.Center)
                      .onSizeChange((_oldSize: SizeOptions, size: SizeOptions) => {
                        this.rememberFeaturedHeight(app.id, Number(size.height));
                      })
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
                            .onClick(() => this.openDetail(app.id))
                        } else {
                          Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                            .fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                            .width(62).height(62).textAlign(TextAlign.Center)
                            .backgroundColor(this.colors().accentSoft).borderRadius(17)
                            .onClick(() => this.openDetail(app.id))
                        }
                        Column({ space: 5 }) {
                          CatalogAppTitle({ title: app.displayName, version: this.latestVersionTag(app),
                            color: this.colors().text, versionColor: this.colors().surface,
                            versionBackground: this.colors().text, active: this.pageVisible && this.currentTab === 0 })
                          Text(app.summary).fontSize(12).fontColor(this.colors().textSecondary).maxLines(1)
                          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
                            space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(5) } }) {
                            Text(app.category).fontSize(11).fontColor(this.colors().accent)
                              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                              .backgroundColor(this.colors().accentSoft).borderRadius(6)
                            RepositoryStats({ stars: app.stars, downloads: app.githubDownloads,
                              color: this.colors().textSecondary, tagBackground: this.colors().accentSoft })
                          }
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                          .onClick(() => this.openDetail(app.id))
                        this.catalogCardAction(app)
                      }.width('100%').padding(15)
                    }.width('100%').backgroundColor(this.colors().surface).borderRadius(19)
                      .margin({ bottom: 10 })
                  }
                }.width('100%').constraintSize({ maxWidth: StoreLayout.contentWidth + this.pageInset() * 2 })
                  .align(Alignment.Top).padding({ left: this.pageInset(), right: this.pageInset() })
              }
            }, (app: CatalogApp) => this.discoverRows.key(app))
            // 接近页尾预取；固定高度的尾项避免加载状态切换改变滚动范围。
            if (this.catalogPage * Index.CATALOG_PAGE_SIZE < this.catalogTotal) {
              ListItem() {
                Row({ space: 9 }) {
                  if (this.catalogMoreError.length > 0) {
                    Text('加载未完成，点击重试').fontSize(12).fontColor(this.colors().accent)
                      .onClick(() => { this.catalogMoreError = ''; this.loadMoreApps(); })
                  } else if (this.catalogMoreBusy) {
                    LoadingProgress().width(16).height(16)
                    Text('加载中…').fontSize(12).fontColor(this.colors().textSecondary)
                  }
                }.width('100%').height(48).justifyContent(FlexAlign.Center)
              }
            }
            // 底部留白给悬浮的导航条让位。用列表项而不是列表内边距：内边距会挤在
            // 滚动区里、内容不满一屏时看着像一块空白，列表项则跟着内容走。
            ListItem() {
              Row().width('100%').height(110)
            }
        }.width('100%')
          .cachedCount(4)
          // 留白属于滚动内容；列表视口一直延伸到透明状态栏下。
          .contentStartOffset(this.statusBarInset)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .onDidScroll(() => this.syncDiscoverScroll())
          .onScrollIndex((_start: number, end: number) => this.prefetchCatalog(end))
          .onReachStart(() => this.revealDiscoverTop())
          .onReachEnd(() => this.loadMoreApps())
        }
        // 下拉容器撑满列表视口，顶部仅保留不响应触摸的占位。
        .width('100%').layoutWeight(1)
        .pullToRefresh(this.discoverCanRefresh)
        .onOffsetChange((offset: number) => this.discoverMotion.pull(offset))
        .onRefreshing(() => this.pullRefreshCatalog())
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private localToolCard(tool:LocalTool) {
    Column({space:10}) {
      SymbolGlyph(tool.symbol).fontSize(27).fontColor([this.colors().accent])
      Text(tool.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.colors().text).textAlign(TextAlign.Center)
      Text(tool.detail).fontSize(11).fontColor(this.colors().textSecondary).maxLines(2).textAlign(TextAlign.Center)
      Text(tool.formats).fontSize(10).fontColor(this.colors().textTertiary)
    }.width('100%').height(160).padding(18).alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors().surface).borderRadius(20).id(tool.id)
      .onClick(()=>router.pushUrl({url:tool.page}))
  }

  @Builder
  private localPage() {
    HdsNavigation() {
    Scroll(this.localScroller) {
      Column() {
        Grid(){ForEach(LocalTools,(tool:LocalTool)=>{GridItem(){this.localToolCard(tool)}},(tool:LocalTool)=>tool.id)}
          .columnsTemplate('1fr 1fr').columnsGap(12).rowsGap(12).height(Math.ceil(LocalTools.length/2)*172)
      }.width('100%').constraintSize({maxWidth:StoreLayout.contentWidth+this.pageInset()*2})
        .padding({left:this.pageInset(),right:this.pageInset(),top:this.statusBarInset+72,bottom:110}).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top).backgroundColor(this.colors().bg)
    }.titleBar({style:this.scrollTitleBarStyle(56),avoidLayoutSafeArea:true,
      content:{stackBuilder:()=>this.simpleTitleBar('本地'),divider:{showType:DividerShowType.OFF}}
    }).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack).hideBackButton(true)
      .systemBarStyle({statusBarContentColor:this.colors().text},{statusBarContentColor:this.colors().text})
      .bindToScrollable([this.localScroller])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.BOTTOM])
      .width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private managePage() {
    HdsNavigation() {
      this.managementList()
    }.titleBar({ style: this.scrollTitleBarStyle(56), avoidLayoutSafeArea: true,
      content: { stackBuilder: () => this.managementTitleBar(), divider: { showType: DividerShowType.OFF } }
    }).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack).hideBackButton(true)
      .systemBarStyle({ statusBarContentColor: this.colors().text }, { statusBarContentColor: this.colors().text })
      .bindToScrollable([this.managementScroller])
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private managementTitleBar() {
    this.simpleTitleBar('管理')
  }

  @Builder
  private simpleTitleBar(title: string) {
    Row() {
      Text(title).fontSize(30).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
    }.width('100%').height('100%').padding({ left: this.pageInset(), right: this.pageInset() })
      .alignItems(VerticalAlign.Center).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private installedSourceOption(label: string, localOnly: boolean) {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 4 }) {
        if (this.installedLocalOnly === localOnly) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(10).fontColor([this.colors().accent])
        }
        Text(label + ' ' + (localOnly ? this.offlineInstalledCount : this.onlineInstalledCount)).fontSize(12)
          .fontWeight(this.installedLocalOnly === localOnly ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.installedLocalOnly === localOnly ? this.colors().accent : this.colors().textSecondary)
          .maxLines(1)
      }.justifyContent(FlexAlign.Center)
    }.layoutWeight(1).height(28).padding({ left: 4, right: 4 })
      .backgroundColor(this.installedLocalOnly === localOnly ? this.colors().surface : Color.Transparent)
      .borderRadius(14).clip(true)
      .border({ width: this.installedLocalOnly === localOnly ? 1 : 0, color: this.colors().borderStrong, radius: 14 })
      .responseRegion({ x: 0, y: -8, width: '100%', height: 44 })
      .accessibilityText(label + (this.installedLocalOnly === localOnly ? '，已选中' : '，点击切换'))
      .onClick(() => { this.installedLocalOnly = localOnly; this.scanDeviceInstalled(); })
  }

  @Builder
  private installedSourceSelector() {
    Row({ space: 2 }) {
      this.installedSourceOption('商店应用', false)
      this.installedSourceOption('本地侧载', true)
    }.width(238).height(36).padding(4).backgroundColor(this.colors().fill).borderRadius(18).clip(true)
      .border({ width: 1, color: this.colors().border, radius: 18 })
  }

  @Builder
  private cardSwipeActions(actions: ManagementAction[], owner: string, select: (key: string) => void) {
    Row({ space: 8 }) {
      ForEach(actions, (action: ManagementAction) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 7 }) {
            SymbolGlyph(this.cardSwipeSymbol(action.key)).fontSize(20)
              .fontColor([action.destructive ? this.colors().onAccent : this.colors().accent])
            Text(action.shortLabel).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(action.destructive ? this.colors().onAccent : this.colors().accent)
          }.justifyContent(FlexAlign.Center)
        }.width(64).height('100%').padding(0)
          .backgroundColor(action.destructive ? this.colors().danger : this.colors().accentSoft)
          .borderRadius(16).accessibilityText(action.label).id('card-swipe-' + owner + '-' + action.key)
          .onClick(() => select(action.key))
      }, (action: ManagementAction) => action.key)
    }.height('100%').padding({ left: 8 })
  }

  private cardSwipeSymbol(key: string): Resource {
    if (key === 'cleanup' || key === 'uninstall') return $r('sys.symbol.trash');
    if (key === 'renew') return $r('sys.symbol.arrow_clockwise');
    if (key === 'login') return $r('sys.symbol.person');
    if (key === 'continue') return $r('sys.symbol.play_fill');
    return $r('sys.symbol.info_circle');
  }

  @Builder
  private managementInstalledCards(rows: ListDataSource<InstallJob>) {
    LazyForEach(rows, (job: InstallJob) => {
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
              CatalogAppTitle({ title: this.jobTitle(job), version: this.managementVersion(job),
                color: this.colors().text, versionColor: this.colors().surface,
                versionBackground: this.colors().text, active: this.pageVisible && this.currentTab === Index.TAB_MANAGE })
              Row({ space: 5 }) {
                Text(this.renewalLabel(job)).fontSize(10)
                  .fontColor(this.renewalDueSoon(job) ? this.colors().danger : this.colors().textTertiary)
                  .maxLines(1).flexShrink(1)
                if (this.renewalButtonLabel(job) === '续签中') {
                  Text('续签中').fontSize(11)
                    .fontWeight(FontWeight.Medium).fontColor(this.colors().accent)
                    .padding({ left: 3, right: 3, top: 5, bottom: 5 }).flexShrink(0)
                    .responseRegion({ x: -2, y: 0, width: '100%', height: 44 })
                    .id('installed-renew-' + job.bundleName).onClick(() => this.renewInstalled(job))
                }
              }.width('100%')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.installedActionLabel(job), { type: ButtonType.Normal })
              .width(StoreLayout.cardActionWidth).height(44).padding({ left: 8, right: 8 }).fontSize(12)
              .fontColor(this.updateFor(job.bundleName) !== undefined ? this.colors().onAccent : this.colors().accent)
              .backgroundColor(this.updateFor(job.bundleName) !== undefined ? this.colors().accent : this.colors().accentSoft)
              .borderRadius(StoreLayout.cardActionRadius).id('installed-open-' + job.bundleName)
              .enabled(this.uninstallingBundle !== job.bundleName)
              .onClick(() => this.performInstalledAction(job))
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).width('100%')
          .padding(15).backgroundColor(this.renewalDueSoon(job) ? this.colors().renewalWarning :
            this.colors().surface).borderRadius(17)
          .id('installed-card-' + job.bundleName)
          .onClick(() => this.openJobDetails(job))
          .gesture(LongPressGesture({ duration: 500, repeat: false }).onAction(() => {
            this.showInstalledActions(job);
          }))
      }.swipeAction({ end: { builder: () => {
        this.cardSwipeActions(this.installedActions(job), job.bundleName, (key: string): void => { this.showInstalledActions(job, key); });
      }, actionAreaDistance: this.installedActions(job).length * 72 }, edgeEffect: SwipeEdgeEffect.Spring })
    }, (job: InstallJob) => rows.key(job))
  }

  @Builder
  private managementList() {
    Column() {
      List({ space: 11, scroller: this.managementScroller }) {
        ListItem() { Row().width('100%').height(12) }
        // 检查期间保留原列表，只有真实失败才增加提示行。
        if (this.updateCatalogError.length > 0) {
          ListItem() {
            Text(this.updateCatalogError + ' · 点此重试')
              .fontSize(12).fontColor(this.colors().textSecondary).width('100%').padding(10)
              .onClick(() => this.loadUpdateCatalog())
          }
        }
        if (this.queueRowCount > 0) {
          ListItem() {
            Row({ space: 8 }) {
              Text('安装队列').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
              Text(String(this.queueRowCount)).fontSize(12).fontColor(this.colors().accent)
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(this.colors().accentSoft).borderRadius(7)
            }.width('100%').padding({ top: 3, bottom: 6 })
          }
          LazyForEach(this.queueRows, (job: InstallJob) => {
            ListItem() {
              Column({ space: 2 }) {
                Row({ space: 12 }) {
                  if (this.jobIcon(job)) {
                    Image(this.jobIcon(job)).width(44).height(44).borderRadius(12)
                  } else {
                    Text(this.jobTitle(job).substring(0, 1)).fontSize(18).fontColor(this.colors().accent)
                      .width(44).height(44).textAlign(TextAlign.Center)
                      .backgroundColor(this.colors().accentSoft).borderRadius(12)
                  }
                  Column({ space: 5 }) {
                    CatalogAppTitle({ title: this.jobTitle(job), version: this.managementVersion(job),
                      color: this.colors().text, versionColor: this.colors().surface,
                      versionBackground: this.colors().text, active: this.pageVisible && this.currentTab === Index.TAB_MANAGE })
                    if (job.stage === InstallStage.QUEUED) {
                      Text(this.taskJobLabel(job)).fontSize(10)
                        .fontColor(this.colors().textSecondary).maxLines(1)
                    }
                    if (!this.jobRunning(job.id) && job.lastError.length > 0) {
                      Text(job.lastError.replace('点击继续安装', '左滑卡片继续安装').replace('长按卡片继续安装', '左滑卡片继续安装'))
                        .fontSize(11).fontColor(this.colors().textTertiary).maxLines(2)
                    }
                    if (job.stage === InstallStage.INSTALLING && this.jobRunning(job.id)) {
                      Text('取消后停止后续步骤，系统已接收的安装可能仍会完成')
                        .fontSize(10).fontColor(this.colors().textTertiary).maxLines(2)
                    }
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  this.taskIndicator(0, '', job.id)
                }.width('100%')
              }.width('100%').padding(15).backgroundColor(this.colors().surface).borderRadius(16)
                .id('queue-card-' + job.id).accessibilityDescription('左滑查看任务操作')
                .gesture(LongPressGesture({ duration: 500, repeat: false }).onAction(() => {
                  if (!this.cancellingJobs.includes(job.id)) this.showQueueActions(job);
                }))
            }.swipeAction({ end: { builder: () => {
              this.cardSwipeActions(this.queueActions(job), job.id, (key: string): void => { this.showQueueActions(job, key); });
            }, actionAreaDistance: this.queueActions(job).length * 72 }, edgeEffect: SwipeEdgeEffect.Spring })
          }, (job: InstallJob) => this.queueRows.key(job))
        }
        if (this.signedIn) {
          ListItem() {
            Row() {
              Text('我上架的应用').fontSize(19).fontWeight(FontWeight.Bold)
                .fontColor(this.colors().text).layoutWeight(1)
              // 与「已安装」那里同一个刷新图标：转圈时不给再点
              if (this.myAppsRefreshing) {
                Row() { LoadingProgress().width(20).height(20) }
                  .width(44).height(44).justifyContent(FlexAlign.Center)
              } else {
                StoreIconButton({ symbol: $r('sys.symbol.arrow_clockwise'), label: '刷新上架应用',
                  action: () => this.loadMyApps(true) })
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
                Text('从 GitHub Release 添加安装包')
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
          if (this.myAppsLoaded && this.myApps.length === 0 && this.myAppsMessage.length === 0) {
            ListItem() {
              Text('还没有上架应用 · 点上面的「上架新应用」添加')
                .fontSize(12).fontColor(this.colors().textTertiary)
                .width('100%').padding({ top: 6, bottom: 8 })
            }
          }
          LazyForEach(this.publishedRows, (app: CatalogApp) => {
            ListItem() {
              Row({ space: 12 }) {
                if (this.managedIconFor(app)) {
                  Image(this.managedIconFor(app)).width(42).height(42).borderRadius(11)
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
                  .height(44).fontSize(12).fontColor(this.colors().accent)
                  .backgroundColor(this.colors().accentSoft).borderRadius(10)
                  .enabled(this.removingId === 0 && !this.configBusy)
                  .onClick(() => this.openAppConfig(app))
              }.width('100%').padding(15).backgroundColor(this.colors().surface).borderRadius(16)
            }
          }, (app: CatalogApp) => this.publishedRows.key(app))
        }
        // 中断任务恢复入口：只在确实有未完成任务时出现，无任务不占版面。
        if (this.jobsError.length > 0) {
          ListItem() {
            Text(this.jobsError).fontSize(12)
              .fontColor(this.colors().danger).width('100%').padding(13)
              .backgroundColor(this.colors().dangerSoft).borderRadius(15)
          }
        }
        ListItem() {
          Row() {
            Text('已安装 · ' + (this.onlineInstalledCount + this.offlineInstalledCount)).fontSize(19).fontWeight(FontWeight.Bold)
              .fontColor(this.colors().text).layoutWeight(1)
            Button(this.bulkUpdating ? '正在加入…' : '一键更新', { type: ButtonType.Normal })
              .height(32).fontSize(12).padding({ left: 10, right: 10 })
              .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
              .borderRadius(StoreLayout.cardActionRadius).margin({ right: 6 })
              .responseRegion({ x: 0, y: -6, width: '100%', height: 44 })
              .enabled(!this.bulkUpdating && this.updatableInstalledJobs().length > 0)
              .id('installed-update-all').onClick(() => this.updateAllInstalled())
            // 刷新完整设备清单，隐藏明确已卸载的应用，保留安装历史。
            // 按钮本身就是状态——转圈时不给再点。
            if (this.syncBusy) {
              Row() { LoadingProgress().width(20).height(20) }
                .width(44).height(44).justifyContent(FlexAlign.Center)
            } else {
              StoreIconButton({ symbol: $r('sys.symbol.arrow_clockwise'), label: '核对已安装应用',
                action: () => this.refreshInstalled() })
            }
          }.width('100%').padding({ top: 18, bottom: 4 })
        }
        ListItem() { this.installedSourceSelector() }
        if ((this.installedLocalOnly ? this.offlineInstalledCount : this.onlineInstalledCount) === 0) {
          ListItem() {
            Text(this.installedLocalOnly ? '暂无本地侧载应用' : '暂无已安装的商店应用')
              .fontSize(12).fontColor(this.colors().textTertiary).padding({ top: 12, bottom: 12 })
          }
        }
        if (this.syncMessage.length > 0) {
          ListItem() {
            Text(this.syncMessage).fontSize(11).fontColor(this.colors().textTertiary)
              .width('100%').maxLines(3).padding({ bottom: 4 })
          }
        }
        if (this.installedLocalOnly) {
          this.managementInstalledCards(this.offlineInstalledRows)
        } else {
          this.managementInstalledCards(this.onlineInstalledRows)
        }
        // 为悬浮导航留出可滚走的尾部空间，不缩小列表的触摸/显示区域。
        ListItem() { Row().height(110).width('100%') }
      }.padding({ left: this.pageInset(), right: this.pageInset() })
        .width('100%').constraintSize({ maxWidth: StoreLayout.contentWidth + this.pageInset() * 2 }).height('100%')
        .contentStartOffset(this.statusBarInset + 56)
        .cachedCount(4)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
  }

  @Builder
  private reconnectSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('连接无线调试')
          .fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        StoreIconButton({ active: !this.reconnectBusy, action: () => {
          this.completeRefreshConnection(false);
          InstallReconnect.clear(this.resumeJobId); this.animateOverlay(() => { this.showReconnect = false; });
        } })
      }.width('100%')
      Text('前往系统设置，开启无线调试').fontSize(12).padding({ top: 3, bottom: 3 })
        .fontColor(this.colors().accent).width('100%').height(44)
        .decoration({ type: TextDecorationType.Underline, color: this.colors().accent })
        .onClick(() => this.openReconnectSettings())
      Text(this.resumeJobId.length > 0 ? '任务已保存。连接后会从刚才的步骤继续。' :
        '连接后核对本机应用，已有侧载应用会显示打开或更新。')
        .fontSize(13).fontColor(this.colors().textSecondary).width('100%')
      TextInput({ placeholder: '输入无线调试端口', text: this.reconnectPort })
        .type(InputType.Number).height(48).textAlign(TextAlign.Center)
        .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
        .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
        .onChange((value: string) => { this.reconnectPort = value; })
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.reconnectBusy) {
            LoadingProgress().width(18).height(18).color(this.colors().onAccent)
          }
          Text(this.reconnectBusy ? '正在连接…' :
            (this.resumeJobId.length > 0 ? '连接并继续安装' : '连接并识别'))
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().onAccent)
        }.justifyContent(FlexAlign.Center)
      }
        .height(48).width('100%').enabled(!this.reconnectBusy)
        .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
        .onClick(() => this.reconnect())
      if (this.reconnectMessage.length > 0) {
        Text(this.reconnectMessage).fontSize(12).fontColor(this.colors().textSecondary)
          .width('100%').maxLines(3)
      }
    }.padding(24).width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
      .backgroundColor(this.colors().surface).borderRadius(28)
      .transition(TransitionEffect.translate({ y: 16 }))
  }

  @Builder
  private appConfigSheet() {
    Column({ space: 16 }) {
      Row() {
        Text('应用配置').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
          .layoutWeight(1)
        StoreIconButton({ active: (!this.configBusy || this.configSourceChecking) && this.removingId === 0,
          action: () => {
            this.configSourceGeneration++; this.configBusy = false; this.configSourceChecking = false;
            this.animateOverlay(() => { this.showAppConfig = false; });
          } })
      }.width('100%')
      Text(this.configApp.displayName).fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(this.colors().text).maxLines(2).width('100%')
      Text('软件分类').fontSize(13).fontColor(this.colors().textSecondary)
      if (this.configCategories.length > 0) {
        StoreSelect({ options: this.configCategories.map((category: string) => ({ value: category } as SelectOption)),
          selectedIndex: this.configCategories.indexOf(this.configCategory), selectedValue: this.configCategory,
          controlId: 'app-config-category-select', active: !this.configBusy && this.removingId === 0,
          action: (index: number) => { this.configCategory = this.configCategories[index] ?? ''; } })
      }
      Column({ space: 10 }) {
        Row() {
          Text('关联子仓').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
            .layoutWeight(1)
          if (this.configApp.secondaryRepo.length > 0 && !this.configSourceRemove) {
            Text('解除关联').fontSize(12).fontColor(this.colors().danger)
              .enabled(!this.configBusy).onClick(() => {
                this.configSourceUrl = ''; this.configSourceDraft = new SubmitDraft();
                this.configSourceRemove = true; this.configSourceMessage = '保存后解除关联';
              })
          }
        }.width('100%')
        if (!this.configSourceExpanded) {
          Button('新增子仓', { type: ButtonType.Normal })
            .height(38).width('100%').fontSize(12).fontColor(this.colors().accent)
            .backgroundColor(this.colors().accentSoft).borderRadius(12)
            .enabled(!this.configBusy).id('app-config-source-add')
            .onClick(() => { this.configSourceExpanded = true; })
        } else {
        Text('用于同步其他渠道搬运的版本，仅接收与主仓包名一致的安装包。')
          .fontSize(11).fontColor(this.colors().textTertiary).width('100%')
        TextInput({ text: this.configSourceUrl, placeholder: 'https://github.com/用户名/仓库' })
          .height(44).fontSize(13).fontColor(this.colors().text).backgroundColor(this.colors().fill)
          .borderRadius(12).enabled(!this.configBusy).id('app-config-source-url')
          .onChange((value: string) => {
            this.configSourceUrl = value; this.configSourceDraft = new SubmitDraft();
            this.configSourceRemove = false; this.configSourceMessage = '';
          })
        Button(this.configSourceChecking ? '正在核验包名…' : '检查子仓')
          .height(38).width('100%').fontSize(12).fontColor(this.colors().accent)
          .backgroundColor(this.colors().accentSoft).borderRadius(12)
          .enabled(!this.configBusy && this.configSourceUrl.trim().length > 0)
          .id('app-config-source-check').onClick(() => this.checkAppSource())
        if (this.configSourceMessage.length > 0) {
          Text(this.configSourceMessage).fontSize(11).fontColor(this.colors().textSecondary).width('100%')
        }
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
      if (this.configMessage.length > 0) {
        Text(this.configMessage).fontSize(12).fontColor(this.colors().danger).maxLines(3)
      }
      Button(this.configBusy ? '处理中…' : '保存配置').width('100%').height(48).fontSize(14)
        .fontColor(this.colors().onAccent).backgroundColor(this.colors().accent).borderRadius(14)
        .enabled(!this.configBusy && this.removingId === 0 &&
          this.configCategories.includes(this.configCategory) && (!this.configSourceChanged() ||
            this.configSourceDraft.token.length > 0 || this.configSourceRemove))
        .onClick(() => this.saveAppConfig())
      Button(this.removingId === this.configApp.id ? '下架中…' : '下架应用')
        .width('100%').height(44).fontSize(14).fontColor(this.colors().danger)
        .backgroundColor(this.colors().dangerSoft).borderRadius(14)
        .enabled(!this.configBusy && this.removingId === 0)
        .onClick(() => this.removeMyApp(this.configApp))
    }.alignItems(HorizontalAlign.Start).width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth }).padding(24)
      .backgroundColor(this.colors().surface).borderRadius(28)
      .transition(TransitionEffect.translate({ y: 16 }))
  }

  @Builder
  private submitSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('上架应用').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        StoreIconButton({ active: !this.submitBusy || this.submitDraft.inspectionStatus !== 'ready', action: () => {
          this.submitGeneration++;
          this.animateOverlay(() => { this.showSubmit = false; });
        } })
      }.width('100%')
      TextInput({ placeholder: 'GitHub / Gitee 仓库地址', text: this.submitUrl })
        .height(48).onChange((value: string) => { this.submitUrl = value; })
        .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
        .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
      Button(this.submitBusy ? '检查中…' : '检查应用')
        .width('100%').height(48).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent).borderRadius(16)
        .enabled(!this.submitBusy && this.submitUrl.trim().length > 0)
        .onClick(() => this.prepareSubmit())
      if (this.submitDraft.token.length > 0 && this.submitDraft.inspectionStatus === 'ready') {
        Text(this.submitDraft.displayName).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor(this.colors().text).width('100%')
        Text(this.submitDraft.supportsMultiSelect ? '选择安装包（可多选）' : '选择安装包').fontSize(13).fontColor(this.colors().textSecondary).width('100%')
        Scroll() {
          Column({ space: 8 }) {
        ForEach(this.submitDraft.choices, (choice: SubmitChoice) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              Text(this.submitAssets.includes(choice.name) ? '☑' : '□')
                .fontSize(20).fontColor(this.colors().accent)
              Column({ space: 3 }) {
                Text(choice.displayName.length > 0 ? choice.displayName : choice.name)
                  .fontSize(14).fontColor(this.colors().text).maxLines(1)
                Text(choice.name + ' · ' + choice.versionName)
                  .fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').padding(10).backgroundColor(this.colors().fill)
          }.width('100%').padding(0).backgroundColor(this.colors().fill).borderRadius(12)
            .enabled(!this.submitBusy).stateEffect(true)
            .accessibilityText((this.submitAssets.includes(choice.name) ? '已选择，' : '选择，') +
              (choice.displayName.length > 0 ? choice.displayName : choice.name) + '，' + choice.versionName)
            .onClick(() => {
              this.submitAssets = !this.submitDraft.supportsMultiSelect ? [choice.name] :
                (this.submitAssets.includes(choice.name) ?
                  this.submitAssets.filter((name: string) => name !== choice.name) :
                  this.submitAssets.concat([choice.name]));
            })
        }, (choice: SubmitChoice) => choice.name)
          }.width('100%')
        }.width('100%').height(Math.min(216, this.submitDraft.choices.length * 68))
          .scrollBar(BarState.Auto)
        Text('选择分类').fontSize(13).fontColor(this.colors().textSecondary).width('100%')
        StoreSelect({ options: this.submitDraft.categories.map((category: string) => ({ value: category } as SelectOption)),
          selectedIndex: this.submitCategoryIndex,
          selectedValue: this.submitCategory.length > 0 ? this.submitCategory : '选择分类',
          controlId: 'submit-category-select', active: !this.submitBusy,
          action: (index: number) => {
            this.submitCategoryIndex = index;
            this.submitCategory = this.submitDraft.categories[index] ?? '';
          } })
        if (this.submitStateLabel().length > 0) {
          Text(this.submitStateLabel()).fontSize(11)
            .fontColor(this.submitExisting === Index.SUBMIT_STATE_OTHER ?
              this.colors().danger : this.colors().textSecondary)
            .width('100%').maxLines(3)
        }
        Button(this.submitBusy ? (this.submitExisting === Index.SUBMIT_STATE_MINE ?
          '更新中…' : '上架中…') :
          (this.submitExisting === Index.SUBMIT_STATE_MINE ? '确认更新已上架应用' : '确认上架'))
          .width('100%').height(48).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent).borderRadius(16)
          .enabled(!this.submitBusy && this.submitAssets.length > 0 &&
            this.submitCategory.length > 0 &&
            this.submitExisting !== Index.SUBMIT_STATE_OTHER)
          .onClick(() => this.confirmSubmit())
      }
      if (this.submitMessage.length > 0) {
        Text(this.submitMessage).fontSize(12).fontColor(this.colors().textBody)
          .width('100%').maxLines(3)
      }
    }.alignItems(HorizontalAlign.Start).width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth }).padding(24)
      .backgroundColor(this.colors().surface).borderRadius(28)
      .transition(TransitionEffect.translate({ y: 16 }))
  }

  @Builder
  private minePage() {
    HdsNavigation() {
      Scroll(this.mineScroller) {
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
                Row({ space: 6 }) {
                  Text(this.sessionNotice.length > 0 ? this.sessionNotice :
                  (this.signedIn ? '开发者身份已连接' : '登录后即可上架和评价'))
                    .fontSize(12).fontColor(this.colors().textSecondary).flexShrink(1)
                  if (this.signedIn && this.account.realNameVerified !== undefined) {
                    Text(this.account.realNameVerified ? '已实名' : '未实名')
                      .fontSize(10).fontWeight(FontWeight.Medium).maxLines(1).flexShrink(0)
                      .fontColor(this.account.realNameVerified ? this.colors().success : this.colors().textSecondary)
                      .backgroundColor(this.account.realNameVerified ? this.colors().successSoft : this.colors().fill)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(5)
                  }
                }.alignItems(VerticalAlign.Center).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              // 已登录时退出收成一个图标，比一整条按钮简洁；点一下仍会二次确认
              if (this.signedIn) {
                Button('退出').height(44).fontSize(12)
                  .fontColor(this.colors().textSecondary).backgroundColor(this.colors().fill)
                  .borderRadius(22).accessibilityText('退出华为开发者账号')
                  .onClick(() => this.confirmSignOut())
              }
            }.width('100%')
            if (this.loginMessage.length > 0) {
              Text(this.loginMessage).fontSize(12).fontColor(this.colors().textSecondary)
                .maxLines(3).width('100%')
            }
            if (!this.signedIn) {
              Button(this.loginBusy ? '等待浏览器授权…' : '登录华为开发者账号')
                .height(44).backgroundColor(this.colors().accent)
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
                Text('本机签名证书')
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().text).maxLines(1)
                Text(this.certLabel.length > 0 ? this.certLabel : '尚未获取证书')
                  .fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.certExpiry.length > 0) {
                  Text('到期 ' + this.certExpiry + (this.certExpired ? ' · 已到期' : ''))
                    .fontSize(11).fontColor(this.certExpired ? this.colors().danger : this.colors().textSecondary).maxLines(1)
                }
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(this.certReady ? '已配对' : (this.certExpired ? '待重建' : '待申请'))
                .fontSize(11)
                .fontColor(this.certReady ? this.colors().success : this.colors().textSecondary)
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .backgroundColor(this.certReady ? this.colors().successSoft : this.colors().fill)
                .borderRadius(8)
            }.width('100%')
            if ((!this.certReady && !this.certExpired) || this.identityMessage.length > 0) {
              Text(this.identityMessage.length > 0 ? this.identityMessage :
                (this.identityBusy ? '正在核对账号现有调试证书…' :
                  '安装时自动复用或申请本机签名证书'))
                .fontSize(11).fontColor(this.colors().textTertiary).maxLines(3).width('100%')
            }
            // 备份没成功就说出来：本机私钥只有这一份，用户有权在重置前知道它没有副本。
            if (this.backupWarning.length > 0) {
              Text(this.backupWarning)
                .fontSize(11).fontColor(this.colors().danger).maxLines(4).width('100%')
            }
            // 还没有可用证书时给出唯一的申请入口：复用优先，确无可用证书才占槽位。
            if (this.signedIn && !this.certReady && !this.certExpired) {
              Button(this.identityBusy ? '正在准备…' :
                '获取调试证书')
                .height(44).width('100%').fontSize(13)
                .backgroundColor(this.colors().accent)
                .fontColor(this.colors().onAccent).borderRadius(12)
                .enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
            if (this.signedIn && this.certExpired) {
              Button(this.identityBusy ? '正在重建…' :
                '重建签名身份')
                .height(44).width('100%').fontSize(12)
                .backgroundColor(this.colors().accentSoft)
                .fontColor(this.colors().accent)
                .borderRadius(12).enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
            Row({ space: 10 }) {
              Button(this.identityBusy ? '重置中…' : '证书重置')
                .height(44).fontSize(12).layoutWeight(1)
                .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
                .borderRadius(12).enabled(!this.identityBusy && this.signedIn)
                .onClick(() => this.resetCertificate())
              Button('管理 AGC 证书')
                .height(44).fontSize(12).layoutWeight(1)
                .backgroundColor(this.colors().fill).fontColor(this.colors().textSecondary)
                .borderRadius(12)
                .onClick(() => {
                  this.animateOverlay(() => { this.showCertSheet = true; });
                  this.loadCertRows();
                })
            }.width('100%')
            if (this.certMessage.length > 0) {
              Text(this.certMessage).fontSize(11).fontColor(this.colors().danger)
                .maxLines(2).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).padding(20)
            .width('100%').backgroundColor(this.colors().surface).borderRadius(22)

          Row({ space: 12 }) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.doc_text')).fontSize(22).fontColor([this.colors().accent])
                .width(22).height(22)
            }.width(44).height(44).backgroundColor(this.colors().accentSoft).borderRadius(12)
            Column({ space: 4 }) {
              Text('本地 Profile').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
              Text('查看与管理保存的签名授权').fontSize(11).fontColor(this.colors().textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.colors().textTertiary])
          }.padding(20).width('100%').backgroundColor(this.colors().surface).borderRadius(22)
            .accessibilityText('本地 Profile，查看与管理保存的签名授权')
            .onClick(() => this.animateOverlay(() => { this.showLocalProfiles = true; }))

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
                  .height(44).fontSize(12).fontColor(this.colors().textSecondary)
                  .backgroundColor(this.colors().fill).borderRadius(11)
                  .onClick(() => this.releaseDeviceLink())
              } else if (!this.deviceBusy) {
                Button('连接')
                  .height(44).fontSize(12).fontColor(this.colors().onAccent)
                  .backgroundColor(this.colors().accent).borderRadius(11)
                  .onClick(() => { this.animateOverlay(() => { this.showReconnect = true; }); })
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
        }.width('calc(100% - ' + (this.pageInset() * 2) + 'vp)').constraintSize({ maxWidth: StoreLayout.contentWidth }).padding({ top: this.statusBarInset + 72, bottom: 110 })
      }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.titleBar({style:this.scrollTitleBarStyle(56),avoidLayoutSafeArea:true,
      content:{stackBuilder:()=>this.simpleTitleBar('我的'),divider:{showType:DividerShowType.OFF}}
    }).titleMode(HdsNavigationTitleMode.MINI).mode(NavigationMode.Stack).hideBackButton(true)
      .systemBarStyle({statusBarContentColor:this.colors().text},{statusBarContentColor:this.colors().text})
      .bindToScrollable([this.mineScroller])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.BOTTOM])
      .width('100%').height('100%').backgroundColor(this.colors().bg)
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

  @Builder
  private cardActionsSheet() {
    WithTheme({ colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
      Column({ space: 10 }) {
        Row({ space: 12 }) {
          Text(this.cardActionTitle).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).maxLines(2).layoutWeight(1)
          StoreIconButton({ label: '关闭操作菜单', action: () => this.dismissCardActions(-1) })
        }.width('100%').margin({ bottom: 6 })
        ForEach(this.cardActionLabels, (label: string, index: number) => {
          Button(label, { type: ButtonType.Normal }).height(48).width('100%').fontSize(14)
            .fontColor(index === this.cardDestructiveIndex ? this.colors().danger : this.colors().text)
            .backgroundColor(index === this.cardDestructiveIndex ? this.colors().dangerSoft : this.colors().fill)
            .borderRadius(12).id('card-action-' + index)
            .onClick(() => this.dismissCardActions(index))
        }, (label: string) => label)
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
        .padding(22).backgroundColor(this.colors().surface).borderRadius(24)
        .border({ width: 0.5, color: this.colors().border, radius: 24 })
        // Block 会连子按钮的触摸一起拦截。Default 允许子项点击并挡住背后的遮罩。
        .hitTestBehavior(HitTestMode.Default).id('card-action-menu')
        .transition(TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 12 })))
    }
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
    .scrollable(false)
    .barOverlap(true)
    // lightColor 原本是饱和蓝，被 IMMERSIVE 材质压成一坨暗色 —— 底部那块
    // "暗区"。改成随主题的卡片色，材质才是正常的玻璃感。
    .barFloatingStyle({
      lightColor: this.colors().surface,
      // 浮动栏自身保留材质，屏幕底部不再叠加 HDS 默认渐变遮罩。
      gradientMask: { maskColor: '#00000000', maskHeight: 0 },
      barSideMargin: 12,
      // 与透明系统手势条保持距离，内容仍可绘制在其下方。
      barBottomMargin: 20,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      this.currentTab = index;
      if (index === 2) { this.loadJobs(); this.loadMyApps(); this.loadUpdateCatalog(); this.scanDeviceInstalled(); this.loadSigningExpiries(); }
      if (index === 3) {
        // 安装流程可能刚自动准备了证书，进入「我的」后同步显示并备份。
        this.recoverSigningIdentity();
        // 设备状态探完再扫「商店已安装」——扫描依赖 connected 与 installedVersion
        this.checkDevice().then(() => this.refreshCatalogInstallState());
      }
    })
    .width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    if (this.showAppConfig) {
      Column() {
        Scroll() { this.appConfigSheet() }
          .width('100%').constraintSize({ maxHeight: '84%' })
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .transition(TransitionEffect.opacity(0))
    }
    if (this.showCardActions) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(this.colors().scrim)
          .onClick(() => this.dismissCardActions(-1))
        this.cardActionsSheet()
      }.width('100%').height('100%').transition(TransitionEffect.opacity(0))
    }
    if (this.showSubmit) {
      Column() {
        Scroll() { this.submitSheet() }
          .width('100%').constraintSize({ maxHeight: '84%' })
      }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .transition(TransitionEffect.opacity(0))
    }
    if (this.showRenewal) {
      RenewalDialog({ target: this.renewalTarget, sourceAppId: this.renewalSourceAppId,
        existingJobId: this.renewalExistingJobId, title: this.jobTitle(this.renewalTarget),
        icon: this.jobIcon(this.renewalTarget) ?? '', onClose: () => { this.showRenewal = false; },
        onRetry: () => { this.showRenewal = false; this.renewInstalled(this.renewalTarget); },
        onPreparing: (bundle: string, busy: boolean) => {
          this.renewalPreparing = this.renewalPreparing.filter((name: string) => name !== bundle);
          if (busy) this.renewalPreparing = this.renewalPreparing.concat(bundle);
        } })
    }
    if (this.showReconnect) {
      Column() { this.reconnectSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .transition(TransitionEffect.opacity(0))
    }
    if (this.showCertSheet) {
      Column() { this.certSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .transition(TransitionEffect.opacity(0))
    }
    if (this.showLocalProfiles) {
      LocalProfileDialog({ titleForBundle: (bundle: string) => this.localProfileTitle(bundle),
        onClose: () => this.animateOverlay(() => { this.showLocalProfiles = false; }) })
        .transition(TransitionEffect.opacity(0))
    }
    // 最上层三态互斥：检查登录态时显示加载页，确认未登录才显示登录页。
    // 之前把两者混在一个页面里，检查期间会先把登录页的标题和说明卡
    // 画出来再跳走，看着就是「闪一下登录页」。
    if (!this.accountChecked) {
      this.startupSplash()
    } else if (!this.signedIn) {
      this.loginGate()
    }
    InstallCertificatePrompt({ active: this.pageVisible, showing: this.showCertificatePrompt,
      dismissRequest: this.certificatePromptDismiss })
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
      .onSizeChange((_old: SizeOptions, size: SizeOptions) => { this.viewportWidth = Number(size.width); })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
