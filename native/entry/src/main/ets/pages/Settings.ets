import { common, bundleManager } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { AppearanceMode, AppearancePreferences } from '../data/AppearancePreferences';
import { AppLanguage, AppLanguagePreferences } from '../data/AppLanguagePreferences';
import { MaterialMode, MaterialPreferences } from '../data/MaterialPreferences';
import { SettingsCache } from '../data/SettingsCache';
import { errorText } from '../jobs/ErrorText';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout, StorePageHeader } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { CloudBackupConsent } from '../data/CloudBackupConsent';
import { SigningIdentityRecovery } from '../data/SigningIdentity';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { GitHubMirrorEditor, GitHubMirrorView } from '../data/GitHubMirrorEditor';
import { DownloadProxyPreferences, DownloadProxySetting } from '../data/DownloadProxyPreferences';
import { DownloadProxyProbe } from '../data/DownloadProxyProbe';
import { UpdatePushDialog } from '../components/UpdatePushDialog';
import { I18n } from '../data/I18n';

@Entry
@Component
struct Settings {
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('appearanceMode') private mode: string = 'system';
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('appLanguage') private appLanguage: string = 'zh';
  @State private materialMenuOpen: boolean = false;
  @State private languageMenuOpen: boolean = false;
  @State private languageBusy: boolean = false;
  @State private materialBusy: boolean = false;
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @StorageProp('windowWidth') private windowWidth: number = 0;
  @StorageProp('windowHeight') private windowHeight: number = 0;
  @StorageProp('navigationBottomInset') private navigationBottomInset: number = 0;
  @State private visible: boolean = true;
  @State private appearanceBusy: boolean = false;
  @State private appearanceMenuOpen: boolean = false;
  @State private cacheBusy: boolean = false;
  @State private cacheReading: boolean = true;
  @State private cacheSize: number = 0;
  @State private version: string = '';
  @State private versionCode: string = '';
  @State private backupEnabled: boolean = false;
  @State private backupBusy: boolean = false;
  @State private backupAccountLabel: string = '';
  @State private privacyAllowed: boolean = false;
  @State private privacyBusy: boolean = false;
  @State private mirror: GitHubMirrorView = new GitHubMirrorView();
  @State private proxyEnabled: boolean = false;
  @State private proxyOpen: boolean = false;
  @State private proxyProtocol: string = 'http';
  @State private proxyHost: string = '127.0.0.1';
  @State private proxyPort: string = '7890';
  @State private proxyStatus: string = '';
  @State private proxyLatency: number = 0;
  private proxyTestedAddress: string = '';
  @State private proxyBusy: boolean = false;
  @State private mirrorChoicesOpen: boolean = false;
  @State private pushDialogOpen: boolean = false;
  private mirrorIssueOpen: boolean = false;
  private static readonly MIRROR_DEFAULTS: string[] = ['https://gh-proxy.org/', 'https://ghfast.top/'];
  private mirrorEditor: GitHubMirrorEditor | undefined = undefined;
  private backupAccount: DeveloperAccount | undefined = undefined;
  private privacySubscription: number = -1;
  private disposed: boolean = false;
  private returning: boolean = false;
  private languageChanged: boolean = false;
  private backTimer: number = -1;

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  aboutToAppear(): void {
    this.disposed = false;
    this.readCache();
    DownloadProxyPreferences.load(getContext(this) as common.UIAbilityContext).then((value: DownloadProxySetting) => {
      if (!this.disposed) {
        this.proxyEnabled = value.enabled;
        const parsed = /^(http|socks5):\/\/(\[[^\]]+\]|[^:]+):(\d+)$/.exec(value.address);
        if (parsed) { this.proxyProtocol = parsed[1]; this.proxyHost = parsed[2]; this.proxyPort = parsed[3]; }
      }
    }).catch(() => {});
    this.mirrorEditor = new GitHubMirrorEditor(getContext(this) as common.UIAbilityContext,
      (view: GitHubMirrorView) => {
        if (this.disposed) return;
        if (!view.enabled) this.mirrorChoicesOpen = false;
        if (view.enabled !== this.mirror.enabled) {
          this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.mirror = view; });
        } else { this.mirror = view; }
      });
    this.mirrorEditor.load();
    if (PrivacyConsent.isManaged()) {
      const context = getContext(this) as common.UIAbilityContext;
      PrivacyConsent.configure(context);
      this.privacyAllowed = PrivacyConsent.isBusinessAllowed();
      this.privacySubscription = PrivacyConsent.subscribe(() => {
        if (!this.disposed) this.privacyAllowed = PrivacyConsent.isBusinessAllowed();
      });
      this.readBackupChoice();
    }
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        if (!this.disposed) { this.version = info.versionName; this.versionCode = String(info.versionCode); }
      }).catch(() => { if (!this.disposed) this.version = I18n.t('暂时无法读取'); });
  }
  aboutToDisappear(): void {
    this.proxyOpen = false;
    this.pushDialogOpen = false;
    this.mirrorChoicesOpen = false;
    this.mirrorEditor?.dispose();
    this.mirrorEditor = undefined;
    this.materialMenuOpen = false;
    this.languageMenuOpen = false;
    if (this.privacySubscription !== -1) PrivacyConsent.unsubscribe(this.privacySubscription);
    this.privacySubscription = -1;
    this.disposed = true; this.visible = false; this.appearanceMenuOpen = false;
    if (this.backTimer !== -1) clearTimeout(this.backTimer);
  }
  onPageShow(): void { if (!this.disposed && !this.returning) this.visible = true; }
  onPageHide(): void {
    this.visible = false; this.appearanceMenuOpen = false; this.materialMenuOpen = false;
    this.languageMenuOpen = false;
    this.mirrorChoicesOpen = false;
    this.mirrorEditor?.pause();
  }
  onBackPress(): boolean {
    if (this.proxyOpen) { this.proxyOpen = false; return true; }
    if (this.pushDialogOpen) { this.pushDialogOpen = false; return true; }
    if (this.languageMenuOpen) { this.languageMenuOpen = false; return true; }
    if(StorePageMotion.dismissDevicePanel?.())return true; this.back(); return true; }

  private back(): void {
    if (this.languageMenuOpen) { this.languageMenuOpen = false; return; }
    if (this.mirrorChoicesOpen) { this.mirrorChoicesOpen = false; return; }
    if (this.materialMenuOpen) { this.materialMenuOpen = false; return; }
    if (this.appearanceMenuOpen) { this.appearanceMenuOpen = false; return; }
    if (this.disposed || this.returning) return;
    this.returning = true;
    this.visible = false;
    // 收起材质浮层后只回到主页面，合并按钮和系统手势的重复返回回调。
    StorePageMotion.prepare();
    if (this.languageChanged) {
      // 语言切换后 router.back 会复用栈里的旧首页，必须换成新实例。
      router.clear();
      router.replaceUrl({ url: 'pages/Index' });
      return;
    }
    this.backTimer = setTimeout(() => { if (!this.disposed) router.back({ url: 'pages/Index' }); }, 32);
  }

  private async changeAppearance(mode: AppearanceMode): Promise<void> {
    if (this.appearanceBusy || mode === this.mode) return;
    this.appearanceBusy = true;
    try { await AppearancePreferences.save(getContext(this) as common.UIAbilityContext, mode); }
    catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
    finally { if (!this.disposed) this.appearanceBusy = false; }
  }

  private selectAppearance(mode: AppearanceMode): void {
    this.appearanceMenuOpen = false;
    this.changeAppearance(mode);
  }

  private async selectMaterial(mode: MaterialMode): Promise<void> {
    this.materialMenuOpen = false;
    if (this.materialBusy || mode === this.materialMode) return;
    this.materialBusy = true;
    try { await MaterialPreferences.save(getContext(this) as common.UIAbilityContext, mode); }
    catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
    finally { if (!this.disposed) this.materialBusy = false; }
  }

  private async selectLanguage(language: AppLanguage): Promise<void> {
    this.languageMenuOpen = false;
    if (this.languageBusy || language === AppLanguagePreferences.current()) return;
    this.languageBusy = true;
    try {
      await AppLanguagePreferences.save(getContext(this) as common.UIAbilityContext, language);
      this.languageChanged = true;
      if (!this.disposed) promptAction.showToast({ message: I18n.t('界面语言已切换') });
      // ArkUI 只更新显式依赖 appLanguage 的节点；已渲染的文案不会因静态查表
      // 重算。换掉整个首页是最可靠的做法，也让用户立即看到生效结果。
      setTimeout(() => {
        if (this.disposed || this.returning) return;
        this.returning = true;
        this.visible = false;
        StorePageMotion.prepare();
        router.clear();
        router.replaceUrl({ url: 'pages/Index' });
      }, 360);
    } catch (error) {
      if (!this.disposed) promptAction.showToast({ message: errorText(error) });
    } finally {
      if (!this.disposed) this.languageBusy = false;
    }
  }

  private async readCache(): Promise<void> {
    const size = await SettingsCache.size(getContext(this) as common.UIAbilityContext);
    if (!this.disposed) { this.cacheSize = size; this.cacheReading = false; }
  }

  private async cleanCache(): Promise<void> {
    if (this.cacheBusy) return;
    this.cacheBusy = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const before = await SettingsCache.size(context);
      await SettingsCache.clean(context);
      const after = await SettingsCache.size(context);
      if (!this.disposed) {
        this.cacheSize = after;
        const remaining = after > 0 ? I18n.t('，暂保留 ') + SettingsCache.format(after) : '';
        promptAction.showToast({ message: before > after ? I18n.t('占用减少 ') + SettingsCache.format(before - after) + remaining :
          (after > 0 ? I18n.t('清理完成，当前占用 ') + SettingsCache.format(after) : I18n.t('暂无可清理的闲置文件')) });
      }
    } catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
    finally { if (!this.disposed) this.cacheBusy = false; }
  }

  private async readBackupChoice(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountSession.load(context);
      const enabled = account ? await CloudBackupConsent.selected(context, account) : false;
      if (this.disposed) return;
      this.backupAccount = account;
      this.backupAccountLabel = account?.label ?? '';
      this.backupEnabled = enabled;
    } catch (_) {
      if (!this.disposed) {
        this.backupAccount = undefined; this.backupAccountLabel = ''; this.backupEnabled = false;
      }
    }
  }

  private async changeBackup(enabled: boolean): Promise<void> {
    if (this.backupBusy || enabled === this.backupEnabled) return;
    this.backupBusy = true;
    // Keep Toggle controlled while confirmation is open; finally restores the durable choice.
    this.backupEnabled = enabled;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const account = await AccountSession.load(context);
      if (!account || account.userId !== this.backupAccount?.userId) {
        throw new Error(I18n.t('请先登录当前华为开发者账号，再选择云备份'));
      }
      if (enabled) {
        if (!await PrivacyConsent.ensureConsent(context)) return;
        const result = await promptAction.showDialog({ title: I18n.t('启用签名材料云备份？'),
          message: I18n.t('仅对当前账号启用。私钥将上传到轻启安装器的商店服务器，服务器能够解密；启用后也可读取并恢复该账号以前保存的云端材料。停用不会删除服务器已有备份。'),
          buttons: [{ text: I18n.t('取消'), color: this.colors().textSecondary },
            { text: I18n.t('同意并启用'), color: this.colors().accent }] });
        if (result.index !== 1 || this.disposed) return;
        const current = await AccountSession.load(context);
        if (!current || current.userId !== account.userId) throw new Error(I18n.t('账号已变化，请重新选择'));
      }
      await CloudBackupConsent.setEnabled(context, account, enabled);
      if (!this.disposed) this.backupEnabled = enabled;
      if (enabled) {
        const synced = await SigningIdentityRecovery.synchronizeBackup(context, account);
        if (!this.disposed) promptAction.showToast({ message: synced ? I18n.t('云备份已启用并完成同步') :
          I18n.t('云备份已启用，生成签名材料后再同步') });
      } else if (!this.disposed) {
        promptAction.showToast({ message: I18n.t('已停用云备份，本机材料保留；服务器已有备份未删除') });
      }
    } catch (error) {
      if (!this.disposed) promptAction.showToast({ message: errorText(error) });
    } finally {
      if (!this.disposed) { await this.readBackupChoice(); this.backupBusy = false; }
    }
  }

  private async openPrivacy(): Promise<void> {
    try {
      const links = PrivacyConsent.links();
      const link = links.find((item) => item.type === 1) ?? links[0];
      if (!link || !/^https:\/\//.test(link.url)) {
        throw new Error(PrivacyConsent.lastError() || I18n.t('当前版本尚未关联托管隐私声明'));
      }
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData', uri: link.url });
    } catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
  }

  private async changePrivacy(): Promise<void> {
    if (this.privacyBusy) return;
    this.privacyBusy = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      if (!PrivacyConsent.isBusinessAllowed()) {
        await PrivacyConsent.ensureConsent(context);
      } else {
        const result = await promptAction.showDialog({ title: I18n.t('撤回隐私同意？'),
          message: I18n.t('将停止相关数据处理并停用云备份。本机材料会保留；商店服务器已有资料和备份不会自动删除。'),
          buttons: [{ text: I18n.t('取消'), color: this.colors().textSecondary },
            { text: I18n.t('撤回'), color: this.colors().danger }] });
        if (result.index !== 1 || this.disposed) return;
        PrivacyConsent.withdraw();
        const account = await AccountSession.load(context);
        if (account) await CloudBackupConsent.setEnabled(context, account, false);
        if (!this.disposed) this.backupEnabled = false;
      }
      if (!this.disposed) this.privacyAllowed = PrivacyConsent.isBusinessAllowed();
    } catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
    finally { if (!this.disposed) this.privacyBusy = false; }
  }

  private openMirrorChoices(): void {
    if (this.disposed || this.returning || !this.visible || !this.mirror.ready || !this.mirror.enabled) return;
    this.mirrorChoicesOpen = true;
  }

  private async saveDownloadProxy(enabled: boolean): Promise<void> {
    if (this.proxyBusy) return;
    this.proxyBusy = true;
    try {
      if (!enabled) {
        const context = getContext(this) as common.UIAbilityContext;
        const previous = await DownloadProxyPreferences.load(context);
        await DownloadProxyPreferences.save(context, false, previous.address);
        if (!this.disposed) { this.proxyEnabled = false; this.proxyLatency = 0; this.proxyTestedAddress = ''; this.proxyStatus = I18n.t('代理已关闭'); }
        return;
      }
      const address = DownloadProxyPreferences.compose(this.proxyProtocol, this.proxyHost, this.proxyPort);
      if (this.proxyProtocol === 'socks5') {
        this.proxyStatus = I18n.t('测速中…');
        const latency = await DownloadProxyProbe.latency(this.proxyProtocol, this.proxyHost.trim(), Number(this.proxyPort));
        await DownloadProxyPreferences.save(getContext(this) as common.UIAbilityContext, true, address);
        if (!this.disposed) { this.proxyEnabled = true; this.proxyTestedAddress = address; this.proxyLatency = latency; this.proxyStatus = ''; }
        return;
      }
      await DownloadProxyPreferences.save(getContext(this) as common.UIAbilityContext, true, address);
      if (!this.disposed) {
        this.proxyEnabled = true; this.proxyLatency = 0; this.proxyStatus = '';
      }
      const latency = await DownloadProxyProbe.latency(this.proxyProtocol, this.proxyHost.trim(), Number(this.proxyPort));
      if (!this.disposed) { this.proxyTestedAddress = address; this.proxyLatency = latency; this.proxyStatus = ''; }
    } catch (error) { if (!this.disposed) { this.proxyLatency = 0; this.proxyStatus = errorText(error); } }
    finally { if (!this.disposed) this.proxyBusy = false; }
  }

  private async openDownloadProxy(): Promise<void> {
    if (this.proxyBusy) return;
    this.proxyOpen = true; this.proxyBusy = true; this.proxyStatus = '';
    try {
      const saved = await DownloadProxyPreferences.load(getContext(this) as common.UIAbilityContext);
      if (this.disposed || !this.proxyOpen) return;
      this.proxyEnabled = saved.enabled;
      if (!saved.enabled || saved.address !== this.proxyTestedAddress) this.proxyLatency = 0;
      const parsed = /^(http|socks5):\/\/(\[[^\]]+\]|[^:]+):(\d+)$/.exec(saved.address);
      if (parsed) { this.proxyProtocol = parsed[1]; this.proxyHost = parsed[2]; this.proxyPort = parsed[3]; }
    } catch (error) { if (!this.disposed && this.proxyOpen) this.proxyStatus = errorText(error); }
    finally { if (!this.disposed) this.proxyBusy = false; }
  }

  private editMirrorAddress(value: string): void {
    if (this.disposed || this.returning || !this.visible) return;
    this.mirrorChoicesOpen = false;
    this.mirrorEditor?.edit(value);
  }

  private selectMirrorChoice(address: string): void {
    if (this.disposed || this.returning || !this.visible || !this.mirror.ready || !this.mirror.enabled ||
      !Settings.MIRROR_DEFAULTS.includes(address)) return;
    this.mirrorChoicesOpen = false;
    // Choosing a candidate is the same edit as typing; the editor owns debounce, persistence and checks.
    this.mirrorEditor?.edit(address);
  }

  private mirrorChoiceSelected(address: string): boolean {
    return this.mirror.address.trim().toLowerCase().replace(/\/+$/, '') === address.replace(/\/+$/, '');
  }

  private toggleMirror(): void {
    this.mirrorChoicesOpen = false;
    this.mirrorEditor?.toggle(!this.mirror.enabled);
  }

  private mirrorStatusLabel(): string {
    if (this.mirror.checking) return I18n.t('正在检验镜像连接');
    if (this.mirror.state === 'success') return I18n.t('镜像连接检查通过');
    if (this.mirror.state === 'warning') return I18n.t('镜像连接未确认，下载时自动回退');
    return this.mirror.address.trim() ? I18n.t('镜像连接尚未确认') : I18n.t('尚未填写镜像地址');
  }

  private mirrorIssueAvailable(): boolean {
    return this.mirror.ready && this.mirror.enabled && !this.mirror.checking &&
      (this.mirror.state === 'warning' || this.mirror.state === 'unconfirmed') &&
      this.mirror.message.trim().length > 0;
  }

  private async showMirrorIssue(): Promise<void> {
    if (this.disposed || this.returning || !this.visible || this.mirrorIssueOpen ||
      !this.mirrorIssueAvailable()) return;
    const message = this.mirror.message;
    this.mirrorIssueOpen = true;
    this.mirrorChoicesOpen = false;
    try {
      await promptAction.showDialog({ title: I18n.t('镜像状态'), message: message,
        buttons: [{ text: I18n.t('知道了'), color: this.colors().accent }] });
    } catch (_) { /* Dismissal or an unavailable dialog leaves the editor unchanged. */ }
    finally { this.mirrorIssueOpen = false; }
  }

  @Builder private mirrorInputStatus() {
    Button({ type: ButtonType.Normal }) {
      if (this.mirror.checking) {
        LoadingProgress().width(16).height(16).color(this.colors().accent)
      } else if (this.mirror.state === 'success') {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([this.colors().success])
      } else if (this.mirror.state === 'warning') {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(16).fontColor([this.colors().danger])
      } else {
        SymbolGlyph($r('sys.symbol.questionmark_circle')).fontSize(16).fontColor([this.colors().textTertiary])
      }
    }.width(36).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
      .enabled(this.mirrorIssueAvailable()).stateEffect(false)
      .accessibilityText(this.mirrorStatusLabel() + (this.mirrorIssueAvailable() ? I18n.t('，点击查看原因') : ''))
      .id('settings-github-mirror-status').onClick(() => { this.showMirrorIssue(); })
  }

  @Builder private mirrorDefaultChoices() {
    Column({ space: 0 }) {
      Row() {
        Text(I18n.t('默认镜像')).fontSize(12).fontColor(this.colors().textSecondary).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([this.colors().textSecondary])
        }.width(28).height(28).padding(0).borderRadius(14).backgroundColor(Color.Transparent)
          .accessibilityText(I18n.t('收起默认镜像')).id('settings-github-mirror-choices-close')
          .onClick(() => { this.mirrorChoicesOpen = false; })
      }.width('100%').padding({ left: 12, right: 6, top: 4, bottom: 2 })
      ForEach(Settings.MIRROR_DEFAULTS, (address: string) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Text(address).fontSize(13).fontColor(this.colors().text).layoutWeight(1).maxLines(1)
            if (this.mirrorChoiceSelected(address)) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([this.colors().accent])
            }
          }.width('100%')
        }.width('100%').height(42).padding({ left: 12, right: 12 })
          .backgroundColor(this.mirrorChoiceSelected(address) ? this.colors().accentSoft : Color.Transparent)
          .borderRadius(8).accessibilityText(address + (this.mirrorChoiceSelected(address) ? I18n.t('，当前地址') : I18n.t('，选择镜像')))
          .id('settings-github-mirror-choice-' + address).onClick(() => this.selectMirrorChoice(address))
      }, (address: string) => address)
    }.width('100%').padding(4).backgroundColor(this.colors().surface).borderRadius(12)
      .border({ width: 1, color: this.colors().border, radius: 12 }).id('settings-github-mirror-choices')
  }

  @Builder private sectionTitle(title: string) {
    Text(title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
      .width('100%').padding({ left: 4 })
  }

  @Builder private settingRows() {
    Column() {
      Row({ space: 12 }) {
        this.settingIcon($r('sys.symbol.paintpalette'))
        Text(I18n.t('外观')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .layoutWeight(1).maxLines(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.mode === 'light' ? I18n.t('浅色') : this.mode === 'dark' ? I18n.t('深色') : I18n.t('跟随系统'))
              .fontSize(14).fontColor(this.colors().text)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.colors().textSecondary])
              .rotate({ angle: this.appearanceMenuOpen ? 180 : 0 })
              .animation({ duration: 180, curve: Curve.EaseOut })
          }.justifyContent(FlexAlign.Center)
        }.width(99).height(44).padding({left:8,right:8}).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.appearanceBusy).id('settings-appearance-select')
          .accessibilityText(I18n.t('外观，') + (this.mode === 'light' ? I18n.t('浅色') : this.mode === 'dark' ? I18n.t('深色') : I18n.t('跟随系统')))
          .onClick(() => { this.appearanceMenuOpen = !this.appearanceMenuOpen; })
          .bindMenu(this.appearanceMenuOpen, [
            { value: I18n.t('跟随系统'), action: () => this.selectAppearance('system') },
            { value: I18n.t('浅色'), action: () => this.selectAppearance('light') },
            { value: I18n.t('深色'), action: () => this.selectAppearance('dark') }
          ], { placement: Placement.BottomRight, backgroundColor: this.colors().surface,
            backgroundBlurStyle: BlurStyle.NONE, borderRadius: 12,
            onDisappear: () => { this.appearanceMenuOpen = false; } })
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        this.settingIcon($r('sys.symbol.sun_max'))
        Text(I18n.t('光感强度')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(MaterialPreferences.label(this.materialMode)).fontSize(14).fontColor(this.colors().text)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.colors().textSecondary])
              .rotate({ angle: this.materialMenuOpen ? 180 : 0 }).animation({ duration: 180, curve: Curve.EaseOut })
          }.justifyContent(FlexAlign.Center)
        }.width(99).height(44).padding({left:8,right:8}).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 }).enabled(!this.materialBusy)
          .id('settings-material-select').onClick(() => { this.materialMenuOpen = !this.materialMenuOpen; })
          .bindMenu(this.materialMenuOpen, [
            { value: I18n.t('自动'), action: () => this.selectMaterial('adaptive') },
            { value: I18n.t('强'), action: () => this.selectMaterial('strong') },
            { value: I18n.t('均衡'), action: () => this.selectMaterial('balanced') },
            { value: I18n.t('弱'), action: () => this.selectMaterial('weak') },
            { value: I18n.t('关闭'), action: () => this.selectMaterial('off') }
          ], { placement: Placement.BottomRight, backgroundColor: this.colors().surface,
            backgroundBlurStyle: BlurStyle.NONE, borderRadius: 12,
            onDisappear: () => { this.materialMenuOpen = false; } })
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        this.settingIcon($r('sys.symbol.translate'))
        Text(I18n.t('界面语言')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .layoutWeight(1).maxLines(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.appLanguage === 'en' ? 'English' : '简体中文')
              .fontSize(14).fontColor(this.colors().text)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.colors().textSecondary])
              .rotate({ angle: this.languageMenuOpen ? 180 : 0 })
              .animation({ duration: 180, curve: Curve.EaseOut })
          }.justifyContent(FlexAlign.Center)
        }.width(99).height(44).padding({left:8,right:8}).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.languageBusy).id('settings-language-select')
          .accessibilityText(I18n.t('界面语言，') + (this.appLanguage === 'en' ? 'English' : '简体中文'))
          .onClick(() => { this.languageMenuOpen = !this.languageMenuOpen; })
          .bindMenu(this.languageMenuOpen, [
            { value: '简体中文', action: () => this.selectLanguage('zh') },
            { value: 'English', action: () => this.selectLanguage('en') }
          ], { placement: Placement.BottomRight, backgroundColor: this.colors().surface,
            backgroundBlurStyle: BlurStyle.NONE, borderRadius: 12,
            onDisappear: () => { this.languageMenuOpen = false; } })
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        this.settingIcon($r('sys.symbol.trash'))
        Column({space:3}){
        Text(I18n.t('缓存管理')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .maxLines(1)
        Text(this.cacheReading ? I18n.t('读取中…') : I18n.t('共 ') + SettingsCache.format(this.cacheSize))
          .fontSize(12).fontColor(this.colors().textSecondary).maxLines(1)
          .accessibilityText(I18n.t('图标、目录及安装临时文件总占用 ') + SettingsCache.format(this.cacheSize))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          if (this.cacheBusy) {
            LoadingProgress().width(18).height(18).color(this.colors().textSecondary)
          } else {
            Text(I18n.t('清理闲置')).fontSize(14).fontColor(this.colors().text)
          }
        }.width(99).height(44).padding({left:8,right:8}).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.cacheBusy && !this.cacheReading).id('settings-clean-cache')
          .accessibilityText(this.cacheBusy ? I18n.t('正在清理缓存') : I18n.t('清理图标、目录及闲置安装文件'))
          .accessibilityDescription(I18n.t('保留未完成任务和签名材料')).onClick(() => this.cleanCache())
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
    }.width('100%').backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius).clip(true)
  }

  @Builder private githubMirrorRow() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.github_mark')).width(21).height(21).fillColor(this.colors().text)
        }.width(24).height(24).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Text(I18n.t('GitHub 镜像')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .layoutWeight(1).maxLines(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.mirror.enabled ? I18n.t('开启') : I18n.t('关闭')).fontSize(14).fontColor(this.colors().text)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.colors().textSecondary])
              .rotate({ angle: this.mirror.enabled ? 180 : 0 }).animation({ duration: 220, curve: Curve.EaseInOut })
          }.justifyContent(FlexAlign.Center)
        }.width(99).height(44).padding({left:8,right:8}).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(this.mirror.ready).id('settings-github-mirror')
          .accessibilityText(I18n.t('自定义 GitHub 下载镜像，') + (this.mirror.enabled ? I18n.t('已开启') : I18n.t('已关闭')))
          .accessibilityDescription(this.mirror.enabled ? I18n.t('点击关闭镜像并收起地址输入框') : I18n.t('点击开启镜像并展开地址输入框'))
          .onClick(() => this.toggleMirror())
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      if (this.mirror.enabled) {
        Column({ space: 10 }) {
          Stack({ alignContent: Alignment.End }) {
            TextInput({ text: this.mirror.address, placeholder: 'https://gh-proxy.org/' })
              .width('100%').height(44).fontSize(14).fontColor(this.colors().text)
              .placeholderColor(this.colors().textTertiary).backgroundColor(this.colors().fill)
              .borderRadius(12).padding({ left: 12, right: 48 }).maxLength(512)
              .id('settings-github-mirror-address')
              .accessibilityText(I18n.t('HTTPS 镜像前缀地址'))
              .onFocus(() => this.openMirrorChoices()).onClick(() => this.openMirrorChoices())
              .onChange((value: string) => this.editMirrorAddress(value))
            this.mirrorInputStatus()
          }.width('100%').height(44).id('settings-github-mirror-input')
          if (this.mirrorChoicesOpen) { this.mirrorDefaultChoices() }
        }.width('100%').padding({ left: 16, right: 16, bottom: 14 })
      }
    }.width('100%')
  }

  @Builder private information(label: string, value: () => string) {
    Row({ space: 16 }) {
      Text(label).fontSize(14).fontColor(this.colors().textSecondary)
      Text(value() || I18n.t('读取中…')).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(2)
    }.width('100%').constraintSize({ minHeight: 28 })
  }

  @Builder private updatePushCard() {
      Row({ space: 12 }) {
        this.settingIcon($r('sys.symbol.bell'))
        Text(I18n.t('推送设置')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        Button(I18n.t('配置'),{type:ButtonType.Normal}).width(99).height(44).borderRadius(12)
          .backgroundColor(this.colors().fill).fontColor(this.colors().text).fontSize(14)
          .border({width:1,color:this.colors().border,radius:12})
          .id('settings-update-push').accessibilityText(I18n.t('推送设置，商店应用更新提醒'))
          .onClick(()=>{this.pushDialogOpen=true;})
      }.width('100%').padding({left:16,right:12,top:12,bottom:12})
  }

  @Builder private settingIcon(symbol:Resource){
    SymbolGlyph(symbol).fontSize(21).fontColor([this.colors().accent])
      .width(24).height(24).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }

  @Builder private advancedRows(){
    Column(){
      this.githubMirrorRow()
      Divider().strokeWidth(.5).color(this.colors().border).margin({left:16,right:16})
      this.downloadProxyRow()
      Divider().strokeWidth(.5).color(this.colors().border).margin({left:16,right:16})
      this.updatePushCard()
    }.width('100%').backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius).clip(true)
  }

  @Builder private downloadProxyRow() {
    Row({ space: 12 }) {
      this.settingIcon($r('sys.symbol.link'))
      Text(I18n.t('下载代理')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
      Button(I18n.t('配置'), { type: ButtonType.Normal }).width(99).height(44).borderRadius(12)
        .backgroundColor(this.colors().fill).fontColor(this.colors().text).fontSize(14)
        .border({ width: 1, color: this.colors().border, radius: 12 })
        .enabled(!this.proxyBusy).id('settings-download-proxy').onClick(() => this.openDownloadProxy())
    }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
  }

  @Builder private downloadProxyDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim)
        .onClick(() => { this.proxyOpen = false; })
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text(I18n.t('下载代理')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).layoutWeight(1)
          StoreIconButton({ label: I18n.t('关闭'), action: () => { this.proxyOpen = false; } })
        }.width('100%')
        Row({ space: 8 }) {
          ForEach(['http', 'socks5'], (protocol: string) => {
            Button(protocol === 'http' ? 'HTTP' : 'SOCKS5', { type: ButtonType.Normal })
              .layoutWeight(1).height(40).borderRadius(12).fontSize(14)
              .backgroundColor(this.proxyProtocol === protocol ? this.colors().accent : this.colors().fill)
              .fontColor(this.proxyProtocol === protocol ? this.colors().onAccent : this.colors().text)
              .enabled(!this.proxyBusy)
            .onClick(() => { this.proxyProtocol = protocol; this.proxyLatency = 0; this.proxyStatus = ''; })
          })
        }.width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.proxyHost, placeholder: '127.0.0.1' })
            .layoutWeight(1).height(44).fontSize(14).backgroundColor(this.colors().fill).fontColor(this.colors().text)
            .borderRadius(12).padding({ left: 12, right: 12 }).enabled(!this.proxyBusy)
            .onChange((value: string) => { this.proxyHost = value; this.proxyLatency = 0; this.proxyStatus = ''; })
          TextInput({ text: this.proxyPort, placeholder: I18n.t('端口') }).width(80).height(44).fontSize(14)
            .type(InputType.Number).maxLength(5).backgroundColor(this.colors().fill).fontColor(this.colors().text)
            .borderRadius(12).padding({ left: 8, right: 8 }).enabled(!this.proxyBusy)
            .onChange((value: string) => { this.proxyPort = value; this.proxyLatency = 0; this.proxyStatus = ''; })
        }.width('100%')
        if (this.proxyStatus) {
          Text(this.proxyStatus).width('100%').fontSize(12).fontColor(this.colors().textSecondary)
        }
        Row({ space: 10 }) {
          if (this.proxyEnabled) {
            Button(I18n.t('停用'), { type: ButtonType.Normal }).layoutWeight(1).height(44).borderRadius(12)
              .backgroundColor(this.colors().fill).fontColor(this.colors().text).enabled(!this.proxyBusy)
              .onClick(() => this.saveDownloadProxy(false))
          }
          Button(this.proxyBusy ? I18n.t('测速中…') : (this.proxyLatency > 0 ? this.proxyLatency + ' ms' : I18n.t('保存')), { type: ButtonType.Normal })
            .layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.colors().accent)
            .fontColor(this.colors().onAccent).enabled(!this.proxyBusy).onClick(() => this.saveDownloadProxy(true))
        }.width('100%')
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth,
        maxHeight: StoreLayout.sheetMaxHeight(this.windowHeight) })
        .padding(20).backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius).clip(true)
    }.width('100%').height('100%').position({ x: 0, y: 0 })
  }

  @Builder private privacyRows() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(I18n.t('签名材料云备份')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          Text(this.backupAccountLabel || I18n.t('请先登录华为开发者账号'))
            .fontSize(12).fontColor(this.colors().textSecondary).maxLines(1)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.backupEnabled })
          .enabled(!this.backupBusy && this.backupAccount !== undefined)
          .selectedColor(this.colors().accent).id('settings-cloud-backup')
          .onChange((enabled: boolean) => this.changeBackup(enabled))
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })
      Text(I18n.t('默认仅存本机。启用后私钥存入商店服务器，服务器能够解密；停用不删除已有云端备份。'))
        .fontSize(12).fontColor(this.colors().textSecondary).width('100%')
        .padding({ left: 16, right: 16, bottom: 14 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        Text(I18n.t('隐私声明')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        Button(I18n.t('查看'), { type: ButtonType.Normal }).width(99).height(44).borderRadius(12)
          .backgroundColor(this.colors().fill).fontColor(this.colors().text)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .id('settings-privacy-view').onClick(() => this.openPrivacy())
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        Text(I18n.t('隐私同意')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        Button(this.privacyAllowed ? I18n.t('撤回同意') : I18n.t('重新同意'), { type: ButtonType.Normal })
          .width(99).height(44).borderRadius(12).backgroundColor(this.colors().fill)
          .fontColor(this.colors().text).border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.privacyBusy).id('settings-privacy-consent').onClick(() => this.changePrivacy())
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
    }.width('100%').backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius).clip(true)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column({ space: 18 }) {
          Column({space:8}){
            this.sectionTitle(I18n.t('基础设置'))
            this.settingRows()
          }.width('100%')
          Column({space:8}){
            this.sectionTitle(I18n.t('高级设置'))
            this.advancedRows()
          }.width('100%')
          if (PrivacyConsent.isManaged()) { this.privacyRows() }
          Column({ space: 8 }) {
            this.sectionTitle(I18n.t('版本信息'))
            Column({ space: 4 }) {
              this.information(I18n.t('应用'), () => I18n.t('轻启·安装器'))
              this.information(I18n.t('版本'), () => this.version)
              this.information(I18n.t('内部编号'), () => this.versionCode)
            }.width('100%').padding(16).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
          }.width('100%')
        }.width('100%').constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
          .padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth),
            top: this.statusInset + 72, bottom: Math.max(28, this.navigationBottomInset + 16) })
      }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
        .onDidScroll(() => ForegroundIdle.interaction())
      StorePageHeader({ title: I18n.t('设置'), statusInset: this.statusInset, visible: this.visible,
        action: () => { this.onBackPress(); }, backAction: () => { this.onBackPress(); } }).position({ x: 0, y: 0 })
      if (this.pushDialogOpen) {
        UpdatePushDialog({ onClose: () => { this.pushDialogOpen = false; } })
      }
      if (this.proxyOpen) { this.downloadProxyDialog() }
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  pageTransition() {
    PageTransitionEnter(StorePageMotion.options(RouteType.Push)).slide(SlideEffect.Right).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionEnter(StorePageMotion.stationary(RouteType.Pop)).translate({ x: 0 }).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionExit(StorePageMotion.stationary(RouteType.Push)).translate({ x: 0 }).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionExit(StorePageMotion.options(RouteType.Pop)).slide(SlideEffect.Right).opacity(1).scale({ x: 1, y: 1 })
  }
}
