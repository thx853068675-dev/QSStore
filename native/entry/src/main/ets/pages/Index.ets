import { router, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { LegacyInstalledMigration } from '../jobs/LegacyInstalledMigration';
import { DownloadJobs } from '../jobs/DownloadJobs';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { JobRunner } from '../jobs/JobRunner';
import { NativeJobRuntime } from '../jobs/NativeJobRuntime';
import { retryDelayMs } from '../jobs/RecoveryPlanner';
import { LocalImport } from '../jobs/LocalImport';
import { CatalogApp } from '../data/CatalogApp';
import { StoreClient } from '../data/StoreClient';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { DevEcoLogin, isTransientAuthError } from '../data/DevEcoLogin';
import { LocalSigningIdentity, SigningIdentityRecovery } from '../data/SigningIdentity';
import { AgcClient } from '../data/AgcClient';
import { SubmitDraft, SubmitChoice } from '../data/StoreActions';
import { Palette } from '../theme/Palette';

class AppIcon {
  id: number = 0;
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
}

@Entry
@Component
struct Index {
  // 跟随系统深色模式；变化时先更新调色板再重渲染。
  @StorageProp('darkMode') @Watch('syncPalette') darkMode: boolean = false;
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
  @State private localBusy: boolean = false;
  @State private localMessage: string = '';
  @State private apps: CatalogApp[] = [];
  @State private appIcons: AppIcon[] = [];
  @State private catalogError: string = '';
  @State private catalogLoading: boolean = true;
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
  @State private showSubmit: boolean = false;
  @State private submitUrl: string = '';
  @State private submitDraft: SubmitDraft = new SubmitDraft();
  @State private submitAsset: string = '';
  @State private submitCategory: string = '';
  @State private submitBusy: boolean = false;
  @State private submitMessage: string = '';
  @State private myApps: CatalogApp[] = [];
  @State private myAppsMessage: string = '';
  @State private removingId: number = 0;
  @State private showReconnect: boolean = false;
  @State private reconnectPort: string = '';
  @State private reconnectBusy: boolean = false;
  @State private reconnectMessage: string = '';
  @State private resumeJobId: string = '';
  @State private updates: UpdateTarget[] = [];
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

  syncPalette(): void {
    Palette.dark = this.darkMode;
  }

  aboutToAppear(): void {
    this.syncPalette();
    this.loadJobs();
    this.migrateLegacyJobs();
    this.reconcileInterruptedInstalls();
    this.loadApps();
    this.recoverDownloads();
    this.restoreAccount();
  }

  private async migrateLegacyJobs(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      if (await LegacyInstalledMigration.run(context, store) > 0) await this.loadJobs();
    } catch (error) {
      this.jobsError = '旧版安装记录暂无法导入：' + String(error);
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
      this.recoverSigningIdentity();
      this.loadMyApps();
    } catch (_) {
      this.signedIn = false;
      this.loginMessage = '登录状态已过期，请重新登录';
    } finally {
      this.accountChecked = true;
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
      this.recoverSigningIdentity();
      this.loadMyApps();
    } catch (error) {
      this.loginMessage = String(error);
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
        this.identityMessage = identity ? '已安全复用现有调试证书 · 未占用新槽位' :
          '账号尚无可取回的签名身份；不会自动申请新证书';
        if (identity !== undefined) await this.loadCertificateDetail(identity);
      }
    } catch (error) {
      if (this.signedIn && this.account.userId === account.userId) {
        this.identityMessage = String(error);
      }
    } finally {
      this.identityBusy = false;
    }
  }

  /** 取当前调试证书的名称与到期时间（拿不到不影响签名可用性）。 */
  private async loadCertificateDetail(identity: LocalSigningIdentity): Promise<void> {
    this.certId = identity.certId;
    try {
      const rows = await new AgcClient(this.account).certificates();
      const row = rows.find((item: Record<string, Object>) =>
        String(item['id'] ?? '') === identity.certId);
      if (row === undefined) return;
      const name = String(row['certName'] ?? '');
      this.certLabel = name.length > 0 ? name : '调试证书';
      const expire = Number(row['expireTime'] ?? 0);
      if (Number.isFinite(expire) && expire > 0) {
        const seconds = expire > 100000000000 ? Math.floor(expire / 1000) : expire;
        const date = new Date(seconds * 1000);
        const pad = (n: number): string => n < 10 ? '0' + n : String(n);
        this.certExpiry = date.getFullYear() + '-' + pad(date.getMonth() + 1) +
          '-' + pad(date.getDate());
      }
    } catch (_) {
      // 离线时只显示证书 ID
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
      this.certSheetMessage = '读取失败：' + String(error);
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
      this.certSheetMessage = '已切换到「' + row.name + '」';
      await this.loadCertRows();
      await this.loadCertificateDetail(identity);
    } catch (error) {
      this.certSheetMessage = String(error);
    } finally {
      this.certUsing = '';
    }
  }

  /** 删除一张调试证书（二次确认，说明后果）。 */
  private async deleteCertificate(row: CertRow): Promise<void> {
    if (this.certDeleting.length > 0) return;
    this.certDeleting = row.id;
    this.certSheetMessage = '';
    try {
      await new AgcClient(this.account).deleteCertificates([row.id]);
      this.certSheetMessage = '已删除「' + row.name + '」';
      await this.loadCertRows();
      // 删掉的正好是本机在用的那张：本机身份已失效，清掉待重新核对
      if (row.inUse) {
        await SigningIdentityRecovery.reset(getContext(this) as common.UIAbilityContext);
        this.certReady = false;
        this.certId = '';
        this.certLabel = '';
        this.certExpiry = '';
        this.identityMessage = '本机在用的证书已被删除，请重新登录或核对以重建签名身份';
      }
    } catch (error) {
      this.certSheetMessage = '删除失败：' + String(error);
    } finally {
      this.certDeleting = '';
    }
  }

  /** 证书重置：清掉本机身份缓存，再从账号重新取回。 */
  private async resetCertificate(): Promise<void> {
    if (this.identityBusy) return;
    this.identityBusy = true;
    this.identityMessage = '正在重置本机签名身份…';
    this.certReady = false;
    this.certId = '';
    this.certLabel = '';
    this.certExpiry = '';
    try {
      await SigningIdentityRecovery.reset(getContext(this) as common.UIAbilityContext);
      this.identityBusy = false;
      await this.recoverSigningIdentity();
      this.identityMessage = this.certReady ?
        '已重置并重新取回：' + (this.certLabel.length > 0 ? this.certLabel : this.certId) :
        this.identityMessage;
    } catch (error) {
      this.identityMessage = '重置失败：' + String(error);
    } finally {
      this.identityBusy = false;
    }
  }

  @Builder
  private certDeleteAction(row: CertRow) {
    Column() {
      Text(this.certDeleting === row.id ? '删除中…' : '删除')
        .fontSize(13).fontColor(Palette.onAccent).fontWeight(FontWeight.Medium)
        .maxLines(1)
    }
    .width(64).height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor(this.certDeleting === row.id ? Palette.textTertiary : Palette.danger)
    .borderRadius(14)
    .onClick(() => this.deleteCertificate(row))
  }

  @Builder
  private certSheet() {
    Column({ space: 14 }) {
      Row() {
        Text('AGC 调试证书').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(Palette.text).layoutWeight(1)
        Text('×').fontSize(24).fontColor(Palette.textSecondary)
          .onClick(() => { this.showCertSheet = false; })
      }.width('100%')
      Text('安装时用与本机私钥配对的那张证书重签。')
        .fontSize(11).fontColor(Palette.textTertiary)
        .lineHeight(17).width('100%')
      if (this.certSheetBusy) {
        Row({ space: 10 }) {
          LoadingProgress().width(18).height(18)
          Text('正在读取…').fontSize(12).fontColor(Palette.textSecondary)
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
      } else {
        List({ space: 9 }) {
          ForEach(this.certRows, (row: CertRow) => {
            ListItem() {
              Row({ space: 11 }) {
                Column({ space: 4 }) {
                  Text(row.name).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('ID ' + row.id).fontSize(11).fontColor(Palette.textTertiary)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (row.expiry.length > 0) {
                    Text('到期 ' + row.expiry).fontSize(11)
                      .fontColor(Palette.textTertiary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (row.inUse) {
                  Text('已使用')
                    .fontSize(11).fontColor(Palette.success)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .backgroundColor(Palette.successSoft).borderRadius(8)
                } else {
                  Button(this.certUsing === row.id ? '配对中…' : '使用')
                    .height(30).fontSize(11)
                    .fontColor(Palette.accent).backgroundColor(Palette.accentSoft)
                    .borderRadius(8).enabled(this.certUsing.length === 0)
                    .onClick(() => this.useCertificate(row))
                }
              }.width('100%').padding(13)
                .backgroundColor(Palette.surface).borderRadius(14)
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
      if (this.certSheetMessage.length > 0) {
        Text(this.certSheetMessage).fontSize(12).fontColor(Palette.textSecondary)
          .maxLines(3).width('100%')
      }
      Row({ space: 10 }) {
        Button(this.certSheetBusy ? '读取中…' : '刷新列表')
          .height(40).fontSize(13).layoutWeight(1)
          .backgroundColor(Palette.accentSoft).fontColor(Palette.accent)
          .borderRadius(12).enabled(!this.certSheetBusy)
          .onClick(() => this.loadCertRows())
        Button('关闭')
          .height(40).fontSize(13).layoutWeight(1)
          .backgroundColor(Palette.fill).fontColor(Palette.textSecondary)
          .borderRadius(12)
          .onClick(() => { this.showCertSheet = false; })
      }.width('100%')
    }.padding(21).width('90%').backgroundColor(Palette.bg).borderRadius(23)
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
      this.certMessage = '无法打开浏览器：' + String(error);
    }
  }

  private async loadApps(): Promise<void> {
    this.catalogLoading = true;
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      this.apps = await client.listApps();
      this.appIcons = [];
      for (const app of this.apps) this.loadAppIcon(client, app);
      this.catalogError = '';
    } catch (error) {
      this.catalogError = String(error);
    } finally {
      this.catalogLoading = false;
    }
  }

  private async loadAppIcon(client: StoreClient, app: CatalogApp): Promise<void> {
    const pixels = await client.appIcon(app);
    if (!pixels) return;
    const icon = new AppIcon();
    icon.id = app.id;
    icon.pixels = pixels;
    this.appIcons = this.appIcons.concat([icon]);
  }

  private iconFor(id: number): image.PixelMap | undefined {
    return this.appIcons.find((entry: AppIcon) => entry.id === id)?.pixels;
  }

  private jobTitle(job: InstallJob): string {
    const app = this.apps.find((item: CatalogApp) => item.id === job.appId);
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

  private stageLabel(stage: InstallStage): string {
    switch (stage) {
      case InstallStage.QUEUED: return '准备下载';
      case InstallStage.DOWNLOADING: return '下载中';
      case InstallStage.VERIFIED:
      case InstallStage.PACKAGE_INSPECTED: return '等待签名';
      case InstallStage.PROFILE_READY:
      case InstallStage.SIGNED:
      case InstallStage.SIGNATURE_VERIFIED: return '正在签名';
      case InstallStage.INSTALLING: return '安装中';
      case InstallStage.WAITING_NETWORK: return '等待网络';
      case InstallStage.WAITING_ACCOUNT: return '等待登录';
      case InstallStage.WAITING_DEVICE: return '等待连接';
      case InstallStage.RETRYABLE_ERROR: return '可重试';
      case InstallStage.TERMINAL_ERROR: return '无法安装';
      case InstallStage.INSTALLED: return '已安装';
    }
  }

  private async loadMyApps(): Promise<void> {
    if (!this.signedIn) return;
    try {
      this.myApps = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .myApps(this.account);
      this.myAppsMessage = '';
    } catch (error) {
      this.myAppsMessage = String(error);
    }
  }

  private async prepareSubmit(): Promise<void> {
    if (!this.signedIn) {
      this.submitMessage = '请先在「我的」登录华为开发者账号';
      return;
    }
    this.submitBusy = true;
    this.submitMessage = '正在检查 Release 中的 HAP…';
    try {
      this.submitDraft = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .prepareSubmit(this.submitUrl.trim(), this.account);
      this.submitAsset = this.submitDraft.choices.length > 0 ? this.submitDraft.choices[0].name : '';
      this.submitCategory = this.submitDraft.categories.includes(this.submitDraft.suggestedCategory) ?
        this.submitDraft.suggestedCategory : this.submitDraft.categories[0] ?? '';
      this.submitMessage = this.submitDraft.choices.length + ' 个 HAP 已检查，请确认上架内容';
    } catch (error) {
      this.submitDraft = new SubmitDraft();
      this.submitMessage = String(error);
    } finally {
      this.submitBusy = false;
    }
  }

  private async confirmSubmit(): Promise<void> {
    this.submitBusy = true;
    this.submitMessage = '正在上架…';
    try {
      const app = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .confirmSubmit(this.submitDraft, this.submitAsset, this.submitCategory, this.account);
      this.showSubmit = false;
      this.submitDraft = new SubmitDraft();
      this.submitMessage = '';
      await this.loadApps();
      await this.loadMyApps();
      router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
    } catch (error) {
      this.submitMessage = String(error);
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
          await this.loadMyApps();
          await this.loadApps();
        } catch (error) {
          this.myAppsMessage = String(error);
        } finally {
          this.removingId = 0;
        }
      } }
    });
  }

  // Updating this installer stops its process before HDC can return success.
  // On the next launch, resolve interrupted installs from the device's real
  // version instead of leaving a permanent "installing" task.
  private async reconcileInterruptedInstalls(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const bridge = new HdcDeviceBridge(context);
      const unfinished = (await store.listAll()).filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLING).slice(0, 3);
      for (const job of unfinished) {
        try {
          const installed = await bridge.installedVersion(job.bundleName);
          if (installed === job.versionCode) {
            job.stage = InstallStage.INSTALLED;
            job.lastError = '';
          } else {
            job.stage = InstallStage.RETRYABLE_ERROR;
            job.lastError = '安装尚未完成，点击继续安装';
          }
        } catch (_) {
          job.stage = InstallStage.WAITING_DEVICE;
          job.lastError = '连接无线调试后确认安装结果';
        }
        await store.save(job);
      }
      if (unfinished.length > 0) await this.loadJobs();
    } catch (_) {}
  }

  private async loadJobs(): Promise<void> {
    try {
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      const jobs = await store.listAll();
      this.pendingJobs = jobs.filter((job: InstallJob) =>
        job.stage !== InstallStage.INSTALLED && job.stage !== InstallStage.TERMINAL_ERROR);
      this.installedJobs = jobs.filter((job: InstallJob) =>
        job.stage === InstallStage.INSTALLED);
      this.jobsError = '';
      this.checkInstalledUpdates();
    } catch (error) {
      this.jobsError = String(error);
    }
  }

  /** 已安装应用里哪些有新版本。 */
  /** 「已安装」区块展示的全部条目：轻启装过的 + 商店里探测到的。 */
  private allInstalledJobs(): InstallJob[] {
    return this.recentInstalledJobs().concat(this.storeInstalled);
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
    const client = new StoreClient(context);
    const bridge = new HdcDeviceBridge(context);
    const targets = this.apps.slice();
    const found: InstallJob[] = [];
    let cursor = 0;

    const worker = async (): Promise<void> => {
      while (true) {
        const index = cursor;
        cursor += 1;
        if (index >= targets.length) return;
        const app = targets[index];
        try {
          const releases = await client.listReleases(app.id);
          if (releases.length === 0 || releases[0].assets.length === 0) continue;
          const asset = releases[0].assets[0];
          if (asset.bundleName.length === 0) continue;
          // 轻启自己装过的已经在 installedJobs 里，不重复列
          if (this.installedJobs.some((item: InstallJob) =>
            item.bundleName === asset.bundleName)) continue;
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
  }

  private async checkInstalledUpdates(): Promise<void> {
    const client = new StoreClient(getContext(this) as common.UIAbilityContext);
    const found: UpdateTarget[] = [];
    for (const job of this.recentInstalledJobs()) {
      if (job.appId <= 0 || job.bundleName.length === 0) continue;
      try {
        const releases = await client.listReleases(job.appId);
        let best: UpdateTarget | undefined = undefined;
        for (const release of releases) {
          for (const asset of release.assets) {
            if (asset.bundleName !== job.bundleName) continue;
            if (asset.versionCode <= job.versionCode) continue;
            if (best !== undefined && asset.versionCode <= best.versionCode) continue;
            const target = new UpdateTarget();
            target.bundleName = job.bundleName;
            target.appId = job.appId;
            target.assetName = asset.name;
            target.assetUrl = asset.url;
            target.assetSha256 = asset.sha256;
            target.mirrorUrls = asset.mirrorUrls;
            target.versionCode = asset.versionCode;
            best = target;
          }
        }
        if (best !== undefined) found.push(best);
      } catch (_) {
        // 单个应用查询失败不影响整页
      }
    }
    this.updates = found;
  }

  private updateFor(bundleName: string): UpdateTarget | undefined {
    return this.updates.find((item: UpdateTarget) => item.bundleName === bundleName);
  }

  /** 下载最新版本并接上安装链路。 */
  private async startUpdate(job: InstallJob, target: UpdateTarget): Promise<void> {
    if (this.activeJobId.length > 0) return;
    this.activeJobId = job.id;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const next = await store.enqueue(target.appId, target.assetName, target.assetUrl,
        target.assetSha256, target.mirrorUrls);
      await DownloadJobs.run(context, store, next);
      this.activeJobId = '';
      await this.continueInstall(next);
      // 版本已变，清掉已装版本缓存再重新比对更新
      this.forgetInstalledVersions();
      await this.checkInstalledUpdates();
    } catch (error) {
      this.jobsError = String(error);
    } finally {
      this.activeJobId = '';
    }
  }

  private async openInstalled(job: InstallJob): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      // 轻启自己装的知道入口 ability；探测到的只知道包名，交给系统解析入口
      if (job.mainAbility.length > 0) {
        await context.startAbility({
          bundleName: job.bundleName,
          abilityName: job.mainAbility,
          moduleName: job.moduleName
        });
      } else {
        await context.startAbility({ bundleName: job.bundleName });
      }
    } catch (error) {
      this.jobsError = '无法打开应用：' + String(error);
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
      message: '只移除「' + this.jobTitle(job) + ' · 版本 ' + job.versionCode +
        '」这一条记录，不会卸载应用。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '移除', action: async () => {
        try {
          const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
          await store.forget(job.id);
          await this.loadJobs();
        } catch (error) {
          this.jobsError = String(error);
        }
      } }
    });
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
          job.stage !== InstallStage.WAITING_NETWORK &&
          job.stage !== InstallStage.QUEUED) continue;
        if (job.stage === InstallStage.WAITING_NETWORK &&
          Date.now() - job.updatedAt < retryDelayMs(job.attempt)) continue;
        attempted++;
        try {
          await DownloadJobs.run(context, store, job);
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
      this.localMessage = '已导入 ' + job.bundleName + ' · ' + job.versionCode +
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
    if (this.activeJobId.length > 0) return;
    this.activeJobId = job.id;
    this.resumeJobId = job.id;
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
      } else if (result.stage === InstallStage.INSTALLED) {
        this.jobsError = '';
        this.localMessage = '安装完成';
      } else {
        this.jobsError = result.lastError;
      }
    } catch (error) {
      this.jobsError = String(error);
    } finally {
      this.activeJobId = '';
      await this.loadJobs();
    }
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
      const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
      const job = await store.get(this.resumeJobId);
      if (job) await this.continueInstall(job);
    } catch (error) {
      this.reconnectMessage = String(error);
    } finally {
      this.reconnectBusy = false;
    }
  }

  @Builder
  private heading(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title).fontSize(29).fontWeight(FontWeight.Bold).fontColor(Palette.text)
      Text(subtitle).fontSize(12).fontColor(Palette.textSecondary)
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 16 })
  }

  @Builder
  private discoverPage() {
    Column() {
      Row() {
        Column({ space: 5 }) {
          Text('HARMONYOS').fontSize(10).fontWeight(FontWeight.Bold)
            .fontColor(Palette.accent).letterSpacing(2)
          // 副标题与大标题同行、下对齐
          Row({ space: 9 }) {
            Text('发现').fontSize(30).fontWeight(FontWeight.Bold).fontColor(Palette.text)
            Text('值得安装的应用').fontSize(12).fontColor(Palette.textSecondary)
              .padding({ bottom: 5 })
          }.alignItems(VerticalAlign.Bottom)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('+').fontSize(26).fontColor(Palette.accent).width(44).height(44)
          .backgroundColor(Palette.accentSoft).borderRadius(15)
          .onClick(() => {
            this.submitDraft = new SubmitDraft();
            this.submitMessage = '';
            this.showSubmit = true;
          })
      }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 18 })
      if (this.catalogLoading) {
        LoadingProgress().width(30).height(30).margin({ top: 36 })
      } else if (this.catalogError.length > 0) {
        Column({ space: 12 }) {
          Text('暂时无法读取应用').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text('检查网络后再试一次').fontSize(12).fontColor(Palette.textSecondary)
          Button('重新加载').height(38).fontSize(12).backgroundColor(Palette.accentSoft)
            .fontColor(Palette.accent).onClick(() => this.loadApps())
        }.padding(25).backgroundColor(Palette.surface).borderRadius(20)
          .width('88%').margin({ top: 18 })
      } else {
        List({ space: 0 }) {
          if (this.apps.length === 0) {
            ListItem() {
              Column({ space: 10 }) {
                Text('还没有上架的应用').fontSize(17).fontWeight(FontWeight.Medium)
                  .fontColor(Palette.text)
                Text('点右上角的 ＋，从 GitHub Release 添加第一个 HAP')
                  .fontSize(12).fontColor(Palette.textSecondary).textAlign(TextAlign.Center)
              }.width('100%').padding(26).backgroundColor(Palette.surface).borderRadius(20)
            }
          }
          ForEach(this.apps, (app: CatalogApp) => {
            ListItem() {
              Column() {
                if (app.stars > 100) {
                Column({ space: 17 }) {
                  Row() {
                    Text(app.category.toUpperCase()).fontSize(11)
                      .fontWeight(FontWeight.Bold).fontColor(Palette.borderStrong).layoutWeight(1)
                    Text('★ ' + app.stars).fontSize(12).fontColor(Palette.borderStrong)
                  }.width('100%')
                  Row({ space: 16 }) {
                    if (this.iconFor(app.id)) {
                      Image(this.iconFor(app.id)).width(72).height(72).borderRadius(18)
                    } else {
                      Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                        .fontSize(29).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
                        .width(72).height(72).textAlign(TextAlign.Center)
                        .backgroundColor(Palette.surface).borderRadius(18)
                    }
                    Column({ space: 6 }) {
                      Text(app.displayName).fontSize(23).fontWeight(FontWeight.Bold)
                        .fontColor(Palette.onAccent).maxLines(1)
                      Text(app.summary).fontSize(13).fontColor(Palette.borderStrong).maxLines(2)
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  }.width('100%')
                  Row() {
                    // 不显示上架人，避免被误认成应用作者
                    Text('★ ' + app.stars).fontSize(11)
                      .fontColor(Palette.borderStrong).layoutWeight(1).maxLines(1)
                    Text('查看详情  ›').fontSize(12).fontWeight(FontWeight.Medium)
                      .fontColor(Palette.onAccent)
                  }.width('100%')
                }.alignItems(HorizontalAlign.Start).padding(21).width('100%')
                  .backgroundColor(Palette.accent).borderRadius(26)
                  .margin({ bottom: 20 })
                } else {
                  Column() {
                    Row({ space: 14 }) {
                      if (this.iconFor(app.id)) {
                        Image(this.iconFor(app.id)).width(62).height(62).borderRadius(17)
                      } else {
                        Text(app.displayName.length > 0 ? app.displayName.substring(0, 1) : '应')
                          .fontSize(23).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
                          .width(62).height(62).textAlign(TextAlign.Center)
                          .backgroundColor(Palette.accentSoft).borderRadius(17)
                      }
                      Column({ space: 5 }) {
                        Text(app.displayName).fontSize(17).fontWeight(FontWeight.Bold)
                          .fontColor(Palette.text).maxLines(1)
                        Text(app.summary).fontSize(12).fontColor(Palette.textSecondary).maxLines(1)
                        Row({ space: 7 }) {
                          Text(app.category).fontSize(10).fontColor(Palette.accent)
                            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                            .backgroundColor(Palette.accentSoft).borderRadius(6)
                          Text('★ ' + app.stars).fontSize(11)
                            .fontColor(Palette.textTertiary).maxLines(1)
                        }
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      Text('›').fontSize(23).fontColor(Palette.textTertiary)
                    }.width('100%').padding(15)
                  }.width('100%').backgroundColor(Palette.surface).borderRadius(19)
                    .margin({ bottom: 10 })
                }
              }.width('100%').onClick(() => {
                router.pushUrl({ url: 'pages/Detail', params: { id: app.id } });
              })
            }
          }, (app: CatalogApp) => String(app.id))
        }.padding({ left: 24, right: 24, bottom: 110 }).layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor(Palette.bg)
  }

  @Builder
  private localPage() {
    Column() {
      this.heading('本地安装', '为设备上的 HAP 安心签名安装')
      Column({ space: 0 }) {
        Row() {
          Text('HAP').fontSize(12).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
            .width(55).height(55).textAlign(TextAlign.Center)
            .backgroundColor(Palette.accentSoft).borderRadius(17)
          Text('从文件安装').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(Palette.text).margin({ left: 14 }).layoutWeight(1)
        }.width('100%')
        Text('选择 HAP 后，轻启会核对应用身份与文件完整性，再接续签名和安装。')
          .fontSize(13).fontColor(Palette.textSecondary).lineHeight(21)
          .width('100%').margin({ top: 18, bottom: 22 })
        Button(this.localBusy ? '正在读取文件…' : '选择 HAP 文件')
          .height(48).enabled(!this.localBusy).width('100%')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .backgroundColor(Palette.accent).borderRadius(15)
          .onClick(() => this.pickLocalHap())
        if (this.localMessage.length > 0) {
          Text(this.localMessage).fontSize(12).fontColor(Palette.textBody)
            .width('100%').maxLines(3).margin({ top: 13 })
        }
      }.alignItems(HorizontalAlign.Start).padding(22)
        .width('100%').backgroundColor(Palette.surface).borderRadius(22)
      Row({ space: 11 }) {
        Text('✓').fontSize(13).fontColor(Palette.accent)
          .width(25).height(25).textAlign(TextAlign.Center)
          .backgroundColor(Palette.accentSoft).borderRadius(13)
        Text('安装进度会保存在「管理」中，离开页面也不会丢失')
          .fontSize(12).fontColor(Palette.textSecondary).layoutWeight(1)
      }.width('100%').margin({ top: 18 })
    }.width('100%').height('100%').padding({ left: 24, right: 24 })
      .backgroundColor(Palette.bg)
  }

  @Builder
  private managePage() {
    Column() {
      this.heading('管理', '你的应用与本机已安装')
      List({ space: 11 }) {
        if (this.signedIn) {
          ListItem() {
            Row() {
              Text('我上架的应用').fontSize(19).fontWeight(FontWeight.Bold)
                .fontColor(Palette.text).layoutWeight(1)
              Text('刷新').fontSize(12).fontColor(Palette.accent)
                .onClick(() => this.loadMyApps())
            }.width('100%').padding({ top: 3, bottom: 6 })
          }
          if (this.myAppsMessage.length > 0) {
            ListItem() {
              Text(this.myAppsMessage).fontSize(12).fontColor(Palette.danger)
            }
          }
          if (this.myApps.length === 0 && this.myAppsMessage.length === 0) {
            ListItem() {
              Text('还没有上架应用 · 可在发现页右上角添加')
                .fontSize(12).fontColor(Palette.textTertiary)
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
                    .fontSize(18).fontColor(Palette.accent).textAlign(TextAlign.Center)
                    .width(42).height(42).backgroundColor(Palette.accentSoft).borderRadius(11)
                }
                Column({ space: 4 }) {
                  Text(app.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text).maxLines(1)
                  Text(app.category + ' · ' + app.publisherName).fontSize(11)
                    .fontColor(Palette.textTertiary).maxLines(1)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  .onClick(() => router.pushUrl({ url: 'pages/Detail', params: { id: app.id } }))
                Button(this.removingId === app.id ? '下架中…' : '下架')
                  .height(31).fontSize(11).fontColor(Palette.danger)
                  .backgroundColor(Palette.dangerSoft).borderRadius(10)
                  .enabled(this.removingId === 0)
                  .onClick(() => this.removeMyApp(app))
              }.width('100%').padding(15).backgroundColor(Palette.surface).borderRadius(16)
            }
          }, (app: CatalogApp) => String(app.id))
        }
        if (this.allInstalledJobs().length > 0) {
          ListItem() {
            Text('已安装').fontSize(19).fontWeight(FontWeight.Bold)
              .fontColor(Palette.text).width('100%').padding({ top: 18, bottom: 4 })
          }
          ForEach(this.allInstalledJobs(), (job: InstallJob) => {
            ListItem() {
              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  if (this.iconFor(job.appId)) {
                    Image(this.iconFor(job.appId)).width(46).height(46).borderRadius(13)
                  } else {
                    Text(this.jobTitle(job).length > 0 ? this.jobTitle(job).substring(0, 1) : '应')
                      .fontSize(19).fontColor(Palette.accent).textAlign(TextAlign.Center)
                      .width(46).height(46).backgroundColor(Palette.accentSoft).borderRadius(13)
                  }
                  Column({ space: 4 }) {
                    Text(this.jobTitle(job)).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(Palette.text).maxLines(1)
                    Text(this.updateFor(job.bundleName) !== undefined ?
                      '版本 ' + job.versionCode + ' → ' +
                        this.updateFor(job.bundleName)!.versionCode :
                      '版本 ' + job.versionCode)
                      .fontSize(11)
                      .fontColor(this.updateFor(job.bundleName) !== undefined ?
                        Palette.accent : Palette.textTertiary)
                      .maxLines(1)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    .onClick(() => router.pushUrl({ url: 'pages/Detail', params: { id: job.appId } }))
                  // 右侧只留一个动作：有更新给「更新」，否则给「打开」。
                  if (this.updateFor(job.bundleName) !== undefined) {
                    Button(this.activeJobId === job.id ? '更新中…' : '更新')
                      .height(34).fontSize(12).fontColor(Palette.onAccent)
                      .backgroundColor(Palette.accent).borderRadius(11)
                      .enabled(this.activeJobId.length === 0)
                      .onClick(() => {
                        const target = this.updateFor(job.bundleName);
                        if (target !== undefined) this.startUpdate(job, target);
                      })
                  } else {
                    Button('打开').height(34).fontSize(12)
                      .fontColor(Palette.accent).backgroundColor(Palette.accentSoft)
                      .borderRadius(11).onClick(() => this.openInstalled(job))
                  }
                }.width('100%')
                Row({ space: 10 }) {
                  Text(job.bundleName).fontSize(10).fontColor(Palette.textTertiary)
                    .maxLines(1).layoutWeight(1)
                  if (this.olderInstalledJobs(job.bundleName, job.id).length > 0) {
                    Text((this.expandedInstallBundles.includes(job.bundleName) ? '收起' : '查看') +
                      '过往安装 · ' + this.olderInstalledJobs(job.bundleName, job.id).length)
                      .fontSize(11).fontColor(Palette.textSecondary)
                      .onClick(() => this.toggleInstallHistory(job.bundleName))
                  }
                }.width('100%')
                if (this.expandedInstallBundles.includes(job.bundleName)) {
                  ForEach(this.olderInstalledJobs(job.bundleName, job.id), (older: InstallJob) => {
                    Row({ space: 8 }) {
                      Text('版本 ' + older.versionCode).fontSize(11)
                        .fontColor(Palette.textTertiary).layoutWeight(1)
                    }.width('100%').padding({ top: 8 })
                  }, (older: InstallJob) => older.id)
                }
              }.alignItems(HorizontalAlign.Start).width('100%')
                .padding(15).backgroundColor(Palette.surface).borderRadius(17)
                // 移除记录收进长按，避免右上一排动作按钮把标题挤变形。
                .gesture(LongPressGesture().onAction(() => this.forgetJob(job)))
            }
          }, (job: InstallJob) => job.id)
        }
      }.padding({ left: 24, right: 24, bottom: 110 }).layoutWeight(1)
    }.width('100%').height('100%').backgroundColor(Palette.bg)
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
      Text('任务已保存。连接后会从刚才的步骤继续。')
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
        .height(48).width('100%').enabled(!this.reconnectBusy)
        .backgroundColor(Palette.accent).onClick(() => this.reconnect())
      if (this.reconnectMessage.length > 0) {
        Text(this.reconnectMessage).fontSize(12).fontColor(Palette.textSecondary)
          .width('100%').maxLines(3)
      }
    }.padding(21).width('90%').backgroundColor(Palette.surface).borderRadius(23)
  }

  @Builder
  private submitSheet() {
    Column({ space: 15 }) {
      Row() {
        Text('上架应用').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(Palette.text).layoutWeight(1)
        Text('×').fontSize(27).fontColor(Palette.textSecondary)
          .onClick(() => { if (!this.submitBusy) this.showSubmit = false; })
      }.width('100%')
      TextInput({ placeholder: '作者/仓库，或 gitee.com/作者/仓库', text: this.submitUrl })
        .height(48).onChange((value: string) => { this.submitUrl = value; })
        .fontColor(Palette.text).placeholderColor(Palette.textTertiary)
        .backgroundColor(Palette.fill).caretColor(Palette.accent)
      Button(this.submitBusy && this.submitDraft.token.length === 0 ? '检查中…' : '检查 Release')
        .width('100%').enabled(!this.submitBusy && this.submitUrl.trim().length > 0)
        .onClick(() => this.prepareSubmit())
      if (this.submitDraft.token.length > 0) {
        Text(this.submitDraft.displayName).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor(Palette.text).width('100%')
        Text('选择 HAP').fontSize(13).fontColor(Palette.textSecondary).width('100%')
        ForEach(this.submitDraft.choices, (choice: SubmitChoice) => {
          Row({ space: 8 }) {
            Text(this.submitAsset === choice.name ? '◉' : '○')
              .fontSize(20).fontColor(Palette.accent)
            Column({ space: 3 }) {
              Text(choice.displayName.length > 0 ? choice.displayName : choice.name)
                .fontSize(14).fontColor(Palette.text).maxLines(1)
              Text(choice.name + ' · ' + choice.versionName)
                .fontSize(11).fontColor(Palette.textSecondary).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding(10).backgroundColor(Palette.fill)
            .borderRadius(12).onClick(() => { this.submitAsset = choice.name; })
        }, (choice: SubmitChoice) => choice.name)
        Text('选择分类').fontSize(13).fontColor(Palette.textSecondary).width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.submitDraft.categories, (category: string) => {
              Button(category).height(34)
                .backgroundColor(this.submitCategory === category ? Palette.accent : Palette.border)
                .fontColor(this.submitCategory === category ? Palette.onAccent : Palette.textBody)
                .onClick(() => { this.submitCategory = category; })
            }, (category: string) => category)
          }
        }.scrollable(ScrollDirection.Horizontal).width('100%')
        Button(this.submitBusy ? '上架中…' : '确认上架')
          .width('100%').enabled(!this.submitBusy && this.submitAsset.length > 0 &&
          this.submitCategory.length > 0).onClick(() => this.confirmSubmit())
      }
      if (this.submitMessage.length > 0) {
        Text(this.submitMessage).fontSize(12).fontColor(Palette.textBody)
          .width('100%').maxLines(3)
      }
    }.alignItems(HorizontalAlign.Start).width('92%').padding(20)
      .backgroundColor(Palette.surface).borderRadius(24)
  }

  @Builder
  private minePage() {
    Column() {
      this.heading('我的', '账号、证书与设备')
      Scroll() {
        Column({ space: 16 }) {
          // ── 华为开发者身份 ──
          Column({ space: 15 }) {
            Row({ space: 14 }) {
              if (this.signedIn && this.account.avatarUrl.length > 0) {
                Image(this.account.avatarUrl).width(58).height(58).borderRadius(29)
              } else {
                Text(this.signedIn ? this.account.label.substring(0, 1) : '华')
                  .fontSize(22).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
                  .width(58).height(58).textAlign(TextAlign.Center)
                  .backgroundColor(Palette.accentSoft).borderRadius(29)
              }
              Column({ space: 5 }) {
                Text(this.signedIn ? this.account.label : '华为开发者账号')
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(Palette.text)
                Text(this.sessionNotice.length > 0 ? this.sessionNotice :
                (this.signedIn ? '开发者身份已连接' : '登录后即可上架和评价'))
                  .fontSize(12).fontColor(Palette.textSecondary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')
            if (this.loginMessage.length > 0) {
              Text(this.loginMessage).fontSize(12).fontColor(Palette.textSecondary)
                .maxLines(3).width('100%')
            }
            Button(this.signedIn ? '退出当前账号' : this.loginBusy ? '等待浏览器授权…' : '登录华为开发者账号')
              .height(43).backgroundColor(this.signedIn ? Palette.fill : Palette.accent)
              .fontColor(this.signedIn ? Palette.textSecondary : Palette.onAccent)
              .borderRadius(14).enabled(!this.loginBusy).width('100%')
              .onClick(() => { if (this.signedIn) this.signOut(); else this.login(); })
          }.alignItems(HorizontalAlign.Start).padding(20)
            .width('100%').backgroundColor(Palette.surface).borderRadius(22)

          // ── 证书管理：展示当前证书本体 + 操作 ──
          Text('证书管理').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(Palette.text).width('100%').padding({ left: 4 })
          Column({ space: 14 }) {
            Row({ space: 12 }) {
              Text('证')
                .fontSize(18).fontColor(Palette.accent).textAlign(TextAlign.Center)
                .width(44).height(44).backgroundColor(Palette.accentSoft).borderRadius(12)
              Column({ space: 4 }) {
                Text(this.certLabel.length > 0 ? this.certLabel : '调试证书')
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Palette.text).maxLines(1)
                Text(this.certId.length > 0 ? '证书 ID ' + this.certId : '尚未取回证书')
                  .fontSize(11).fontColor(Palette.textSecondary).maxLines(1)
                if (this.certExpiry.length > 0) {
                  Text('到期 ' + this.certExpiry)
                    .fontSize(11).fontColor(Palette.textSecondary).maxLines(1)
                }
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(this.certReady ? '已配对' : '待申请')
                .fontSize(11)
                .fontColor(this.certReady ? Palette.success : Palette.textSecondary)
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .backgroundColor(this.certReady ? Palette.successSoft : Palette.fill)
                .borderRadius(8)
            }.width('100%')
            Text(this.identityMessage.length > 0 ? this.identityMessage :
              (this.signedIn ? '正在核对账号现有调试证书…' : '登录后自动复用或申请本机签名证书'))
              .fontSize(11).fontColor(Palette.textTertiary).maxLines(3).width('100%')
            Row({ space: 10 }) {
              Button(this.identityBusy ? '重置中…' : '证书重置')
                .height(38).fontSize(12).layoutWeight(1)
                .backgroundColor(Palette.accentSoft).fontColor(Palette.accent)
                .borderRadius(12).enabled(!this.identityBusy && this.signedIn)
                .onClick(() => this.resetCertificate())
              Button('管理 AGC 证书')
                .height(38).fontSize(12).layoutWeight(1)
                .backgroundColor(Palette.fill).fontColor(Palette.textSecondary)
                .borderRadius(12)
                .onClick(() => {
                  this.showCertSheet = true;
                  this.loadCertRows();
                })
            }.width('100%')
            if (this.certMessage.length > 0) {
              Text(this.certMessage).fontSize(11).fontColor(Palette.danger)
                .maxLines(2).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).padding(20)
            .width('100%').backgroundColor(Palette.surface).borderRadius(22)

          // ── 设备连接：已连接只占一行；断线时才给连接按钮 ──
          Text('设备连接').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(Palette.text).width('100%').padding({ left: 4 })
          Column({ space: 13 }) {
            Row({ space: 10 }) {
              Text(this.deviceBusy ? '◌' : (this.deviceConnected ? '✓' : '!'))
                .fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor(this.deviceConnected ? Palette.success :
                  (this.deviceBusy ? Palette.textTertiary : Palette.danger))
              Text(this.deviceBusy ? '正在检测…' :
                (this.deviceConnected ? '无线调试已连接' : '无线调试未连接'))
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Palette.text)
                .layoutWeight(1)
              if (this.deviceConnected) {
                // 已连接就一行，不再显示 UDID
              } else if (!this.deviceBusy) {
                Button('连接')
                  .height(34).fontSize(12).fontColor(Palette.onAccent)
                  .backgroundColor(Palette.accent).borderRadius(11)
                  .onClick(() => { this.reconnectPort = ''; this.showReconnect = true; })
              }
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).padding(18)
            .width('100%').backgroundColor(Palette.surface).borderRadius(22)

          Text('轻启·安装器').fontSize(12).fontColor(Palette.textTertiary)
            .margin({ top: 14, bottom: 8 })
        }.width('88%').padding({ top: 4 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(Palette.bg)
  }

  /**
   * 启动加载页：检查登录态期间显示，替代原来的「先闪一下登录页」。
   * 只有确认需要登录时才切到 loginGate。
   */
  @Builder
  private startupSplash() {
    Column({ space: 22 }) {
      Column({ space: 6 }) {
        Text('轻启').fontSize(38).fontWeight(FontWeight.Bold).fontColor(Palette.text)
        Text('安装器').fontSize(13).fontColor(Palette.textTertiary).letterSpacing(4)
      }.alignItems(HorizontalAlign.Center)
      LoadingProgress().width(28).height(28).color(Palette.accent)
      Text('正在检查登录状态…').fontSize(12).fontColor(Palette.textTertiary)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(Palette.bg)
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
          .fontColor(Palette.text)
        Text('用你自己的证书，把 HarmonyOS 应用装到本机')
          .fontSize(13).fontColor(Palette.textSecondary).textAlign(TextAlign.Center)
      }.alignItems(HorizontalAlign.Center)

      Column({ space: 10 }) {
        Text('为什么必须先登录').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(Palette.text).width('100%')
        Text('HarmonyOS 的安装包必须包含本机设备标识。安装时轻启会用你账号下的 ' +
          'AGC 调试证书与设备授权，在本机重新签名后再装到这台设备。' +
          '证书、设备授权与上架记录都绑定在华为开发者账号上。')
          .fontSize(12).fontColor(Palette.textSecondary).lineHeight(19).width('100%')
      }.alignItems(HorizontalAlign.Start).padding(18).width('100%')
        .backgroundColor(Palette.surface).borderRadius(18)

      Column({ space: 10 }) {
          Button(this.loginBusy ? '等待浏览器授权…' : '登录华为开发者账号')
            .height(48).width('100%').fontSize(15)
            .backgroundColor(Palette.accent).fontColor(Palette.onAccent)
            .borderRadius(14).enabled(!this.loginBusy)
            .onClick(() => this.login())
          if (this.loginMessage.length > 0) {
            Text(this.loginMessage).fontSize(12).fontColor(Palette.danger)
              .textAlign(TextAlign.Center).maxLines(3).width('100%')
          }
        Text('登录会打开浏览器，完成后自动回到轻启')
          .fontSize(11).fontColor(Palette.textTertiary)
      }.width('100%')
    }.width('100%').height('100%').padding({ left: 28, right: 28 })
      .justifyContent(FlexAlign.Center).backgroundColor(Palette.bg)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      // 每个 Tab 一对「线性 + 实心」系统符号：选中态既换形也换色。
      // 之前「发现」和「管理」共用 square_grid_2x2，且只给了 normal。
      TabContent() { this.discoverPage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.compass_circle'))
            .fontColor([Palette.tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.compass_circle_fill'))
            .fontColor([Palette.accent]).fontSize(23)
        }, '发现').iconStyle({ selectedColor: Palette.accent }))
      TabContent() { this.localPage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.folder'))
            .fontColor([Palette.tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.folder_fill'))
            .fontColor([Palette.accent]).fontSize(23)
        }, '本地').iconStyle({ selectedColor: Palette.accent }))
      TabContent() { this.managePage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.square_stack_3d'))
            .fontColor([Palette.tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.square_stack_3d_fill'))
            .fontColor([Palette.accent]).fontSize(23)
        }, '管理').iconStyle({ selectedColor: Palette.accent }))
      TabContent() { this.minePage() }
        .tabBar(BottomTabBarStyle.of({
          normal: new SymbolGlyphModifier($r('sys.symbol.person'))
            .fontColor([Palette.tabIdle]).fontSize(23),
          selected: new SymbolGlyphModifier($r('sys.symbol.person_fill'))
            .fontColor([Palette.accent]).fontSize(23)
        }, '我的').iconStyle({ selectedColor: Palette.accent }))
    }
    .barMode(BarMode.Fixed)
    .vertical(false)
    .barOverlap(true)
    // lightColor 原本是饱和蓝，被 IMMERSIVE 材质压成一坨暗色 —— 底部那块
    // "暗区"。改成随主题的卡片色，材质才是正常的玻璃感。
    .barFloatingStyle({
      lightColor: Palette.surface,
      barSideMargin: 12,
      // 系统导航栏已隐藏，底部不再有安全区，6 会让导航条贴着屏幕边缘。
      barBottomMargin: 20,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      this.currentTab = index;
      if (index === 2) { this.loadJobs(); this.loadMyApps(); }
      if (index === 3) {
        // 设备状态探完再扫「商店已安装」——扫描依赖 connected 与 installedVersion
        this.checkDevice().then(() => this.scanStoreInstalled());
      }
    })
    .width('100%').height('100%')
    if (this.showSubmit) {
      Column() {
        Scroll() { this.submitSheet() }
          .width('100%').constraintSize({ maxHeight: '84%' })
      }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.scrim)
    }
    if (this.showReconnect) {
      Column() { this.reconnectSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.scrim)
    }
    if (this.showCertSheet) {
      Column() { this.certSheet() }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.scrim)
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
