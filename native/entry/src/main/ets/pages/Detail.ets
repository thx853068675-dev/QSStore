import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { CatalogApp } from '../data/CatalogApp';
import { StoreClient } from '../data/StoreClient';
import { ReleaseInfo, HapAsset } from '../data/ReleaseInfo';
import { DownloadJobs } from '../jobs/DownloadJobs';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { JobStore } from '../jobs/JobStore';
import { JobRunner } from '../jobs/JobRunner';
import { NativeJobRuntime } from '../jobs/NativeJobRuntime';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { AppReview } from '../data/StoreActions';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { Palette } from '../theme/Palette';

@Entry
@Component
struct Detail {
  @StorageProp('darkMode') @Watch('syncPalette') darkMode: boolean = false;
  @State private app: CatalogApp = new CatalogApp();
  @State private appIcon: image.PixelMap | null = null;
  @State private loaded: boolean = false;
  @State private error: string = '';
  @State private releases: ReleaseInfo[] = [];
  @State private selectedAsset: HapAsset = new HapAsset();
  @State @Watch('onBusyChanged') private downloadBusy: boolean = false;
  // 按钮自身就是进度显示：进度或忙碌状态变化时重绘一次即可，不需要动画。
  @State @Watch('onPercentChanged') private downloadPercent: number = 0;
  private pulseSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private pulseCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.pulseSettings);
  @State private downloadMessage: string = '';
  @State private reviews: AppReview[] = [];
  /** 评论分页：每页 5 条。 */
  @State private reviewPage: number = 0;
  /** 发布评论默认收起，点编辑按钮再展开。 */
  @State private reviewComposeOpen: boolean = false;
  @State private reviewText: string = '';
  @State private reviewStars: number = 5;
  @State private reviewBusy: boolean = false;
  @State private reviewMessage: string = '';
  @State private account: DeveloperAccount = new DeveloperAccount();
  @State private signedIn: boolean = false;
  @State private installedJobs: InstallJob[] = [];
  @State private expandedReleaseTag: string = '';
  @State private showReconnect: boolean = false;
  @State private reconnectPort: string = '';
  @State private reconnectBusy: boolean = false;
  @State private reconnectMessage: string = '';
  @State private activeInstallId: string = '';
  /** 默认 0 = 最新版本；版本不再平铺，改成下拉选择。 */
  @State private selectedReleaseIndex: number = 0;

  syncPalette(): void {
    Palette.dark = this.darkMode;
  }

  aboutToAppear(): void {
    this.syncPalette();
    this.loadApp();
    this.restoreAccount();
    this.loadInstalledJobs();
  }

  onBusyChanged(): void {
    if (this.downloadBusy) this.paintInstallButton();
  }

  onPercentChanged(): void {
    if (this.downloadBusy) this.paintInstallButton();
  }

  private paintInstallButton(): void {
    const ctx = this.pulseCtx;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) return;
    const ratio = Math.min(Math.max(this.downloadPercent, 0), 100) / 100;

    ctx.clearRect(0, 0, w, h);
    // 槽底
    ctx.fillStyle = Palette.accentSoft;
    ctx.fillRect(0, 0, w, h);
    // 已完成部分
    const front = w * ratio;
    if (front > 0) {
      ctx.fillStyle = Palette.accent;
      ctx.fillRect(0, 0, front, h);
    }
  }

  private async loadInstalledJobs(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const installed = (await store.listAll()).filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLED);
      const bridge = new HdcDeviceBridge(context);
      const verified: InstallJob[] = [];
      for (const job of installed) {
        try {
          if (await bridge.installedVersion(job.bundleName) === job.versionCode) {
            verified.push(job);
          }
        } catch (_) {
          // A disconnected device can still open previously installed apps.
          verified.push(job);
        }
      }
      this.installedJobs = verified;
    } catch (_) {
      this.installedJobs = [];
    }
  }

  private installedForSelection(): InstallJob | undefined {
    return this.installedJobs.find((job: InstallJob) => job.appId === this.app.id &&
      job.bundleName === this.selectedAsset.bundleName &&
      job.versionCode === this.selectedAsset.versionCode &&
      job.mainAbility.length > 0);
  }

  private async openInstalled(job: InstallJob): Promise<void> {
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        bundleName: job.bundleName,
        abilityName: job.mainAbility,
        moduleName: job.moduleName
      });
    } catch (error) {
      this.downloadMessage = '无法打开应用：' + String(error);
    }
  }

  private static readonly REVIEWS_PER_PAGE: number = 5;

  private reviewPageCount(): number {
    const count = Math.ceil(this.reviews.length / Detail.REVIEWS_PER_PAGE);
    return count > 0 ? count : 1;
  }

  private pagedReviews(): AppReview[] {
    const start = this.reviewPage * Detail.REVIEWS_PER_PAGE;
    return this.reviews.slice(start, start + Detail.REVIEWS_PER_PAGE);
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
    return (release.name.length > 0 ? release.name : release.tag) +
      (release.publishedAt.length >= 10 ? '  ·  ' + release.publishedAt.substring(0, 10) : '');
  }

  private releaseOptions(): SelectOption[] {
    return this.releases.map((release: ReleaseInfo) => {
      const label = (release.name.length > 0 ? release.name : release.tag) +
        (release.publishedAt.length >= 10 ? '  ·  ' + release.publishedAt.substring(0, 10) : '');
      return { value: label } as SelectOption;
    });
  }

  /** 评论时间：API 给的是 epoch 秒或毫秒的字符串。 */
  private formatReviewTime(raw: string): string {
    const value = Number(raw);
    if (!Number.isFinite(value) || value <= 0) return '';
    const date = new Date(value < 1000000000000 ? value * 1000 : value);
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    const now = new Date();
    const sameYear = date.getFullYear() === now.getFullYear();
    const monthDay = pad(date.getMonth() + 1) + '-' + pad(date.getDate());
    return (sameYear ? '' : date.getFullYear() + '-') + monthDay;
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
      asset.sha256 === this.selectedAsset.sha256 && asset.name === this.selectedAsset.name);
  }

  private async restoreAccount(): Promise<void> {
    const saved = await AccountSession.load(getContext(this) as common.UIAbilityContext);
    if (saved) { this.account = saved; this.signedIn = true; }
  }

  private selectRelease(index: number): void {
    this.selectedReleaseIndex = index;
    const release = this.releases[index];
    if (release && release.assets.length > 0) this.selectedAsset = release.assets[0];
    this.expandedReleaseTag = '';
  }

  private async loadReviews(): Promise<void> {
    try {
      this.reviews = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .listReviews(this.app.id);
      this.reviewPage = 0;
    } catch (error) {
      this.reviewMessage = String(error);
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
      this.reviews = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .postReview(this.app.id, this.reviewStars, this.reviewText.trim(), this.account);
      this.reviewText = '';
      this.reviewMessage = '评价已发布';
    } catch (error) {
      this.reviewMessage = String(error);
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
      this.releases = await client.listReleases(id);
      await this.loadReviews();
      if (this.releases.length > 0 && this.releases[0].assets.length > 0) {
        this.selectedAsset = this.releases[0].assets[0];
      }
      this.loaded = true;
      this.error = '';
    } catch (error) {
      this.error = String(error);
    }
  }


  private progressForStage(stage: InstallStage): number {
    switch (stage) {
      case InstallStage.VERIFIED: return 70;
      case InstallStage.PACKAGE_INSPECTED: return 74;
      case InstallStage.PROFILE_READY: return 82;
      case InstallStage.SIGNED: return 89;
      case InstallStage.SIGNATURE_VERIFIED: return 93;
      case InstallStage.INSTALLING: return 97;
      case InstallStage.INSTALLED: return 100;
      default: return this.downloadPercent;
    }
  }

  private async resumeInstall(id: string): Promise<void> {
    this.downloadBusy = true;
    this.activeInstallId = id;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const runner = new JobRunner(store,
        new NativeJobRuntime(context, store, this.signedIn ? this.account : undefined,
          new HdcDeviceBridge(context)),
        (stage: InstallStage) => { this.downloadPercent = this.progressForStage(stage); });
      const result = await runner.run(id);
      if (result.stage === InstallStage.INSTALLED) {
        this.downloadPercent = 100;
        this.downloadMessage = '安装完成';
        await this.loadInstalledJobs();
      } else if (result.stage === InstallStage.WAITING_DEVICE) {
        this.downloadMessage = '安装已暂停，重新连接后会从当前步骤继续';
        this.reconnectMessage = '';
        this.showReconnect = true;
      } else if (result.stage === InstallStage.WAITING_ACCOUNT) {
        this.downloadMessage = '请先在「我的」登录华为开发者账号';
      } else {
        this.downloadMessage = result.lastError.length > 0 ? result.lastError :
          '安装任务已保存，可在「管理」中继续';
      }
    } catch (error) {
      this.downloadMessage = String(error);
    } finally {
      this.downloadBusy = false;
    }
  }

  private async reconnect(): Promise<void> {
    this.reconnectBusy = true;
    this.reconnectMessage = '正在连接，请在系统弹窗中信任本机';
    try {
      const port = Number(this.reconnectPort.trim());
      const bridge = new HdcDeviceBridge(getContext(this) as common.UIAbilityContext);
      if (!await bridge.connect(port)) {
        this.reconnectMessage = '未连上此端口，请核对无线调试页显示的端口';
        return;
      }
      this.showReconnect = false;
      this.reconnectMessage = '';
      await this.resumeInstall(this.activeInstallId);
    } catch (error) {
      this.reconnectMessage = String(error);
    } finally {
      this.reconnectBusy = false;
    }
  }

  private async downloadSelected(): Promise<void> {
    const asset = this.selectedAsset;
    if (!/^https:\/\//.test(asset.url) || !/^[0-9a-f]{64}$/.test(asset.sha256)) {
      this.downloadMessage = '该附件缺少可信下载地址或 SHA-256，暂不能下载';
      return;
    }
    this.downloadBusy = true;
    this.downloadPercent = 0;
    this.downloadMessage = '正在下载并校验完整性';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const job = await store.enqueue(this.app.id, asset.name, asset.url,
        asset.sha256, asset.mirrorUrls);
      if (job.stage === InstallStage.QUEUED || job.stage === InstallStage.DOWNLOADING ||
        job.stage === InstallStage.WAITING_NETWORK) {
        await DownloadJobs.run(context, store, job,
          (received: number, total: number) => {
            if (total > 0) {
              this.downloadPercent = Math.min(68, Math.floor(received * 68 / total));
              this.downloadMessage = '正在下载并校验完整性 · ' +
                this.downloadPercent + '%';
            }
          });
      }
      this.downloadPercent = 70;
      this.downloadBusy = false;
      await this.resumeInstall(job.id);
    } catch (error) {
      this.downloadMessage = String(error);
    } finally {
      this.downloadBusy = false;
    }
  }

  @Builder
  private reconnectSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('连接无线调试').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(Palette.text).layoutWeight(1)
        Text('×').fontSize(26).fontColor(Palette.textSecondary)
          .onClick(() => { if (!this.reconnectBusy) this.showReconnect = false; })
      }.width('100%')
      Text('安装进度已保留。连接后会从刚才的步骤继续。')
        .fontSize(13).fontColor(Palette.textSecondary).width('100%')
      Button('打开无线调试设置').height(42).width('100%')
        .backgroundColor(Palette.accentSoft).fontColor(Palette.accent)
        .onClick(() => new HdcDeviceBridge(getContext(this) as common.UIAbilityContext)
          .openWirelessSettings())
      TextInput({ placeholder: '输入无线调试端口', text: this.reconnectPort })
        .type(InputType.Number).height(48)
        .fontColor(Palette.text).placeholderColor(Palette.textTertiary)
        .backgroundColor(Palette.fill).caretColor(Palette.accent)
        .onChange((value: string) => { this.reconnectPort = value; })
      Button(this.reconnectBusy ? '正在连接…' : '连接并继续安装')
        .width('100%').height(48).enabled(!this.reconnectBusy)
        .backgroundColor(Palette.accent).onClick(() => this.reconnect())
      if (this.reconnectMessage.length > 0) {
        Text(this.reconnectMessage).fontSize(12).fontColor(Palette.textSecondary)
          .width('100%').maxLines(3)
      }
    }.padding(21).width('90%').backgroundColor(Palette.surface).borderRadius(23)
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
      this.downloadMessage = '无法打开来源仓库：' + String(error);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      Row() {
        Text('‹').fontSize(30).fontColor(Palette.text).width(38)
          .onClick(() => router.back())
        Text('应用详情').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
      }.width('100%').padding({ left: 18, right: 20, top: 6, bottom: 12 })
      if (this.error.length > 0) {
        Text('无法读取应用详情').fontSize(15).fontColor(Palette.textSecondary)
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
                      .fontSize(28).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
                      .width(74).height(74).textAlign(TextAlign.Center)
                      .backgroundColor(Palette.surface).borderRadius(20)
                  }
                  Column({ space: 7 }) {
                    Text(this.app.displayName).fontSize(25).fontWeight(FontWeight.Bold)
                      .fontColor(Palette.text).maxLines(1)
                    Text(this.app.category).fontSize(11).fontWeight(FontWeight.Medium)
                      .fontColor(Palette.accent).padding({ left: 9, right: 9, top: 5, bottom: 5 })
                      .backgroundColor(Palette.surface).borderRadius(8)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }
                Text(this.app.summary).fontSize(13).fontColor(Palette.textBody)
                  .lineHeight(20).maxLines(3).width('100%')
                Row() {
                  Text('由 ' + this.app.publisherName + ' 上架').fontSize(11)
                    .fontColor(Palette.textSecondary).layoutWeight(1).maxLines(1)
                  Text('★ ' + this.app.stars).fontSize(11)
                    .fontColor(Palette.accent)
                }.width('100%')
              }.alignItems(HorizontalAlign.Start).width('100%')
                .padding(22).backgroundColor(Palette.hero).borderRadius(26)
              // 来源仓库卡片：平台徽章按仓库地址识别，不写死 GitHub
              Column({ space: 10 }) {
                Row({ space: 9 }) {
                  Text(this.repoHostLabel())
                    .fontSize(10).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
                    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                    .backgroundColor(Palette.accentSoft).borderRadius(7)
                  Text('来源仓库').fontSize(11).fontColor(Palette.textTertiary)
                    .layoutWeight(1).maxLines(1)
                  Text('↗').fontSize(17).fontColor(Palette.accent)
                }.width('100%')
                Text(this.repoPath()).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(Palette.text).maxLines(1)
                Text('点击用浏览器打开 ' + this.repoHost())
                  .fontSize(10).fontColor(Palette.textTertiary).maxLines(1)
              }.alignItems(HorizontalAlign.Start).width('100%').padding(16)
                .backgroundColor(Palette.surface).borderRadius(17)
                .onClick(() => this.openRepo())
              Row() {
                Text('版本记录').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(Palette.text).layoutWeight(1)
                Text(String(this.releases.length) + ' 个版本').fontSize(11)
                  .fontColor(Palette.textTertiary)
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
                    .fontColor(Palette.text)
                    .selectedOptionBgColor(Palette.accentSoft)
                    .optionBgColor(Palette.surface)
                    .menuBackgroundColor(Palette.surface)
                    .backgroundColor(Palette.fill)
                    .width('100%')
                    .onSelect((index: number) => this.selectRelease(index))
                  if (this.currentRelease()!.notes.length > 0) {
                    Text(this.displayNotes(this.currentRelease()!.notes, this.currentRelease()!.name))
                      .fontSize(10).fontColor(Palette.textBody)
                      .lineHeight(17)
                      .maxLines(this.expandedReleaseTag === this.currentRelease()!.tag ? 80 : 3)
                      .width('100%')
                    if (this.displayNotes(this.currentRelease()!.notes,
                      this.currentRelease()!.name).length > 125) {
                      Text(this.expandedReleaseTag === this.currentRelease()!.tag ? '收起' : '展开更新内容')
                        .fontSize(11).fontColor(Palette.accent)
                        .onClick(() => {
                          this.expandedReleaseTag =
                            this.expandedReleaseTag === this.currentRelease()!.tag ? '' :
                              this.currentRelease()!.tag;
                        })
                    }
                  }
                  ForEach(this.currentRelease()!.assets, (asset: HapAsset) => {
                    Row({ space: 10 }) {
                      Text(this.selectedAsset.sha256 === asset.sha256 &&
                        this.selectedAsset.name === asset.name ? '已选' : '选择')
                        .fontSize(10).fontColor(this.selectedAsset.sha256 === asset.sha256 &&
                        this.selectedAsset.name === asset.name ? Palette.accent : Palette.textTertiary)
                      Text(asset.name).fontSize(12).fontColor(Palette.textBody)
                        .maxLines(2).layoutWeight(1)
                    }.width('100%').padding({ left: 11, right: 11, top: 9, bottom: 9 })
                      .backgroundColor(this.selectedAsset.sha256 === asset.sha256 &&
                        this.selectedAsset.name === asset.name ? Palette.accentSoft : Palette.fill)
                      .borderRadius(10)
                      .onClick(() => { this.selectedAsset = asset; })
                  }, (asset: HapAsset) => asset.name)
                }.alignItems(HorizontalAlign.Start).width('100%')
                  .padding(16)
                  .backgroundColor(Palette.surface)
                  .borderRadius(18)
                  .border({ width: 1, color: Palette.border })
              }
              Row() {
                Text('用户评价').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(Palette.text).layoutWeight(1)
                Text(String(this.reviews.length) + ' 条').fontSize(11).fontColor(Palette.textTertiary)
              }.width('100%')
              // 应用总分：服务端详情接口返回 rating:{average,count}
              Row({ space: 12 }) {
                Column({ space: 2 }) {
                  Text(this.app.ratingCount > 0 ?
                    this.app.ratingAverage.toFixed(1) : '—')
                    .fontSize(34).fontWeight(FontWeight.Bold)
                    .fontColor(this.app.ratingCount > 0 ? Palette.accent : Palette.textTertiary)
                  Text(this.app.ratingCount > 0 ?
                    this.app.ratingCount + ' 条评分' : '还没有评分')
                    .fontSize(11).fontColor(Palette.textTertiary)
                }.alignItems(HorizontalAlign.Start)
                Column({ space: 4 }) {
                  Row({ space: 2 }) {
                    ForEach([1, 2, 3, 4, 5], (slot: number) => {
                      Text(slot <= Math.round(this.app.ratingAverage) ? '★' : '☆')
                        .fontSize(15).fontColor(Palette.star)
                    }, (slot: number) => String(slot))
                  }
                  Text('满分 5 分').fontSize(10).fontColor(Palette.textTertiary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').padding(14)
                .backgroundColor(Palette.surface).borderRadius(17)
              // 发布区默认收起：收起时只有一行入口，点 ✎ 展开
              Column({ space: 9 }) {
                if (!this.reviewComposeOpen) {
                  Row({ space: 9 }) {
                    Text('写下你的使用感受…').fontSize(12)
                      .fontColor(Palette.textTertiary).layoutWeight(1).maxLines(1)
                    Text('✎ 写评价').fontSize(12).fontColor(Palette.accent)
                  }.width('100%').padding({ left: 13, right: 13, top: 12, bottom: 12 })
                    .backgroundColor(Palette.fill).borderRadius(11)
                    .onClick(() => { this.reviewComposeOpen = true; })
                } else {
                Row({ space: 3 }) {
                  ForEach([1, 2, 3, 4, 5], (star: number) => {
                    Text(star <= this.reviewStars ? '★' : '☆')
                      .fontSize(20).fontColor(Palette.star)
                      .onClick(() => { this.reviewStars = star; })
                  }, (star: number) => String(star))
                  Blank()
                  Button(this.reviewBusy ? '提交中…' : '发布评价')
                    .height(30).fontSize(11).borderRadius(10)
                    .backgroundColor(Palette.accentSoft).fontColor(Palette.accent)
                    .enabled(!this.reviewBusy)
                    .onClick(() => this.sendReview())
                }.width('100%')
                TextArea({ placeholder: this.signedIn ? '写下你的使用感受' : '登录开发者账号后可评价',
                  text: this.reviewText })
                  .height(58).fontSize(12).backgroundColor(Palette.fill).borderRadius(11)
                  .fontColor(Palette.text).placeholderColor(Palette.textTertiary)
                  .caretColor(Palette.accent)
                  .onChange((value: string) => { this.reviewText = value; })
                if (this.reviewMessage.length > 0) {
                  Text(this.reviewMessage).fontSize(11).fontColor(Palette.textSecondary)
                    .width('100%').maxLines(3)
                }
                Text('收起').fontSize(11).fontColor(Palette.textTertiary)
                  .onClick(() => { this.reviewComposeOpen = false; })
                }
              }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
                .backgroundColor(Palette.surface).borderRadius(17)
              if (this.reviews.length > 0) {
                Column() {
                  ForEach(this.pagedReviews(), (review: AppReview) => {
                    Column({ space: 7 }) {
                      Row({ space: 9 }) {
                        if (review.avatarUrl.length > 0) {
                          Image(review.avatarUrl).width(30).height(30).borderRadius(15)
                        } else {
                          Text(review.displayName.length > 0 ? review.displayName.substring(0, 1) : '华')
                            .fontSize(13).fontColor(Palette.accent).width(30).height(30)
                            .textAlign(TextAlign.Center).backgroundColor(Palette.accentSoft).borderRadius(15)
                        }
                        Column({ space: 2 }) {
                          Text(review.displayName).fontSize(13).fontWeight(FontWeight.Medium)
                            .fontColor(Palette.text).maxLines(1)
                          Text(this.formatReviewTime(review.updatedAt))
                            .fontSize(10).fontColor(Palette.textTertiary).maxLines(1)
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        Text('★'.repeat(review.stars)).fontSize(11).fontColor(Palette.star)
                      }.width('100%')
                      Text(review.body).fontSize(12).fontColor(Palette.textBody)
                        .lineHeight(17).width('100%')
                      Divider().color(Palette.border).strokeWidth(0.5)
                    }.alignItems(HorizontalAlign.Start).width('100%')
                      .padding({ top: 11, bottom: 9 })
                  }, (review: AppReview, index: number) =>
                    String(review.id > 0 ? review.id : index) + ':' + review.updatedAt + ':' + review.stars + ':' +
                    review.displayName + ':' + review.avatarUrl + ':' + review.body)
                  // 分页条：每页 5 条
                  if (this.reviewPageCount() > 1) {
                    Row({ space: 6 }) {
                      Text('上一页')
                        .fontSize(12)
                        .fontColor(this.reviewPage > 0 ? Palette.accent : Palette.textTertiary)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .onClick(() => {
                          if (this.reviewPage > 0) this.reviewPage -= 1;
                        })
                      Text((this.reviewPage + 1) + ' / ' + this.reviewPageCount())
                        .fontSize(12).fontColor(Palette.textSecondary)
                        .layoutWeight(1).textAlign(TextAlign.Center)
                      Text('下一页')
                        .fontSize(12)
                        .fontColor(this.reviewPage < this.reviewPageCount() - 1 ?
                          Palette.accent : Palette.textTertiary)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .onClick(() => {
                          if (this.reviewPage < this.reviewPageCount() - 1) this.reviewPage += 1;
                        })
                    }.width('100%').padding({ top: 8, bottom: 2 })
                  }
                }.width('100%').padding({ left: 14, right: 14, top: 2, bottom: 6 })
                  .backgroundColor(Palette.surface).borderRadius(17)
              }
            }.width('100%').padding({ left: 20, right: 20, top: 10, bottom: 115 })
          }.width('100%').height('100%')
          Column({ space: 7 }) {
            if (this.downloadMessage.length > 0) {
              Text(this.downloadMessage).fontSize(12).fontColor(Palette.textBody)
                .maxLines(2).padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor(Palette.fill).borderRadius(10)
            }
            // 整颗按钮就是进度条：安装中由 Canvas 画出波浪前沿，
            // 不再叠一条细进度条。
            Stack({ alignContent: Alignment.Center }) {
              if (this.downloadBusy) {
                Canvas(this.pulseCtx)
                  .width('100%').height(52)
                  .onReady(() => this.paintInstallButton())
              }
              Text(this.installedForSelection() ? '打开应用' :
                this.downloadBusy ? '正在安装  ' + this.downloadPercent + '%' : '安装应用')
                .fontSize(17).fontWeight(FontWeight.Medium)
                .fontColor(Palette.onAccent)
            }
            .width('100%').height(52)
            .backgroundColor(this.downloadBusy ? Palette.accentSoft :
              (this.installedForSelection() ? Palette.accent : Palette.accent))
            .borderRadius(18).clip(true)
            .onClick(() => {
              if (this.downloadBusy) return;
              const installed = this.installedForSelection();
              if (installed) this.openInstalled(installed);
              else this.downloadSelected();
            })
          }.width('86%').margin({ bottom: 20 })
            .backgroundColor('#00000000')
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor(Palette.bg)
    if (this.showReconnect) {
      Column() { this.reconnectSheet() }
        .height('100%').width('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.scrim)
    }
    }
  }
}
