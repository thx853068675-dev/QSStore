import { InstallReconnect } from '../jobs/InstallReconnect';
import { InstallTaskState, InstallTaskSnapshot } from '../jobs/InstallTaskState';
import { isPending } from '../jobs/RecoveryPlanner';
import { promptAction, router, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { CatalogApp } from '../data/CatalogApp';
import { StoreClient } from '../data/StoreClient';
import { ReleaseInfo, HapAsset } from '../data/ReleaseInfo';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { JobStore } from '../jobs/JobStore';
import { JobRunner } from '../jobs/JobRunner';
import { JobScheduler } from '../jobs/JobScheduler';
import { errorText } from '../jobs/ErrorText';
import { LocalBundles } from '../jobs/LocalBundles';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { NativeJobRuntime } from '../jobs/NativeJobRuntime';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { AppReview } from '../data/StoreActions';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { Palette } from '../theme/Palette';
import { ColorTint } from '../theme/ColorTint';

@Entry
@Component
struct Detail {
  @StorageProp('darkMode') @Watch('syncPalette') darkMode: boolean = false;
  @State private app: CatalogApp = new CatalogApp();
  @State private appIcon: image.PixelMap | null = null;
  /** 头部卡片底色：由图标主色调推导，取不到时用主题默认值。 */
  @State private heroColor: string = '';
  @State private loaded: boolean = false;
  @State private error: string = '';
  @State private releases: ReleaseInfo[] = [];
  @State private selectedAsset: HapAsset = new HapAsset();
  @State @Watch('onBusyChanged') private downloadBusy: boolean = false;
  // 有字节计数时平滑绘制实际阶段进度，其余阶段显示持续活动光效。
  @State @Watch('onPercentChanged') private downloadPercent: number = 0;
  private installFrameTimer: number = -1;
  private renderedPercent: number = 0;
  private renderedPhase: string = '';
  private pulseSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private pulseCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.pulseSettings);
  @State private installTasks: InstallTaskSnapshot[] = [];
  private installSubscription: number = -1;
  private reconnectSubscription: number = -1;
  private detailAppId: number = 0;
  /**
   * 一次性提示文案。
   *
   * 原来它是「按钮上方那行进度文字」的数据源，但那行已经去掉 —— 按钮本身就是
   * 进度显示。这里只保留它真正不可替代的用途：把安装失败、未登录、任务收尾中
   * 这类**用户需要知道原因**的结果说出来，用 toast 呈现，不再长期占版面。
   */
  private lastNotice: string = '';
  @State private reviews: AppReview[] = [];
  /** 评论与版本都按服务端分页取；``*Page`` 是已加载到的页码，``*Total`` 是服务端总数。 */
  @State private reviewPage: number = 0;
  @State private reviewTotal: number = 0;
  @State private reviewPageBusy: boolean = false;
  @State private releasePage: number = 0;
  @State private releaseTotal: number = 0;
  @State private releaseMoreBusy: boolean = false;
  @State private releaseMessage: string = '';
  @State private showPreviewReleases: boolean = false;
  /** 发布评论默认收起，点编辑按钮再展开。 */
  @State private reviewComposeOpen: boolean = false;
  @State private reviewText: string = '';
  @State private reviewStars: number = 5;
  @State private reviewBusy: boolean = false;
  @State private reviewMessage: string = '';
  @State private account: DeveloperAccount = new DeveloperAccount();
  @State private signedIn: boolean = false;
  @State private installedJobs: InstallJob[] = [];
  /** 系统查到的本机版本号（0 = 没装）。不依赖无线调试。 */
  @State private installedVersion: number = 0;
  /**
   * 本机版本是否「无法核实」（系统查询被拒，设备又没连上）。
   *
   * 为 true 时不能把状态当成未安装；仍允许用户主动发起安装或更新。
   */
  @State private installedUnknown: boolean = false;
  /** 「检查更新」的进行状态与结果提示。 */
  @State private refreshBusy: boolean = false;
  @State private refreshMessage: string = '';
  /** 上次真正发起检查的时间，用于客户端侧的静默冷却。 */
  private lastCheckAt: number = 0;
  @State private expandedReleaseTag: string = '';
  @State @Watch('onReconnectVisibilityChanged') private showReconnect: boolean = false;
  @State private reconnectPort: string = '';
  @State private reconnectBusy: boolean = false;
  @State private reconnectMessage: string = '';
  @State private activeInstallId: string = '';
  private reconnectJobId: string = '';
  /** 默认 0 = 最新版本；版本不再平铺，改成下拉选择。 */
  @State private selectedReleaseIndex: number = 0;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  syncPalette(): void {
    // 主题一变，之前按旧主题算出的底色就不再合适，重新推导一次
    this.refreshHeroColor();
    // Canvas 不会随组件属性更新自动重画，下载时切换主题也要同步进度填充色。
    if (this.downloadBusy) this.paintInstallButton();
  }

  private refreshHeroColor(): void {
    if (this.appIcon === null) {
      this.heroColor = '';
      return;
    }
    const dark = this.darkMode;
    ColorTint.heroBackground(this.appIcon, dark).then((color: string) => {
      if (dark === this.darkMode) this.heroColor = color;
    });
  }

  onPageShow(): void {
    this.observeReconnect();
    this.observeInstallTasks();
    this.syncInstallTask();
    this.loadInstalledJobs();
  }

  aboutToAppear(): void {
    this.observeReconnect();
    const params = router.getParams() as Record<string, number>;
    this.detailAppId = Number(params['id'] ?? 0);
    this.observeInstallTasks();
    this.syncPalette();
    this.loadApp();
    this.restoreAccount();
    this.loadInstalledJobs();
    InstalledAppRegistry.load(getContext(this) as common.UIAbilityContext)
      .then(() => this.refreshInstalledVersion());
  }

  aboutToDisappear(): void {
    InstallReconnect.unsubscribe(this.reconnectSubscription);
    this.reconnectSubscription = -1;
    this.stopInstallAnimation();
    InstallTaskState.unsubscribe(this.installSubscription);
    this.installSubscription = -1;
  }

  onPageHide(): void {
    InstallReconnect.deactivate(this.reconnectSubscription);
  }

  private observeReconnect(): void {
    if (this.reconnectSubscription === -1) {
      this.reconnectSubscription = InstallReconnect.subscribe((jobId: string) => {
        if (jobId.length > 0) {
          this.reconnectJobId = jobId;
          this.reconnectMessage = '';
          this.showReconnect = true;
        } else if (this.reconnectJobId.length > 0) {
          this.showReconnect = false;
        }
      });
    }
    InstallReconnect.activate(this.reconnectSubscription);
  }

  private observeInstallTasks(): void {
    if (this.installSubscription !== -1) return;
    this.installSubscription = InstallTaskState.subscribe((rows: InstallTaskSnapshot[]) => {
      this.installTasks = rows;
      const installed = rows.map((row: InstallTaskSnapshot) => row.job).filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLED);
      const changed = installed.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',') !==
        this.installedJobs.map((job: InstallJob) => job.id + ':' + job.updatedAt).join(',');
      this.installedJobs = installed;
      this.syncInstallTask();
      if (changed) this.refreshInstalledVersion();
    });
  }

  private currentInstallTask(): InstallTaskSnapshot | undefined {
    if (this.selectedAsset.name.length > 0) {
      return InstallTaskState.forAsset(this.installTasks, this.detailAppId,
        this.selectedAsset.bundleName, this.selectedAsset.name,
        this.selectedAsset.sha256, this.selectedAsset.versionCode);
    }
    return InstallTaskState.forApp(this.installTasks, this.detailAppId,
      this.selectedAsset.bundleName);
  }

  private syncInstallTask(): void {
    const row = this.currentInstallTask();
    if (row === undefined) return;
    this.activeInstallId = row.job.id;
    this.downloadBusy = row.running;
    this.downloadPercent = row.percent;
    this.paintInstallButton();
    // 只把「失败原因」说出来。这里是每秒轮询的入口，若把正常阶段也弹一遍，
    // 用户会被持续刷屏；阶段本身由按钮文案表达，不需要额外提示。
    if (!row.running && row.job.lastError.length > 0) this.notify(row.job.lastError);
  }

  /**
   * 提示一条结果。
   *
   * 同样的内容不重复弹（阶段轮询会反复给出同一个状态），失败与等待类信息一律
   * 走这里，保证「点了没反应」不会发生。
   */
  private notify(text: string): void {
    if (text.length === 0 || text === this.lastNotice) return;
    this.lastNotice = text;
    try {
      promptAction.showToast({ message: text, duration: 2600 });
    } catch (error) {
      console.error('StarHub notify failed: ' + errorText(error));
    }
  }

  private installButtonLabel(): string {
    const row = this.currentInstallTask();
    if (row !== undefined && row.running) return InstallTaskState.label(row);
    if (row !== undefined && isPending(row.job.stage)) return InstallTaskState.label(row) + ' · 继续';
    if (this.downloadBusy) return '准备中';
    if (this.installedUnknown && this.installedForApp() === undefined) return '安装/更新';
    return !this.installedForApp() ? '安装应用' :
      (this.updateAvailable() ? '更新到 ' + this.selectedVersionLabel() : '打开应用');
  }

  onBusyChanged(): void {
    if (this.downloadBusy) this.paintInstallButton();
    else this.stopInstallAnimation();
  }

  onPercentChanged(): void {
    if (this.downloadBusy) this.paintInstallButton();
  }

  private stopInstallAnimation(): void {
    if (this.installFrameTimer !== -1) clearInterval(this.installFrameTimer);
    this.installFrameTimer = -1;
  }

  private paintInstallButton(): void {
    this.renderInstallFrame();
    if (this.downloadBusy && this.installFrameTimer === -1) {
      this.installFrameTimer = setInterval(() => this.renderInstallFrame(), 33);
    }
  }

  private renderInstallFrame(): void {
    const ctx = this.pulseCtx;
    const w = ctx.width, h = ctx.height;
    if (w <= 0 || h <= 0) return;
    const row = this.currentInstallTask();
    const phase = row === undefined ? '' : row.job.id + ':' + row.job.stage + ':' + row.phase;
    if (phase !== this.renderedPhase) {
      this.renderedPhase = phase;
      this.renderedPercent = 0;
    }
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = this.colors().accent;
    ctx.fillRect(0, 0, w, h);
    if (row !== undefined && InstallTaskState.determinate(row)) {
      // 插值仅用于宽度动画，文字始终显示实际计数；不预估未完成工作。
      this.renderedPercent += (row.percent - this.renderedPercent) * 0.3;
      if (Math.abs(row.percent - this.renderedPercent) < 0.1) this.renderedPercent = row.percent;
      ctx.fillStyle = '#FFFFFF30';
      ctx.fillRect(0, 0, w * this.renderedPercent / 100, h);
    } else {
      const left = ((Date.now() % 1600) / 1600) * (w + w * 0.35) - w * 0.35;
      const band = ctx.createLinearGradient(left, 0, left + w * 0.35, 0);
      band.addColorStop(0, '#FFFFFF00');
      band.addColorStop(0.5, '#FFFFFF40');
      band.addColorStop(1, '#FFFFFF00');
      ctx.fillStyle = band;
      ctx.fillRect(Math.max(0, left), 0, w * 0.35, h);
    }
  }

  /**
   * 刷新「本机装没装」。
   *
   * 数据源有两层：轻启自己的安装记录（知道入口 ability，能直接打开），以及
   * 系统 bundleManager 查到的本机版本。前者依赖无线调试（HDC），后者是本地
   * 同步调用 —— 只看记录时，关掉无线调试就会把已装的应用显示成「安装应用」。
   */
  private async loadInstalledJobs(): Promise<void> {
    try {
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      InstallTaskState.seed(await store.listAll());
    } catch (_) {
      // 保留已收到的任务快照。
    }
    this.refreshInstalledVersion();
  }

  /**
   * 查一次本机版本；查的是当前选中附件的包名（切换版本后包名一般不变）。
   *
   * 系统查询可能因权限不足而「无法核实」（返回 UNKNOWN）。那种情况下**不能**
   * 当成未安装 —— 否则外部装好、或本应用装好但记录丢失时，会把「打开」错误地
   * 显示成「安装」，有记录的应用还会一直显示「更新」。所以另用 unknown 标记，
   * 由 `installedForApp` 决定是否回退到设备查询。
   */
  private refreshInstalledVersion(): void {
    const bundleName = this.selectedAsset.bundleName;
    if (bundleName.length === 0) {
      this.installedVersion = 0;
      this.installedUnknown = false;
      return;
    }
    const version = LocalBundles.installedVersion(bundleName);
    this.installedUnknown = !LocalBundles.isKnown(version);
    this.installedVersion = version > 0 ? version : 0;
    if (this.installedUnknown) this.confirmInstalledViaDevice(bundleName);
  }

  /**
   * 系统查询无法核实时，退一步问设备（HDC 的 `bm dump` 不需要任何权限）。
   *
   * 问到了就补上版本号；设备没连或仍答不出来，就保持 unknown。
   * 用户仍可发起安装，后续授权/安装步骤再要求连接设备。
   */
  private async confirmInstalledViaDevice(bundleName: string): Promise<void> {
    try {
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      const version = await bridge.installedVersion(bundleName);
      // 期间用户可能已经切到别的附件，只认仍然对得上的结果。
      if (this.selectedAsset.bundleName !== bundleName) return;
      if (version >= 0) {
        this.installedVersion = version;
        this.installedUnknown = false;
      }
    } catch (_) {
      // 设备没连/已断开：无法核实就保持无法核实
    }
  }

  /** 本机是否装了这个应用：记录或系统查询任一命中即可。 */
  private installedForApp(): InstallJob | undefined {
    const bundleName = this.selectedAsset.bundleName;
    if (bundleName.length === 0) return undefined;
    const record = this.installedJobs.find((job: InstallJob) =>
      job.bundleName === bundleName);
    if (record !== undefined) return record;
    // 系统里装着但没有轻启的安装记录：构造一个够用的记录（没有入口 ability，
    // openInstalled 会交给系统解析）
    if (this.installedVersion <= 0) return undefined;
    const job = new InstallJob();
    job.appId = this.app.id;
    job.bundleName = bundleName;
    job.versionCode = this.installedVersion;
    return job;
  }

  /**
   * 选中版本是否比本机装的更新。
   *
   * 比较用 versionCode，展示用 versionName —— 后者对人可读。
   *
   * 无法核实本机版本时，有本应用的安装记录就用记录中的版本做展示判断；
   * 没有记录则保持未知，由按钮显示「安装/更新」。设备最终版本仍由安装链核实。
   */
  private updateAvailable(): boolean {
    if (this.installedUnknown) {
      const recorded = this.installedForApp();
      return recorded !== undefined && recorded.versionCode > 0 &&
        this.selectedAsset.versionCode > recorded.versionCode;
    }
    if (this.installedVersion <= 0 && this.installedForApp() === undefined) return false;
    return this.selectedAsset.versionCode > this.installedVersion;
  }

  /** 展示实际版本名；缺失时先用 Release 标签，再退回构建号。 */
  private selectedVersionLabel(): string {
    if (this.selectedAsset.versionName.length > 0) return this.selectedAsset.versionName;
    const tag = this.currentRelease()?.tag ?? '';
    if (tag.length > 0) return tag.replace(/^v(?=\d)/i, '');
    return this.selectedAsset.versionCode > 0 ? String(this.selectedAsset.versionCode) : '待确认';
  }

  private installedForSelection(): InstallJob | undefined {
    return this.installedJobs.find((job: InstallJob) => job.appId === this.app.id &&
      job.bundleName === this.selectedAsset.bundleName &&
      job.versionCode === this.selectedAsset.versionCode &&
      job.mainAbility.length > 0);
  }

  /**
   * 打开一个已装应用。
   *
   * 外部安装没有入口记录时，从设备包信息取得真实模块和 Ability，再发起启动。
   */
  private async openInstalled(job: InstallJob): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await new HdcDeviceBridge(context).openApp(job.bundleName, job.moduleName, job.mainAbility);
    } catch (error) {
      this.notify('无法打开应用：' + errorText(error));
    }
  }

  /**
   * 检查更新：让服务端重采这个仓库，再把版本列表重新拉一遍。
   *
   * 客户端只能看到服务端已经采集到的数据，而采集器是有周期的，所以「刚发布的
   * 版本」在界面上会晚一轮出现。点这里让服务端立刻去 GitHub 采一次。
   */
  private async checkForUpdates(): Promise<void> {
    if (this.refreshBusy || this.app.id <= 0) return;
    // 客户端自己也限频：服务端虽然按 IP 限流，但没必要为了连点几次去占一次
    // 请求。冷却期内的点击直接忽略——用户无感，不会弹错也不会转圈。
    const now = Date.now();
    if (now - this.lastCheckAt < Detail.CHECK_COOLDOWN_MS) {
      return;
    }
    this.lastCheckAt = now;
    this.refreshBusy = true;
    this.refreshMessage = '正在检查…';
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      // 服务端要现去 GitHub 采一次，给它一个上限：卡住时按钮要能自己恢复
      await Detail.withDeadline(client.refreshApp(this.app.id), Detail.CHECK_TIMEOUT_MS,
        '检查更新超时，请稍后再试');
      const releases = await client.listReleases(this.app.id, 1, Detail.RELEASES_PER_PAGE,
        this.showPreviewReleases);
      const before = this.releaseTotal;
      const previousTags = this.releases.map((release: ReleaseInfo) => release.tag).join(',');
      const selectedUrl = this.selectedAsset.url;
      const selectedName = this.selectedAsset.name;
      this.releases = releases.items;
      this.releasePage = releases.page;
      this.releaseTotal = releases.total;
      // 已选附件可能随上游 Release 删除而消失，不能让底部按钮继续安装旧地址。
      this.reconcileSelectedAsset(selectedUrl, selectedName);
      this.releaseMessage = '';
      // 先取本机版本，再判断按钮该显示「安装」还是「更新」
      this.refreshInstalledVersion();
      this.refreshMessage = releases.total > before ?
        '发现 ' + (releases.total - before) + ' 个新版本' :
        (releases.total < before ? '已移除 ' + (before - releases.total) + ' 个失效版本' :
          (previousTags !== this.releases.map((release: ReleaseInfo) => release.tag).join(',') ?
            '版本列表已更新' : '已是最新'));
    } catch (error) {
      // 检查失败不影响已有内容，只提示这一次
      this.refreshMessage = '检查更新失败：' + errorText(error);
    } finally {
      this.refreshBusy = false;
    }
  }

  /** 每页条数直接交给服务端，界面上不再对第一页做本地切片。 */
  /** 「检查更新」的客户端冷却：冷却期内的点击静默忽略，不发请求也不提示。 */
  private static readonly CHECK_COOLDOWN_MS: number = 60000;
  /** 检查更新的上限：服务端要现去 GitHub 采一次，慢了就放弃，别让按钮一直转。 */
  private static readonly CHECK_TIMEOUT_MS: number = 30000;

  /** 给一个 Promise 加上限，超时后以给定文案失败。 */
  private static withDeadline<T>(work: Promise<T>, ms: number, message: string): Promise<T> {
    let settled = false;
    const guarded = work.then((value: T) => {
      if (!settled) return value;
      return new Promise<T>(() => {});
    }, (error: Object) => {
      // ArkTS 只允许抛 Error 实例，原始错误转成文案再抛
      if (!settled) throw new Error(errorText(error));
      return new Promise<T>(() => {});
    });
    const limit = new Promise<T>((_resolve, reject) => {
      setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error(message));
      }, ms);
    });
    return Promise.race([guarded, limit]);
  }
  private static readonly REVIEWS_PER_PAGE: number = 20;
  private static readonly RELEASES_PER_PAGE: number = 20;

  /** 服务端返回的总数才是真实条数，不能用当前页长度推算。 */
  private reviewPageCount(): number {
    return Math.max(1, Math.ceil(this.reviewTotal / Detail.REVIEWS_PER_PAGE));
  }

  private releaseHasMore(): boolean {
    return this.releases.length < this.releaseTotal && !this.releaseMoreBusy;
  }

  private currentRelease(): ReleaseInfo | undefined {
    if (this.releases.length === 0) return undefined;
    const index = Math.min(Math.max(this.selectedReleaseIndex, 0), this.releases.length - 1);
    return this.releases[index];
  }

  /** 版本下拉收起时显示的标签：版本名 · 发布时间。 */
  private currentReleaseLabel(): string {
    const release = this.currentRelease();
    if (release === undefined) return '选择版本';
    return (release.prerelease ? '预览版 · ' : '') +
      (release.name.length > 0 ? release.name : release.tag) +
      (release.publishedAt.length >= 10 ? '  ·  ' + release.publishedAt.substring(0, 10) : '');
  }

  private releaseOptions(): SelectOption[] {
    const options = this.releases.map((release: ReleaseInfo) => {
      const label = (release.prerelease ? '预览版 · ' : '') +
        (release.name.length > 0 ? release.name : release.tag) +
        (release.publishedAt.length >= 10 ? '  ·  ' + release.publishedAt.substring(0, 10) : '');
      return { value: label } as SelectOption;
    });
    if (this.releases.length < this.releaseTotal) {
      options.push({ value: this.releaseMoreBusy ? '读取历史版本中…' : '更多历史版本…' });
    }
    return options;
  }

  /** 评论时间：API 给的是 epoch 秒或毫秒的字符串。始终带年份。 */
  private formatReviewTime(raw: string): string {
    const value = Number(raw);
    if (!Number.isFinite(value) || value <= 0) return '';
    const date = new Date(value < 1000000000000 ? value * 1000 : value);
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
  }

  private displayNotes(notes: string, releaseName: string): string {
    const cleaned = notes.replace(/\r/g, '').replace(/^\s*#{1,6}\s*/gm, '')
      .replace(/^\s*[-*]\s+/gm, '• ').replace(/\*\*/g, '')
      .replace(/\n{3,}/g, '\n\n').trim();
    const lines = cleaned.split('\n');
    if (lines.length > 1 && lines[0].trim() === releaseName.trim()) {
      return lines.slice(1).join('\n').trim();
    }
    return cleaned;
  }

  private releaseSelected(release: ReleaseInfo): boolean {
    return release.assets.some((asset: HapAsset) =>
      asset.url === this.selectedAsset.url && asset.name === this.selectedAsset.name);
  }

  /** 重新拉取版本后，沿用仍存在的附件；附件已下架时改选最新可安装版本。 */
  private reconcileSelectedAsset(preferredUrl: string, preferredName: string): void {
    let chosen = new HapAsset();
    let chosenIndex = 0;
    if (preferredUrl.length > 0) {
      for (let index = 0; index < this.releases.length; index++) {
        const match = this.releases[index].assets.find((asset: HapAsset) =>
          asset.url === preferredUrl && asset.name === preferredName);
        if (match !== undefined) {
          chosen = match;
          chosenIndex = index;
          break;
        }
      }
    }
    if (chosen.url.length === 0) {
      for (let index = 0; index < this.releases.length; index++) {
        if (this.releases[index].assets.length > 0) {
          chosen = this.releases[index].assets[0];
          chosenIndex = index;
          break;
        }
      }
    }
    this.selectedReleaseIndex = chosenIndex;
    this.selectedAsset = chosen;
  }

  private async restoreAccount(): Promise<void> {
    const saved = await AccountSession.load(getContext(this) as common.UIAbilityContext);
    if (saved) { this.account = saved; this.signedIn = true; }
  }

  private selectRelease(index: number): void {
    if (index >= this.releases.length) {
      this.loadMoreReleases();
      return;
    }
    this.selectedReleaseIndex = index;
    const release = this.releases[index];
    this.selectedAsset = release && release.assets.length > 0 ? release.assets[0] : new HapAsset();
    this.expandedReleaseTag = '';
    // 换了附件就可能换了包名，按钮状态要跟着重算
    this.refreshInstalledVersion();
  }

  private async togglePreviewReleases(): Promise<void> {
    if (this.releaseMoreBusy || this.app.id <= 0) return;
    const previous = this.showPreviewReleases;
    const next = !previous;
    const selectedUrl = this.selectedAsset.url;
    const selectedName = this.selectedAsset.name;
    this.releaseMoreBusy = true;
    this.showPreviewReleases = next;
    try {
      const result = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .listReleases(this.app.id, 1, Detail.RELEASES_PER_PAGE, next);
      this.showPreviewReleases = next;
      this.releases = result.items;
      this.releasePage = result.page;
      this.releaseTotal = result.total;
      this.reconcileSelectedAsset(selectedUrl, selectedName);
      this.refreshInstalledVersion();
      this.releaseMessage = '';
    } catch (error) {
      this.showPreviewReleases = previous;
      this.releaseMessage = '无法读取版本：' + errorText(error);
    } finally {
      this.releaseMoreBusy = false;
    }
  }

  /** 取服务端的第 page 页（从 1 开始）。失败时保留当前页，只提示错误。 */
  private async fetchReviewPage(page: number): Promise<void> {
    if (page < 1 || this.reviewPageBusy) return;
    this.reviewPageBusy = true;
    try {
      const result = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .listReviews(this.app.id, page, Detail.REVIEWS_PER_PAGE);
      this.reviews = result.items;
      this.reviewPage = result.page;
      this.reviewTotal = result.total;
    } catch (error) {
      this.reviewMessage = errorText(error);
    } finally {
      this.reviewPageBusy = false;
    }
  }

  private async loadReviews(): Promise<void> {
    this.reviewMessage = '';
    await this.fetchReviewPage(1);
  }

  private async loadMoreReleases(): Promise<void> {
    if (!this.releaseHasMore()) return;
    this.releaseMoreBusy = true;
    try {
      const result = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .listReleases(this.app.id, this.releasePage + 1, Detail.RELEASES_PER_PAGE,
          this.showPreviewReleases);
      const known = this.releases.map((release: ReleaseInfo) => release.tag);
      this.releases = this.releases.concat(result.items.filter(
        (release: ReleaseInfo) => known.indexOf(release.tag) < 0));
      this.releasePage = result.page;
      this.releaseTotal = result.total;
      this.releaseMessage = '';
    } catch (error) {
      // 续取失败不能清空页面：已加载的版本仍然可用，只提示这一行。
      this.releaseMessage = '无法加载更早的版本：' + errorText(error);
    } finally {
      this.releaseMoreBusy = false;
    }
  }

  private async sendReview(): Promise<void> {
    if (!this.signedIn) {
      this.reviewMessage = '请在「我的」登录华为开发者账号后评价';
      return;
    }
    if (this.reviewText.trim().length === 0) {
      this.reviewMessage = '请输入评价内容';
      return;
    }
    this.reviewBusy = true;
    try {
      // 新评价排在最前，服务端返回的第一页就是它所在的那页。
      const result = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .postReview(this.app.id, this.reviewStars, this.reviewText.trim(), this.account);
      this.reviews = result.items;
      this.reviewPage = result.page;
      this.reviewTotal = result.total;
      this.reviewText = '';
      this.reviewMessage = '评价已发布';
    } catch (error) {
      this.reviewMessage = errorText(error);
    } finally {
      this.reviewBusy = false;
    }
  }

  private async loadApp(): Promise<void> {
    try {
      const params = router.getParams() as Record<string, number>;
      const id = Number(params['id'] ?? 0);
      if (id <= 0) throw new Error('应用编号无效');
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      this.app = await client.appDetail(id);
      this.appIcon = await client.appIcon(this.app) ?? null;
      const releases = await client.listReleases(id, 1, Detail.RELEASES_PER_PAGE,
        this.showPreviewReleases);
      this.releases = releases.items;
      this.releasePage = releases.page;
      this.releaseTotal = releases.total;
      // 图标到位后再取主色调，头部底色跟着图标变
      this.refreshHeroColor();
      await this.loadReviews();
      this.reconcileSelectedAsset('', '');
      // 必须在选中附件之后重算：aboutToAppear 里 loadInstalledJobs 跑在
      // loadApp 之前，那时 selectedAsset 还是空的，查不到包名就会一直显示「安装应用」。
      this.refreshInstalledVersion();
      this.syncInstallTask();
      this.loaded = true;
      this.error = '';
    } catch (error) {
      this.error = errorText(error);
    }
  }


  private async resumeInstall(id: string): Promise<void> {
    if (JobScheduler.isRunning(id)) { this.syncInstallTask(); return; }
    this.downloadBusy = true;
    this.activeInstallId = id;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const runner = new JobRunner(store,
        new NativeJobRuntime(context, store, this.signedIn ? this.account : undefined,
          new HdcDeviceBridge(context)));
      const result = await runner.run(id);
      if (result.stage === InstallStage.INSTALLED) {
        this.downloadPercent = 100;
        this.lastNotice = '';
        await this.loadInstalledJobs();
      } else if (result.stage === InstallStage.WAITING_DEVICE) {
        this.notify('安装已暂停，重新连接后会从当前步骤继续');
        this.reconnectMessage = '';
        InstallReconnect.request(id);
      } else if (result.stage === InstallStage.WAITING_ACCOUNT) {
        this.notify('请先在「我的」登录华为开发者账号');
      } else if (result.stage === InstallStage.WAITING_CONFIRMATION) {
        this.confirmDataLoss(result);
      } else {
        this.notify(result.lastError.length > 0 ? result.lastError :
          '安装任务已保存，可在「管理」中继续');
      }
    } catch (error) {
      const text = errorText(error);
      if (String(error).includes('安装任务已取消')) return;
      // 超时只结束了「等待」，旧执行还在收尾（锁没放）。说清楚原因，否则用户
      // 立刻点重试会收到「正在执行」，看起来像卡住了。
      this.notify(JobScheduler.stillFinishing(id) ?
        text + '（本次执行仍在后台收尾，请等它结束后再重试）' :
        (text.includes('正在执行') ? '该任务已在执行中，请稍候' : text));
    } finally {
      this.downloadBusy = false;
      this.syncInstallTask();
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
          await store.approveDataLoss(job.id, installed);
          await this.resumeInstall(job.id);
        } catch (error) { this.notify(errorText(error)); }
      } }
    });
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
      const port = Number(this.reconnectPort.trim());
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      if (!await bridge.connect(port)) {
        this.reconnectMessage = bridge.connectionFailureMessage();
        return;
      }
      this.showReconnect = false;
      this.reconnectMessage = '';
      const jobId = this.reconnectJobId || this.activeInstallId;
      InstallReconnect.clear(jobId);
      await this.resumeInstall(jobId);
    } catch (error) {
      this.reconnectMessage = errorText(error);
    } finally {
      this.reconnectBusy = false;
    }
  }

  private async downloadSelected(): Promise<void> {
    if (this.downloadBusy || this.currentInstallTask()?.running) return;
    const asset = this.selectedAsset;
    if (!/^https:\/\//.test(asset.url)) {
      this.notify('该附件缺少 HTTPS 下载地址，暂不能下载');
      return;
    }
    this.downloadBusy = true;
    this.downloadPercent = 0;
    this.notify('正在下载安装包');
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const job = await store.enqueue(this.app.id, asset.name, asset.url,
        asset.sha256, asset.mirrorUrls, asset.versionName, asset.bundleName, asset.versionCode);
      if (job.stage === InstallStage.QUEUED || job.stage === InstallStage.DOWNLOADING ||
        job.stage === InstallStage.WAITING_NETWORK) {
        await JobScheduler.runDownload(context, store, job);
      }
      await this.resumeInstall(job.id);
    } catch (error) {
      this.notify(errorText(error));
    } finally {
      this.downloadBusy = false;
      this.syncInstallTask();
    }
  }

  @Builder
  private reconnectSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('连接无线调试').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
        Text('×').fontSize(26).fontColor(this.colors().textSecondary)
          .onClick(() => { if (!this.reconnectBusy) { InstallReconnect.clear(this.reconnectJobId); this.showReconnect = false; } })
      }.width('100%')
      Text('前往系统设置，开启无线调试').fontSize(12).padding({ top: 3, bottom: 3 })
        .fontColor(this.colors().accent).width('100%')
        .decoration({ type: TextDecorationType.Underline, color: this.colors().accent })
        .onClick(() => new HdcDeviceBridge(getContext(this) as common.UIAbilityContext)
          .openWirelessSettings())
      Text('安装进度已保留。连接后会从刚才的步骤继续。')
        .fontSize(13).fontColor(this.colors().textSecondary).width('100%')
      TextInput({ placeholder: '输入无线调试端口', text: this.reconnectPort })
        .type(InputType.Number).height(48).textAlign(TextAlign.Center)
        .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
        .backgroundColor(this.colors().fill).caretColor(this.colors().accent)
        .onChange((value: string) => { this.reconnectPort = value; })
      Button(this.reconnectBusy ? '正在连接…' : '连接并继续安装')
        .width('100%').height(48).enabled(!this.reconnectBusy)
        .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
        .onClick(() => this.reconnect())
      if (this.reconnectMessage.length > 0) {
        Text(this.reconnectMessage).fontSize(12).fontColor(this.colors().textSecondary)
          .width('100%').maxLines(3)
      }
    }.padding(21).width('90%').backgroundColor(this.colors().surface).borderRadius(23)
  }

  /**
   * 来源仓库所在平台。
   *
   * 服务端只存 owner/name，没有平台字段，所以这里做兼容解析：
   *   owner/name                  → 默认 github.com（历史数据都是这种）
   *   gitee.com/owner/name        → gitee.com
   *   https://gitcode.com/o/n     → gitcode.com
   * 换成别的托管平台时不用改代码，写清平台即可。
   */
  private repoHost(): string {
    const raw = this.app.repo.trim();
    const withScheme = /^https?:\/\/([^/\s]+)\//.exec(raw);
    if (withScheme) return withScheme[1].toLowerCase();
    const parts = raw.split('/');
    if (parts.length >= 3 && parts[0].includes('.')) return parts[0].toLowerCase();
    return 'github.com';
  }

  /** 去掉平台前缀，只留 owner/name。 */
  private repoPath(): string {
    let raw = this.app.repo.trim();
    raw = raw.replace(/^https?:\/\/[^/\s]+\//, '');
    const parts = raw.split('/');
    if (parts.length >= 3 && parts[0].includes('.')) parts.shift();
    return parts.join('/');
  }

  private repoHostLabel(): string {
    const host = this.repoHost();
    if (host === 'github.com') return 'GITHUB';
    if (host === 'gitee.com') return 'GITEE';
    if (host === 'gitcode.com') return 'GITCODE';
    if (host === 'coding.net') return 'CODING';
    if (host === 'bitbucket.org') return 'BITBUCKET';
    if (host.startsWith('gitlab')) return 'GITLAB';
    return host.toUpperCase();
  }

  private async openRepo(): Promise<void> {
    const path = this.repoPath();
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(path)) return;
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: 'https://' + this.repoHost() + '/' + path
      });
    } catch (error) {
      this.notify('无法打开来源仓库：' + errorText(error));
    }
  }

  private packageSizeLabel(): string {
    const size = this.selectedAsset.url.length > 0 ? this.selectedAsset.size :
      (this.app.latestAsset?.size ?? 0);
    if (!Number.isFinite(size) || size <= 0) return '安装包大小待确认';
    if (size >= 1024 * 1024 * 1024) return '安装包 ' + (size / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
    if (size >= 1024 * 1024) return '安装包 ' + (size / (1024 * 1024)).toFixed(1) + ' MB';
    if (size >= 1024) return '安装包 ' + Math.ceil(size / 1024) + ' KB';
    return '安装包 ' + Math.ceil(size) + ' B';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      Row() {
        Text('‹').fontSize(30).fontColor(this.colors().text).width(38)
          .onClick(() => router.back())
        Text('应用详情').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text)
      }.width('100%').padding({ left: 18, right: 20, top: 6, bottom: 12 })
      if (this.error.length > 0) {
        Text('无法读取应用详情').fontSize(15).fontColor(this.colors().textSecondary)
          .margin({ top: 28 })
      } else if (!this.loaded) {
        LoadingProgress().width(30).height(30).margin({ top: 36 })
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
          Scroll() {
            Column({ space: 20 }) {
              Column({ space: 17 }) {
                Row({ space: 16 }) {
                  if (this.appIcon) {
                    Image(this.appIcon).width(74).height(74).borderRadius(20)
                  } else {
                    Text(this.app.displayName.length > 0 ? this.app.displayName.substring(0, 1) : '应')
                      .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                      .width(74).height(74).textAlign(TextAlign.Center)
                      .backgroundColor(this.colors().surface).borderRadius(20)
                  }
                  Column({ space: 7 }) {
                    Text(this.app.displayName).fontSize(25).fontWeight(FontWeight.Bold)
                      .fontColor(this.colors().text).maxLines(1)
                    Text('版本 ' + this.selectedVersionLabel()).fontSize(11).fontWeight(FontWeight.Medium)
                      .fontColor(this.colors().accent).padding({ left: 9, right: 9, top: 5, bottom: 5 })
                      .backgroundColor(this.colors().surface).borderRadius(8).maxLines(1)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')
                Text(this.app.summary).fontSize(13).fontColor(this.colors().textBody)
                  .lineHeight(20).maxLines(3).width('100%')
                Row() {
                  Text('由 ' + this.app.publisherName + ' 上架').fontSize(11)
                    .fontColor(this.colors().textSecondary).layoutWeight(1).maxLines(1)
                  Text('★ ' + this.app.stars).fontSize(11)
                    .fontColor(this.colors().accent)
                }.width('100%')
                Row({ space: 10 }) {
                  Text(this.app.category).fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor(this.colors().accent).padding({ left: 9, right: 9, top: 5, bottom: 5 })
                    .backgroundColor(this.colors().surface).borderRadius(8)
                  Blank().layoutWeight(1)
                  Text(this.packageSizeLabel()).fontSize(12).fontColor(this.colors().textSecondary)
                    .maxLines(1)
                }.width('100%')
              }.alignItems(HorizontalAlign.Start).width('100%')
                .padding(22)
                .backgroundColor(this.heroColor.length > 0 ? this.heroColor : this.colors().hero)
                .borderRadius(26)
              // 来源仓库卡片：平台徽章按仓库地址识别，不写死 GitHub
              Column({ space: 10 }) {
                Row({ space: 9 }) {
                  Text(this.repoHostLabel())
                    .fontSize(10).fontWeight(FontWeight.Bold).fontColor(this.colors().accent)
                    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                    .backgroundColor(this.colors().accentSoft).borderRadius(7)
                  Text('来源仓库').fontSize(11).fontColor(this.colors().textTertiary)
                    .layoutWeight(1).maxLines(1)
                }.width('100%')
                Text(this.repoPath()).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().text).maxLines(1)
              }.alignItems(HorizontalAlign.Start).width('100%').padding(16)
                .backgroundColor(this.colors().surface).borderRadius(17)
                .onClick(() => this.openRepo())
              Row() {
                Text('版本记录').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().text).layoutWeight(1)
                Text(String(this.releaseTotal) + ' 个版本').fontSize(11)
                  .fontColor(this.colors().textTertiary)
                // 采集器按周期跑，刚发布的版本要等下一轮；这里可以即时重采
                if (this.refreshBusy) {
                  LoadingProgress().width(16).height(16).margin({ left: 10 })
                } else {
                  Text('检查更新').fontSize(11).fontColor(this.colors().accent)
                    .margin({ left: 10 })
                    .onClick(() => this.checkForUpdates())
                }
              }.width('100%')
              if (this.currentRelease()) {
                Column({ space: 11 }) {
                  // 版本下拉全宽：发布时间并进下拉标签，收起时也能看到
                  Select(this.releaseOptions())
                    .selected(this.selectedReleaseIndex)
                    .value(this.currentReleaseLabel())
                    .font({ size: 14 })
                    .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
                    .optionFont({ size: 13 })
                    // Font 类型没有 color，文字色要用 fontColor 单独设
                    .fontColor(this.colors().text)
                    .optionFontColor(this.colors().text).selectedOptionFontColor(this.colors().accent)
                    .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
                      .fontColor([this.colors().textSecondary]).fontSize(14))
                    .selectedOptionBgColor(this.colors().accentSoft)
                    .optionBgColor(this.colors().surface)
                    .menuBackgroundColor(this.colors().surface).menuBackgroundBlurStyle(BlurStyle.NONE)
                    .backgroundColor(this.colors().fill)
                    .width('100%')
                    .onSelect((index: number) => this.selectRelease(index))
                  Row({ space: 8 }) {
                    Text('包含预览版').fontSize(12).fontColor(this.colors().textSecondary)
                      .layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.showPreviewReleases })
                      .selectedColor(this.colors().accent).enabled(!this.releaseMoreBusy)
                      .onChange((enabled: boolean) => {
                        if (enabled !== this.showPreviewReleases) this.togglePreviewReleases();
                      })
                  }.width('100%')
                  if (this.currentRelease()!.notes.length > 0) {
                    Text(this.displayNotes(this.currentRelease()!.notes, this.currentRelease()!.name))
                      .fontSize(10).fontColor(this.colors().textBody)
                      .lineHeight(17)
                      .maxLines(this.expandedReleaseTag === this.currentRelease()!.tag ? 80 : 3)
                      .width('100%')
                    if (this.displayNotes(this.currentRelease()!.notes,
                      this.currentRelease()!.name).length > 125) {
                      Text(this.expandedReleaseTag === this.currentRelease()!.tag ? '收起' : '展开更新内容')
                        .fontSize(11).fontColor(this.colors().accent)
                        .onClick(() => {
                          this.expandedReleaseTag =
                            this.expandedReleaseTag === this.currentRelease()!.tag ? '' :
                              this.currentRelease()!.tag;
                        })
                    }
                  }
                  if (this.currentRelease()!.assets.length > 1) {
                  ForEach(this.currentRelease()!.assets, (asset: HapAsset) => {
                    Row({ space: 10 }) {
                      Text(this.selectedAsset.url === asset.url &&
                        this.selectedAsset.name === asset.name ? '✓' : '选择')
                        .fontSize(10).fontColor(this.selectedAsset.url === asset.url &&
                        this.selectedAsset.name === asset.name ? this.colors().accent : this.colors().textTertiary)
                      Text(asset.name).fontSize(12).fontColor(this.colors().textBody)
                        .maxLines(2).layoutWeight(1)
                    }.width('100%').padding({ left: 11, right: 11, top: 9, bottom: 9 })
                      .backgroundColor(this.selectedAsset.url === asset.url &&
                        this.selectedAsset.name === asset.name ? this.colors().accentSoft : this.colors().fill)
                      .borderRadius(10)
                      .onClick(() => { this.selectedAsset = asset; })
                  }, (asset: HapAsset) => asset.name)
                  }
                  // 版本按服务端分页续取，避免只看到第一页就以为没有旧版本。
                  if (this.refreshMessage.length > 0) {
                    Text(this.refreshMessage).fontSize(11)
                      .fontColor(this.colors().textTertiary)
                      .width('100%').maxLines(2)
                  }
                  if (this.releaseMessage.length > 0) {
                    Text(this.releaseMessage).fontSize(11)
                      .fontColor(this.colors().textSecondary)
                      .width('100%').maxLines(2)
                  }
                }.alignItems(HorizontalAlign.Start).width('100%')
                  .padding(16)
                  .backgroundColor(this.colors().surface)
                  .borderRadius(18)
                  .border({ width: 1, color: this.colors().border })
              }
              Row() {
                Text('用户评价').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().text).layoutWeight(1)
                Text(this.reviewTotal + ' 条').fontSize(11).fontColor(this.colors().textTertiary)
              }.width('100%')
              // 应用总分：服务端详情接口返回 rating:{average,count}
              Row({ space: 12 }) {
                Column({ space: 2 }) {
                  Text(this.app.ratingCount > 0 ?
                    this.app.ratingAverage.toFixed(1) : '—')
                    .fontSize(34).fontWeight(FontWeight.Bold)
                    .fontColor(this.app.ratingCount > 0 ? this.colors().accent : this.colors().textTertiary)
                  Text(this.app.ratingCount > 0 ?
                    this.app.ratingCount + ' 条评分' : '还没有评分')
                    .fontSize(11).fontColor(this.colors().textTertiary)
                }.alignItems(HorizontalAlign.Start)
                Column({ space: 4 }) {
                  Row({ space: 2 }) {
                    ForEach([1, 2, 3, 4, 5], (slot: number) => {
                      Text(slot <= Math.round(this.app.ratingAverage) ? '★' : '☆')
                        .fontSize(15).fontColor(this.colors().star)
                    }, (slot: number) => String(slot))
                  }
                  Text('满分 5 分').fontSize(10).fontColor(this.colors().textTertiary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').padding(14)
                .backgroundColor(this.colors().surface).borderRadius(17)
              // 发布区默认收起：收起时只有一行入口，点 ✎ 展开
              Column({ space: 9 }) {
                if (!this.reviewComposeOpen) {
                  Row({ space: 9 }) {
                    Text('写下你的使用感受…').fontSize(12)
                      .fontColor(this.colors().textTertiary).layoutWeight(1).maxLines(1)
                    Text('✎ 写评价').fontSize(12).fontColor(this.colors().accent)
                  }.width('100%').padding({ left: 13, right: 13, top: 12, bottom: 12 })
                    .backgroundColor(this.colors().fill).borderRadius(11)
                    .onClick(() => { this.reviewComposeOpen = true; })
                } else {
                Row({ space: 3 }) {
                  ForEach([1, 2, 3, 4, 5], (star: number) => {
                    Text(star <= this.reviewStars ? '★' : '☆')
                      .fontSize(20).fontColor(this.colors().star)
                      .onClick(() => { this.reviewStars = star; })
                  }, (star: number) => String(star))
                  Blank()
                  Button(this.reviewBusy ? '提交中…' : '发布评价')
                    .height(30).fontSize(11).borderRadius(10)
                    .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
                    .enabled(!this.reviewBusy)
                    .onClick(() => this.sendReview())
                }.width('100%')
                TextArea({ placeholder: this.signedIn ? '写下你的使用感受' : '登录开发者账号后可评价',
                  text: this.reviewText })
                  .height(58).fontSize(12).backgroundColor(this.colors().fill).borderRadius(11)
                  .fontColor(this.colors().text).placeholderColor(this.colors().textTertiary)
                  .caretColor(this.colors().accent)
                  .onChange((value: string) => { this.reviewText = value; })
                if (this.reviewMessage.length > 0) {
                  Text(this.reviewMessage).fontSize(11).fontColor(this.colors().textSecondary)
                    .width('100%').maxLines(3)
                }
                Text('收起').fontSize(11).fontColor(this.colors().textTertiary)
                  .onClick(() => { this.reviewComposeOpen = false; })
                }
              }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
                .backgroundColor(this.colors().surface).borderRadius(17)
              if (this.reviews.length > 0) {
                Column() {
                  ForEach(this.reviews, (review: AppReview) => {
                    Column({ space: 7 }) {
                      Row({ space: 9 }) {
                        if (review.avatarUrl.length > 0) {
                          Image(review.avatarUrl).width(30).height(30).borderRadius(15)
                        } else {
                          Text(review.displayName.length > 0 ? review.displayName.substring(0, 1) : '华')
                            .fontSize(13).fontColor(this.colors().accent).width(30).height(30)
                            .textAlign(TextAlign.Center).backgroundColor(this.colors().accentSoft).borderRadius(15)
                        }
                        Column({ space: 2 }) {
                          Text(review.displayName).fontSize(13).fontWeight(FontWeight.Medium)
                            .fontColor(this.colors().text).maxLines(1)
                          Text(this.formatReviewTime(review.updatedAt))
                            .fontSize(10).fontColor(this.colors().textTertiary).maxLines(1)
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        Text('★'.repeat(review.stars)).fontSize(11).fontColor(this.colors().star)
                      }.width('100%')
                      Text(review.body).fontSize(12).fontColor(this.colors().textBody)
                        .lineHeight(17).width('100%')
                      Divider().color(this.colors().border).strokeWidth(0.5)
                    }.alignItems(HorizontalAlign.Start).width('100%')
                      .padding({ top: 11, bottom: 9 })
                  }, (review: AppReview, index: number) =>
                    String(review.id > 0 ? review.id : index) + ':' + review.updatedAt + ':' + review.stars + ':' +
                    review.displayName + ':' + review.avatarUrl + ':' + review.body)
                  // 分页条：翻页直接向服务端要第 N 页，不再对第一页做本地切片
                  if (this.reviewPageCount() > 1) {
                    Row({ space: 6 }) {
                      Text('上一页')
                        .fontSize(12)
                        .fontColor(this.reviewPage > 1 ? this.colors().accent : this.colors().textTertiary)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .onClick(() => this.fetchReviewPage(this.reviewPage - 1))
                      Text(this.reviewPage + ' / ' + this.reviewPageCount())
                        .fontSize(12).fontColor(this.colors().textSecondary)
                        .layoutWeight(1).textAlign(TextAlign.Center)
                      Text('下一页')
                        .fontSize(12)
                        .fontColor(this.reviewPage < this.reviewPageCount() ?
                          this.colors().accent : this.colors().textTertiary)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .onClick(() => this.fetchReviewPage(this.reviewPage + 1))
                    }.width('100%').padding({ top: 8, bottom: 2 })
                  }
                }.width('100%').padding({ left: 14, right: 14, top: 2, bottom: 6 })
                  .backgroundColor(this.colors().surface).borderRadius(17)
              }
            }.width('100%').padding({ left: 20, right: 20, top: 10, bottom: 115 })
          }.width('100%').height('100%')
          Column({ space: 7 }) {
            // 按钮上方原本还有一行进度文字（downloadMessage）。按钮本身就是进度
            // 显示（Canvas 波浪前沿 + 文案带百分比），上面再挂一行纯文字既重复
            // 又占高度，已去掉。
            Stack({ alignContent: Alignment.Center }) {
              if (this.downloadBusy) {
                Canvas(this.pulseCtx)
                  .width('100%').height(52)
                  .onReady(() => this.paintInstallButton())
              }
              Text(this.installButtonLabel())
                .fontSize(17).fontWeight(FontWeight.Medium)
                .fontColor(this.colors().onAccent)
            }
            .width('100%').height(52)
            .backgroundColor(this.colors().accent)
            .borderRadius(18).clip(true)
            .onClick(() => {
              if (this.downloadBusy) return;
              const task = this.currentInstallTask();
              if (task !== undefined && isPending(task.job.stage)) {
                this.resumeInstall(task.job.id);
                return;
              }
              const installed = this.installedForApp();
              // 已装且没有更新可装：打开；否则安装或更新
              if (installed !== undefined && !this.updateAvailable()) this.openInstalled(installed);
              else this.downloadSelected();
            })
          }.width('86%').margin({ bottom: 20 })
            .backgroundColor('#00000000')
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
    if (this.showReconnect) {
      Column() { this.reconnectSheet() }
        .height('100%').width('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
    }
    }
  }
}
