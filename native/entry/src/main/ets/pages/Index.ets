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
import { NativeJobRuntime } from '../jobs/NativeJobRuntime';
import { retryDelayMs } from '../jobs/RecoveryPlanner';
import { LocalImport } from '../jobs/LocalImport';
import { LocalBundles } from '../jobs/LocalBundles';
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
import { Palette } from '../theme/Palette';

class AppIcon {
  id: number = 0;
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
  /** 进行中任务的阶段刷新定时器（-1 表示未在跑）。 */
  private stageTicker: number = -1;
  /** 上一次已渲染的阶段，用来避免无谓的重绘。 */
  private activeStage: InstallStage | undefined = undefined;
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
  /** 正在从目录卡片安装的应用编号（0 表示没有）。 */
  private activeCatalogAppId: number = 0;
  /** 卡片上的下载进度百分比。 */
  @State private catalogInstallPercent: number = 0;
  /** 与设备核对卸载状态。 */
  @State private syncBusy: boolean = false;
  @State private syncMessage: string = '';
  @State private localBusy: boolean = false;
  @State private localMessage: string = '';
  /** 本地页时间轴要展示的任务 id。 */
  @State private localJobId: string = '';
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
  /** 证书即将到期（30 天内）时提示提前重建，别等签名失败。 */
  @State private certExpiringSoon: boolean = false;
  /** 只剩最后一个槽位时的二次确认：为 true 才会真的申请。 */
  @State private certLastSlotConfirmed: boolean = false;
  /** 左滑后等待确认删除的证书 ID。 */
  @State private certConfirmDelete: string = '';

  syncPalette(): void {
    Palette.dark = this.darkMode;
  }

  aboutToAppear(): void {
    this.syncPalette();
    this.loadJobs();
    this.migrateLegacyJobs();
    this.reconcileInterruptedInstalls();
    // 先等缓存画出来，再发起刷新：刷新会重置 appIcons，顺序反了会把刚恢复的图标清掉
    this.loadCatalogFromCache().then(() => this.loadApps());
    this.recoverDownloads();
    this.restoreAccount();
  }

  aboutToDisappear(): void {
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
        this.certLastSlotConfirmed = false;
        this.identityMessage = identity ? '已安全复用现有调试证书 · 未占用新槽位' :
          '账号下还没有与本机配对的调试证书，可点「准备签名身份」申请一张';
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
    if (!this.signedIn || this.identityBusy) return;
    const account = this.account;
    this.identityBusy = true;
    this.certMessage = '';
    this.identityMessage = '正在核对账号现有调试证书…';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const options = new EnrollmentOptions();
      options.allowLastSlot = this.certLastSlotConfirmed;
      const result = await SigningIdentityRecovery.enroll(context, account, options);
      if (!this.signedIn || this.account.userId !== account.userId) return;
      this.certReady = true;
      this.certLastSlotConfirmed = false;
      await this.loadCertificateDetail(result.identity);
      await this.syncIdentityToCloud(context, result.identity);
      const label = this.certLabel.length > 0 ? this.certLabel : result.identity.certId;
      this.identityMessage = result.outcome === EnrollmentOutcome.CREATED ?
        '已申请并配对新的调试证书「' + label + '」，本机私钥未离开设备' :
        '已复用账号现有调试证书「' + label + '」，未占用新槽位';
    } catch (error) {
      if (!this.signedIn || this.account.userId !== account.userId) return;
      const message = String(error);
      // 「只剩最后一个槽位」是可确认的状态，不是失败；把按钮切换成确认态。
      this.certLastSlotConfirmed = message.includes('最后一个调试证书槽位');
      this.identityMessage = message;
    } finally {
      this.identityBusy = false;
    }
  }

  /** 尽力而为地把新身份备份到商店服务，换设备时可直接取回。 */
  private async syncIdentityToCloud(context: common.UIAbilityContext,
    identity: LocalSigningIdentity): Promise<void> {
    try {
      const pem = fileIo.readTextSync(identity.privateKeyPath);
      await new StoreClient(context).publishSigningIdentity(identity.certId, pem, this.account);
    } catch (_) {
      // 备份失败不影响本机签名，换设备时按「无可用身份」重新申请即可
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

  /**
   * 删除一张调试证书。
   *
   * 删除是不可撤销的，而本机私钥只有一把：如果删掉之后账号里再没有证书能与
   * 它配对，这台设备就再也签不出能装上的包了，重建还得占一个新槽位。所以先
   * 找替代证书 —— 找不到直接拒绝，找得到就先切过去再删。
   */
  private async deleteCertificate(row: CertRow): Promise<void> {
    if (this.certDeleting.length > 0) return;
    this.certDeleting = row.id;
    this.certSheetMessage = '正在确认是否有可用替代证书…';
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const replacement = await SigningIdentityRecovery.findReplacement(
        context, this.account, row.id);
      if (replacement === undefined) {
        this.certSheetMessage = '不能删除「' + row.name +
          '」：本机私钥没有别的证书可以配对，删掉后这台设备将无法再签名安装。' +
          '请先申请一张新证书并与本机配对，再删除这一张。';
        return;
      }
      // 删的正好是本机在用的那张：先把本机身份切到替代证书，再交给 AGC 删除，
      // 中途失败也仍然是「有一张能用的证书」，不会停在无证书状态。
      if (row.inUse) {
        const identity = await SigningIdentityRecovery.activate(context, this.account,
          replacement.certId);
        this.certId = identity.certId;
        this.certReady = true;
        await this.loadCertificateDetail(identity);
      }
      await new AgcClient(this.account).deleteCertificates([row.id]);
      this.certSheetMessage = row.inUse ?
        '已先切换到「' + replacement.certName + '」，再删除「' + row.name + '」' :
        '已删除「' + row.name + '」';
      await this.loadCertRows();
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
      if (this.certConfirmDelete.length > 0) {
        Column({ space: 10 }) {
          Text('删除调试证书不可撤销，且需要确认本机仍有可配对的证书。')
            .fontSize(11).fontColor(Palette.textSecondary).width('100%')
          Row({ space: 10 }) {
            Button('确认删除')
              .height(36).fontSize(12).layoutWeight(1)
              .backgroundColor(Palette.danger).fontColor(Palette.onAccent)
              .borderRadius(11).enabled(this.certDeleting.length === 0)
              .onClick(() => {
                const target = this.certRows.find((item: CertRow) =>
                  item.id === this.certConfirmDelete);
                this.certConfirmDelete = '';
                if (target !== undefined) this.deleteCertificate(target);
              })
            Button('取消')
              .height(36).fontSize(12).layoutWeight(1)
              .backgroundColor(Palette.fill).fontColor(Palette.textSecondary)
              .borderRadius(11)
              .onClick(() => { this.certConfirmDelete = ''; })
          }.width('100%')
        }.width('100%').padding(13)
          .backgroundColor(Palette.surface).borderRadius(12)
          .border({ width: 1, color: Palette.danger })
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

  /** 目录每页条数；服务端 /apps 的 page_size 上限为 100。 */
  private static readonly CATALOG_PAGE_SIZE: number = 30;

  private catalogHasMore(): boolean {
    return this.apps.length < this.catalogTotal && !this.catalogMoreBusy;
  }

  private async loadApps(reset: boolean = true): Promise<void> {
    if (reset) {
      this.catalogLoading = true;
      this.catalogPage = 0;
      this.catalogTotal = 0;
    } else if (!this.catalogHasMore()) {
      return;
    }
    this.catalogMoreBusy = true;
    // 输入即搜时请求会重叠：只认最后一次发出的那一个，先到的旧响应直接丢弃，
    // 否则「搜 quiet」的慢响应会盖掉「搜 quietstart」的结果。
    const token = ++this.catalogToken;
    const query = this.activeQuery;
    try {
      const client = new StoreClient(getContext(this) as common.UIAbilityContext);
      const page = await client.listApps(this.catalogPage + 1, Index.CATALOG_PAGE_SIZE,
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
        this.appIcons = this.appIcons.filter((entry: AppIcon) => keep.has(entry.id));
      }
      // 首屏这一轮要等图标拿到再写缓存，否则缓存里只会有目录没有图标；
      // 追加页不需要等，图标照旧异步补上。
      const cacheablePage = reset && this.activeQuery.length === 0;
      const iconLoads: Promise<void>[] = [];
      for (const app of fresh) {
        // 缓存刚恢复过的图标不必再请求一次
        if (this.iconFor(app.id) !== undefined) continue;
        const load = this.loadAppIcon(client, app);
        if (cacheablePage) iconLoads.push(load);
      }
      if (cacheablePage) await Promise.all(iconLoads);
      this.catalogPage = reset ? 1 : this.catalogPage + 1;
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
      this.catalogError = String(error);
    } finally {
      if (token === this.catalogToken) {
        this.catalogMoreBusy = false;
        this.catalogLoading = false;
      }
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

  private async loadAppIcon(client: StoreClient, app: CatalogApp): Promise<void> {
    const bytes = await client.appIconBytes(app);
    if (bytes === undefined) return;
    if (CatalogCache.iconWithinLimit(bytes)) {
      const record = new CachedIcon();
      record.id = String(app.id);
      record.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
      this.pendingIconCache = this.pendingIconCache.concat([record]);
    }
    try {
      const source = image.createImageSource(bytes);
      try {
        const pixels = await source.createPixelMap();
        const icon = new AppIcon();
        icon.id = app.id;
        icon.pixels = pixels;
        this.appIcons = this.appIcons.concat([icon]);
      } finally {
        await source.release();
      }
    } catch (_) {
      // 单张图标解不出来不影响列表
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
    const icons = await CatalogCache.loadIcons(context);
    icons.forEach((bytes: ArrayBuffer, id: number) => {
      try {
        const source = image.createImageSource(bytes);
        source.createPixelMap().then((pixels: image.PixelMap) => {
          const icon = new AppIcon();
          icon.id = id;
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
      case InstallStage.VERIFIED: return '下载完成，正在校验完整性';
      case InstallStage.PACKAGE_INSPECTED: return '已确认应用身份，正在准备设备授权';
      case InstallStage.PROFILE_READY: return '授权就绪，正在签名';
      case InstallStage.SIGNED: return '签名完成，正在校验签名';
      case InstallStage.SIGNATURE_VERIFIED: return '签名有效，正在连接设备';
      case InstallStage.WAITING_NETWORK: return '网络中断，稍后自动重试';
      case InstallStage.WAITING_ACCOUNT: return '等待登录华为开发者账号';
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
    return job.versionName.length > 0 ? job.versionName : String(job.versionCode);
  }

  private jobStatusLine(job: InstallJob): string {
    if (this.activeJobId === job.id) return this.stageLabel(job.stage);
    if (job.stage !== InstallStage.INSTALLED) {
      return job.lastError.length > 0 ? job.lastError : this.stageLabel(job.stage);
    }
    const update = this.updateFor(job.bundleName);
    if (update === undefined) return '版本 ' + this.versionLabel(job);
    const target = update.versionName.length > 0 ? update.versionName :
      String(update.versionCode);
    return '版本 ' + this.versionLabel(job) + ' → ' + target;
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
      this.submitMessage = String(error);
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
      this.syncLocalIcons();
      this.refreshCatalogInstallState();
      this.checkInstalledUpdates();
    } catch (error) {
      this.jobsError = String(error);
    }
  }

  /** 已安装应用里哪些有新版本。 */
  /** 继续第一个未完成的安装任务。 */
  private async resumePending(): Promise<void> {
    if (this.activeJobId.length > 0 || !this.signedIn) return;
    const job = this.pendingJobs[0];
    if (job === undefined) return;
    await this.continueInstall(job);
  }

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
  private catalogCardAction(app: CatalogApp) {
    Column() {
      if (this.activeCatalogAppId === app.id) {
        Column({ space: 4 }) {
          LoadingProgress().width(22).height(22)
          Text(this.catalogInstallPercent > 0 ? this.catalogInstallPercent + '%' : '准备中')
            .fontSize(10).fontColor(Palette.accent).maxLines(1)
        }.width(74).height(46).justifyContent(FlexAlign.Center)
          .backgroundColor(Palette.accentSoft).borderRadius(13)
      } else if (this.installedBundleOf(app.id).length > 0) {
        if (this.updateForApp(app.id) !== undefined) {
          Button('更新')
            .width(74).height(38).fontSize(13).fontColor(Palette.onAccent)
            .backgroundColor(Palette.accent).borderRadius(12)
            .enabled(this.activeCatalogAppId === 0)
            .onClick(() => this.installFromCatalog(app))
        } else {
          Button('打开')
            .width(74).height(38).fontSize(13)
            .fontColor(Palette.accent).backgroundColor(Palette.accentSoft)
            .borderRadius(12)
            .onClick(() => this.openCatalogApp(app))
        }
      } else {
        Button('安装')
          .width(74).height(38).fontSize(13).fontColor(Palette.onAccent)
          .backgroundColor(Palette.accent).borderRadius(12)
          .enabled(this.activeCatalogAppId === 0)
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
   * 走和详情页一样的链路：入队 → 下载校验 → 签名安装。区别只是不用先打开
   * 详情页，所以是一次点击而不是三次。
   */
  private async installFromCatalog(app: CatalogApp): Promise<void> {
    if (this.activeCatalogAppId !== 0) return;
    const asset = app.latestAsset;
    if (asset === undefined || !/^https:\/\//.test(asset.url) ||
      !/^[0-9a-f]{64}$/.test(asset.sha256)) {
      this.jobsError = '「' + app.displayName + '」缺少可信下载地址或 SHA-256';
      return;
    }
    if (!this.signedIn) {
      // 安装必然需要开发者账号，直接把用户送到登录页，比只报一句错有用
      this.jobsError = '安装前需要先登录华为开发者账号，已切到「我的」';
      this.currentTab = Index.TAB_MINE;
      return;
    }
    this.activeCatalogAppId = app.id;
    this.catalogInstallPercent = 0;
    this.jobsError = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const job = await store.enqueue(app.id, asset.name, asset.url, asset.sha256,
        asset.mirrorUrls, asset.versionName);
      if (job.stage === InstallStage.QUEUED || job.stage === InstallStage.DOWNLOADING ||
        job.stage === InstallStage.WAITING_NETWORK) {
        await JobScheduler.runDownload(context, store, job,
          (received: number, total: number) => {
            if (total > 0) {
              this.catalogInstallPercent = Math.min(95, Math.floor(received * 95 / total));
            }
          });
      }
      this.catalogInstallPercent = 100;
      this.activeCatalogAppId = 0;
      await this.loadJobs();
      await this.continueInstall(job);
    } catch (error) {
      this.jobsError = String(error);
    } finally {
      this.activeCatalogAppId = 0;
      this.catalogInstallPercent = 0;
      await this.loadJobs();
    }
  }

  /**
   * 重建目录卡片的安装状态。
   *
   * 数据源按可靠性排序：
   *   1. 轻启自己的安装记录（知道入口 ability，能直接「打开」）
   *   2. 系统 bundleManager 查到的本机版本（同步、免网络、免无线调试）
   * 两者都没有才算未安装。因为第 2 条是本地同步调用，卡片状态在第一次绘制
   * 时就是对的，不用等扫描结果。
   */
  private refreshCatalogInstallState(): void {
    const next = new Map<number, number>();
    for (const app of this.apps) {
      const asset = app.latestAsset;
      if (asset === undefined || asset.bundleName.length === 0) continue;
      const version = LocalBundles.installedVersion(asset.bundleName);
      if (version > 0) next.set(app.id, version);
    }
    this.installedVersions = next;
  }

  /** 该应用在本机的版本号；0 表示没装。 */
  private installedVersionOf(appId: number): number {
    const job = this.allInstalledJobs().find((item: InstallJob) =>
      item.appId === appId && item.bundleName.length > 0);
    const fromJob = job !== undefined ? job.versionCode : 0;
    return Math.max(fromJob, this.installedVersions.get(appId) ?? 0);
  }

  private installedBundleOf(appId: number): string {
    const job = this.allInstalledJobs().find((item: InstallJob) =>
      item.appId === appId && item.bundleName.length > 0);
    if (job !== undefined) return job.bundleName;
    if (this.installedVersionOf(appId) <= 0) return '';
    return this.apps.find((item: CatalogApp) => item.id === appId)?.latestAsset?.bundleName ?? '';
  }

  private installedJobFor(appId: number): InstallJob | undefined {
    const bundleName = this.installedBundleOf(appId);
    if (bundleName.length === 0) return undefined;
    return this.allInstalledJobs().find((item: InstallJob) =>
      item.bundleName === bundleName);
  }

  /** 本机版本落后于目录最新版本时给「更新」。 */
  private updateForApp(appId: number): UpdateTarget | undefined {
    const asset = this.apps.find((item: CatalogApp) => item.id === appId)?.latestAsset;
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
    for (const app of this.apps) {
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
    if (this.activeJobId.length > 0) return;
    this.activeJobId = job.id;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = await JobStore.open(context);
      const next = await store.enqueue(target.appId, target.assetName, target.assetUrl,
        target.assetSha256, target.mirrorUrls, target.versionName);
      await JobScheduler.runDownload(context, store, next);
      this.activeJobId = '';
      await this.continueInstall(next);
      // 版本已变，清掉已装版本缓存再重新比对更新
      this.forgetInstalledVersions();
      this.checkInstalledUpdates();
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

  /**
   * 让进行中的任务把阶段显示出来。
   *
   * JobRunner 每一步都会把 stage 写进 RDB，但页面里的对象不会自己变。这里在
   * 任务运行期间按秒把最新状态取回来，用户就能看到「正在下载」「正在签名」
   * 这样的实时进度，而不是一直停在「继续中…」。
   */
  private startStageTicker(jobId: string): void {
    this.stopStageTicker();
    this.stageTicker = setInterval(async () => {
      try {
        const store = await JobStore.open(getContext(this) as common.UIAbilityContext);
        const fresh = await store.get(jobId);
        if (fresh === undefined) return;
        // 换一个对象才会触发刷新：直接改字段对 @State 数组不可见
        if (fresh.stage === this.activeStage) return;
        this.activeStage = fresh.stage;
        this.jobsError = '';
        this.installedJobs = this.installedJobs.map((job: InstallJob) =>
          job.id === jobId ? fresh : job);
        this.pendingJobs = this.pendingJobs.map((job: InstallJob) =>
          job.id === jobId ? fresh : job);
      } catch (_) {
        // 取不到就保持上一次显示，不打断安装
      }
    }, 1000);
  }

  private stopStageTicker(): void {
    if (this.stageTicker !== -1) {
      clearInterval(this.stageTicker);
      this.stageTicker = -1;
    }
    this.activeStage = undefined;
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
      this.syncMessage = '刷新失败：' + String(error);
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
          job.stage !== InstallStage.WAITING_NETWORK &&
          job.stage !== InstallStage.QUEUED) continue;
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
    if (this.activeJobId.length > 0) return;
    this.activeJobId = job.id;
    this.resumeJobId = job.id;
    // 立刻把初始阶段显示出来，再交给定时器跟进后续阶段
    this.activeStage = job.stage;
    this.startStageTicker(job.id);
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
      this.stopStageTicker();
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
      }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 14 })
      // 搜索框常驻：输入即搜（带防抖），没有单独的搜索按钮
      Row({ space: 9 }) {
        TextInput({ placeholder: '搜索应用名或仓库', text: this.searchText })
          .layoutWeight(1).height(44).fontSize(14)
          .fontColor(Palette.text).placeholderColor(Palette.textTertiary)
          .backgroundColor(Palette.fill).caretColor(Palette.accent)
          .onChange((value: string) => this.onSearchInput(value))
          .onSubmit(() => this.applySearch())
        if (this.searchText.length > 0) {
          Text('✕').fontSize(15).fontColor(Palette.textTertiary)
            .width(34).height(44).textAlign(TextAlign.Center)
            .onClick(() => this.clearSearch())
        }
      }.width('100%').padding({ left: 24, right: 24, bottom: 10 })
      if (this.activeQuery.length > 0) {
        Text('搜索「' + this.activeQuery + '」· ' + this.catalogTotal + ' 个结果')
          .fontSize(11).fontColor(Palette.textTertiary)
          .width('100%').maxLines(1)
          .padding({ left: 24, right: 24, bottom: 8 })
      }
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
                Text(this.activeQuery.length > 0 ? '没有匹配的应用' : '还没有上架的应用')
                  .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Palette.text)
                Text(this.activeQuery.length > 0 ?
                  '换个关键词试试，或清除搜索看全部应用' :
                  '在「管理」页的「我上架的应用」里可以从 GitHub Release 添加')
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
                  }.width('100%').onClick(() => this.openDetail(app.id))
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
                        .onClick(() => this.openDetail(app.id))
                      this.catalogCardAction(app)
                    }.width('100%').padding(15)
                  }.width('100%').backgroundColor(Palette.surface).borderRadius(19)
                    .margin({ bottom: 10 })
                }
              }.width('100%')
            }
          }, (app: CatalogApp) => String(app.id))
          // 目录按服务端分页续取：滚到底自动加载下一页。
          if (this.apps.length < this.catalogTotal) {
            ListItem() {
              Row({ space: 9 }) {
                LoadingProgress().width(19).height(19)
                Text(this.catalogMoreBusy ? '正在加载更多…' :
                  '还有 ' + String(this.catalogTotal - this.apps.length) + ' 个应用')
                  .fontSize(12).fontColor(Palette.textSecondary)
              }.width('100%').justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
            }
          }
        }.padding({ left: 24, right: 24, bottom: 110 }).layoutWeight(1)
          .onReachEnd(() => this.loadMoreApps())
      }
    }.width('100%').height('100%').backgroundColor(Palette.bg)
  }

  @Builder
  private localPage() {
    Scroll() {
      Column() {
        this.heading('本地安装', '为设备上的 HAP 安心签名安装')
        Column({ space: 0 }) {
          // 图标 + 标题居中
          Column({ space: 10 }) {
            Text('HAP').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
              .width(58).height(58).textAlign(TextAlign.Center)
              .backgroundColor(Palette.accentSoft).borderRadius(18)
            Text('从文件安装').fontSize(20).fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
          }.width('100%').alignItems(HorizontalAlign.Center)
          Text('选择 HAP 后，轻启会核对应用身份与文件完整性，再接续签名和安装。')
            .fontSize(13).fontColor(Palette.textSecondary).lineHeight(21)
            .textAlign(TextAlign.Center)
            .width('100%').margin({ top: 16, bottom: 22 })
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
        // 安装流程时间轴：读取 → 核对 → 签名 → 安装
        if (this.localTimelineJob() !== undefined) {
          this.localTimeline(this.localTimelineJob()!)
        }
      }.width('100%').padding({ left: 24, right: 24, bottom: 110 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Off)
      // Scroll 默认把内容垂直居中，内容不满一屏时会浮在中间
      .align(Alignment.Top)
      .backgroundColor(Palette.bg)
  }

  /** 本地页展示哪个任务的流程：本页正在跑的那个，否则最近一次本地任务。 */
  private localTimelineJob(): InstallJob | undefined {
    if (this.localJobId.length > 0) {
      const active = this.installedJobs.concat(this.pendingJobs).find((job: InstallJob) =>
        job.id === this.localJobId);
      if (active !== undefined) return active;
    }
    // 本地导入的任务 id 以 local: 开头，或来源标记为 local
    const local = this.installedJobs.concat(this.pendingJobs).filter((job: InstallJob) =>
      job.sourceUrl === 'local' || job.id.startsWith('local:'));
    if (local.length === 0) return undefined;
    return local.reduce((newest: InstallJob, job: InstallJob) =>
      job.updatedAt > newest.updatedAt ? job : newest);
  }

  /**
   * 安装流程时间轴。
   *
   * 任务每进入一个阶段都会在 RDB 里留时间戳（JobStore.markStage），这里按
   * 时间顺序画出来，能看到「读取 → 核对 → 签名 → 安装」走到哪一步、各步
   * 花了多久。进行中的那一步带转圈。
   */
  @Builder
  private localTimeline(job: InstallJob) {
    Column({ space: 12 }) {
      Row() {
        Text('安装流程').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(Palette.text).layoutWeight(1)
        Text(job.versionName.length > 0 ? job.versionName :
          (job.versionCode > 0 ? String(job.versionCode) : ''))
          .fontSize(11).fontColor(Palette.textTertiary)
      }.width('100%')
      Text(this.jobTitle(job)).fontSize(12).fontColor(Palette.textSecondary)
        .width('100%').maxLines(1)
      ForEach(job.stageHistory, (mark: StageMark, index: number) => {
        Row({ space: 11 }) {
          Column() {
            // 已完成的步骤：实心点；当前步骤：转圈
            if (index === job.stageHistory.length - 1 &&
              job.stage !== InstallStage.INSTALLED) {
              LoadingProgress().width(15).height(15)
            } else {
              Text('✓').fontSize(11).fontColor(Palette.onAccent)
                .width(17).height(17).textAlign(TextAlign.Center)
                .backgroundColor(job.stage === InstallStage.TERMINAL_ERROR ?
                  Palette.danger : Palette.success).borderRadius(9)
            }
          }.width(17).height(17)
          Column({ space: 2 }) {
            Text(this.timelineStepLabel(mark.stage)).fontSize(13)
              .fontColor(Palette.text).maxLines(1)
            Text(Index.formatClock(mark.at) + ' · 用时 ' +
              Index.formatDuration(mark.at, job.stageHistory, index))
              .fontSize(10).fontColor(Palette.textTertiary).maxLines(1)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
      }, (mark: StageMark) => mark.stage + ':' + String(mark.at))
      if (job.lastError.length > 0) {
        Text(job.lastError).fontSize(11).fontColor(Palette.danger)
          .width('100%').maxLines(3)
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(18)
      .backgroundColor(Palette.surface).borderRadius(20).margin({ top: 18 })
  }

  /** 阶段 → 用户看得懂的一步。 */
  private timelineStepLabel(stage: string): string {
    switch (stage as InstallStage) {
      case InstallStage.QUEUED: return '已读取 HAP，等待开始';
      case InstallStage.DOWNLOADING: return '正在下载安装包';
      case InstallStage.VERIFIED: return '文件完整性已校验';
      case InstallStage.PACKAGE_INSPECTED: return '已核对应用身份';
      case InstallStage.PROFILE_READY: return '设备授权已就绪';
      case InstallStage.SIGNED: return '已用本机证书签名';
      case InstallStage.SIGNATURE_VERIFIED: return '签名校验通过';
      case InstallStage.WAITING_NETWORK: return '网络中断，等待重试';
      case InstallStage.WAITING_ACCOUNT: return '等待登录开发者账号';
      case InstallStage.WAITING_DEVICE: return '等待无线调试连接';
      case InstallStage.INSTALLING: return '正在安装到设备';
      case InstallStage.INSTALLED: return '安装完成';
      case InstallStage.RETRYABLE_ERROR: return '出错，可重试';
      case InstallStage.TERMINAL_ERROR: return '无法继续';
      default: return stage;
    }
  }

  private static formatClock(at: number): string {
    const date = new Date(at);
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' +
      pad(date.getSeconds());
  }

  /** 这一步到下一步之间的耗时；最后一步显示距今时间。 */
  private static formatDuration(at: number, marks: StageMark[], index: number): string {
    const next: number = index + 1 < marks.length ? marks[index + 1].at : Date.now();
    const seconds = Math.max(0, Math.round((next - at) / 1000));
    if (seconds < 60) return seconds + ' 秒';
    return Math.floor(seconds / 60) + ' 分 ' + (seconds % 60) + ' 秒';
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
          // 上架入口：从发现页搬到这里，与「我上架的应用」同处一块
          ListItem() {
            Row({ space: 12 }) {
              Text('＋').fontSize(22).fontColor(Palette.accent)
                .width(42).height(42).textAlign(TextAlign.Center)
                .backgroundColor(Palette.accentSoft).borderRadius(13)
              Column({ space: 3 }) {
                Text('上架新应用').fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(Palette.text).maxLines(1)
                Text('从 GitHub Release 添加一个 HAP')
                  .fontSize(11).fontColor(Palette.textTertiary).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text('›').fontSize(20).fontColor(Palette.textTertiary)
            }.width('100%').padding({ left: 12, right: 12, top: 11, bottom: 11 })
              .backgroundColor(Palette.surface).borderRadius(15)
              .onClick(() => this.openSubmitSheet())
          }
          if (this.myAppsMessage.length > 0) {
            ListItem() {
              Text(this.myAppsMessage).fontSize(12).fontColor(Palette.danger)
            }
          }
          if (this.myApps.length === 0 && this.myAppsMessage.length === 0) {
            ListItem() {
              Text('还没有上架应用 · 点上面的「上架新应用」添加')
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
        // 中断任务恢复入口：只在确实有未完成任务时出现，无任务不占版面。
        if (this.jobsError.length > 0) {
          ListItem() {
            Text('安装记录暂不可用：' + this.jobsError).fontSize(12)
              .fontColor(Palette.danger).width('100%').padding(13)
              .backgroundColor(Palette.dangerSoft).borderRadius(15)
          }
        } else if (this.pendingJobs.length > 0) {
          ListItem() {
            Row({ space: 10 }) {
              Text('!').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Palette.accent)
              Column({ space: 3 }) {
                Text(this.pendingJobs.length + ' 个安装未完成').fontSize(13)
                  .fontWeight(FontWeight.Medium).fontColor(Palette.text).maxLines(1)
                Text(this.activeJobId.length > 0 ?
                  this.jobTitle(this.pendingJobs[0]) + ' · ' +
                    this.stageLabel(this.pendingJobs[0].stage) :
                  (this.pendingJobs.length > 1 ?
                    '将依次继续：' + this.jobTitle(this.pendingJobs[0]) :
                    this.jobTitle(this.pendingJobs[0])))
                  .fontSize(11).fontColor(this.activeJobId.length > 0 ?
                    Palette.accent : Palette.textTertiary).maxLines(2)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button(this.activeJobId.length > 0 ? '继续中…' : '继续')
                .height(32).fontSize(12).fontColor(Palette.onAccent)
                .backgroundColor(Palette.accent).borderRadius(10)
                .enabled(this.activeJobId.length === 0 && this.signedIn)
                .onClick(() => this.resumePending())
            }.width('100%').padding(13)
              .backgroundColor(Palette.surface).borderRadius(15)
          }
        }
        if (this.allInstalledJobs().length > 0) {
          ListItem() {
            Row() {
              Text('已安装').fontSize(19).fontWeight(FontWeight.Bold)
                .fontColor(Palette.text).layoutWeight(1)
              // 刷新：与设备核对一遍，顺手清掉设备上已经卸载的记录。
              // 按钮本身就是状态——转圈时不给再点。
              if (this.syncBusy) {
                LoadingProgress().width(20).height(20)
              } else {
                Text('↻').fontSize(19).fontColor(Palette.accent)
                  .width(32).height(32).textAlign(TextAlign.Center)
                  .onClick(() => this.refreshInstalled())
              }
            }.width('100%').padding({ top: 18, bottom: 4 })
          }
          if (this.syncMessage.length > 0) {
            ListItem() {
              Text(this.syncMessage).fontSize(11).fontColor(Palette.textTertiary)
                .width('100%').maxLines(3).padding({ bottom: 4 })
            }
          }
          ForEach(this.allInstalledJobs(), (job: InstallJob) => {
            ListItem() {
              Column({ space: 10 }) {
                Row({ space: 12 }) {
                  if (this.jobIcon(job)) {
                    Image(this.jobIcon(job)).width(46).height(46).borderRadius(13)
                  } else {
                    Text(this.jobTitle(job).length > 0 ? this.jobTitle(job).substring(0, 1) : '应')
                      .fontSize(19).fontColor(Palette.accent).textAlign(TextAlign.Center)
                      .width(46).height(46).backgroundColor(Palette.accentSoft).borderRadius(13)
                  }
                  Column({ space: 4 }) {
                    Text(this.jobTitle(job)).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(Palette.text).maxLines(1)
                    Text(this.jobStatusLine(job))
                      .fontSize(11)
                      .fontColor(this.activeJobId === job.id ? Palette.accent :
                        (this.updateFor(job.bundleName) !== undefined ? Palette.accent :
                          Palette.textTertiary))
                      .maxLines(2)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    .onClick(() => router.pushUrl({ url: 'pages/Detail', params: { id: job.appId } }))
                  // 正在跑的任务给一个转圈，避免看起来像卡住
                  if (this.activeJobId === job.id) {
                    LoadingProgress().width(20).height(20)
                  }
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
                if (this.olderInstalledJobs(job.bundleName, job.id).length > 0) {
                  Row() {
                    Text((this.expandedInstallBundles.includes(job.bundleName) ? '收起' : '查看') +
                      '过往安装 · ' + this.olderInstalledJobs(job.bundleName, job.id).length)
                      .fontSize(11).fontColor(Palette.textSecondary)
                      .onClick(() => this.toggleInstallHistory(job.bundleName))
                  }.width('100%')
                }
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
          .fontColor(Palette.text)
          .selectedOptionBgColor(Palette.accentSoft)
          .optionBgColor(Palette.surface)
          .menuBackgroundColor(Palette.surface)
          .backgroundColor(Palette.fill)
          .width('100%')
          .enabled(!this.submitBusy)
          .onSelect((index: number) => {
            this.submitCategoryIndex = index;
            this.submitCategory = this.submitDraft.categories[index] ?? '';
          })
        if (this.submitStateLabel().length > 0) {
          Text(this.submitStateLabel()).fontSize(11)
            .fontColor(this.submitExisting === Index.SUBMIT_STATE_OTHER ?
              Palette.danger : Palette.textSecondary)
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
            // 还没有可用证书时给出唯一的申请入口：复用优先，确无可用证书才占槽位。
            if (this.signedIn && !this.certReady) {
              Button(this.identityBusy ? '正在准备…' :
                (this.certLastSlotConfirmed ? '占用最后槽位并申请' : '准备签名身份'))
                .height(42).width('100%').fontSize(13)
                .backgroundColor(this.certLastSlotConfirmed ? Palette.danger : Palette.accent)
                .fontColor(Palette.onAccent).borderRadius(12)
                .enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
            // 证书快到期时提前重建：过期后签名会直接被设备拒绝。
            if (this.certReady && this.certExpiringSoon) {
              Text('证书将于 ' + this.certExpiry + ' 到期，建议现在重建')
                .fontSize(11).fontColor(Palette.danger).maxLines(2).width('100%')
              Button(this.identityBusy ? '正在重建…' :
                (this.certLastSlotConfirmed ? '占用最后槽位并重建' : '重建签名身份'))
                .height(38).width('100%').fontSize(12)
                .backgroundColor(this.certLastSlotConfirmed ? Palette.danger : Palette.accentSoft)
                .fontColor(this.certLastSlotConfirmed ? Palette.onAccent : Palette.accent)
                .borderRadius(12).enabled(!this.identityBusy)
                .onClick(() => this.prepareSigningIdentity())
            }
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
