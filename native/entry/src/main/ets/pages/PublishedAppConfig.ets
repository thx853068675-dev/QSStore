import { AppBackground } from '../data/AppBackgroundPreferences';
import { AppThemeBackground } from '../components/AppThemeBackground';
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { ListingPresentationEditor } from '../components/ListingPresentationEditor';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { I18n } from '../data/I18n';
import { ListingPresentationDraft } from '../data/ListingPresentation';
import { ReleaseChannelRegistry } from '../data/ReleaseChannelRegistry';
import { HapAsset } from '../data/ReleaseInfo';
import { SubmitChoice, SubmitDraft } from '../data/StoreActions';
import { PublishedAppConfiguration, StoreClient } from '../data/StoreClient';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreLayout, StorePageHeader } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';
import { StoreSelect } from '../theme/StoreSelect';

@Entry
@Component
struct PublishedAppConfig {
  @StorageProp('appBackground') private themeState: AppBackground = new AppBackground();
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 0;
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @StorageProp('navigationBottomInset') private bottomInset: number = 0;
  @State private config: PublishedAppConfiguration = new PublishedAppConfiguration();
  @State private draft: ListingPresentationDraft = new ListingPresentationDraft();
  @State private category: string = '';
  @State private primaryUrl: string = '';
  @State private sourceUrl: string = '';
  @State private source: SubmitDraft = new SubmitDraft();
  @State private sourceExpanded: boolean = false;
  @State private removeSource: boolean = false;
  @State private sourceMessage: string = '';
  @State private message: string = '';
  @State private task: string = '';
  @State private headerVisible: boolean = true;
  private account?: DeveloperAccount;
  private appId: number = 0;
  private disposed: boolean = false;
  private returning: boolean = false;
  private returnTimer: number = -1;

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  private cardSurface(): string { return Palette.containerPaint(this.colors().surface, this.themeState.containerOpacity); }
  private context(): common.UIAbilityContext { return getContext(this) as common.UIAbilityContext; }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, number> | undefined;
    this.appId = Number(params?.['id'] ?? 0);
    this.load();
  }

  aboutToDisappear(): void { this.disposed = true; clearTimeout(this.returnTimer); }
  onPageHide(): void { this.headerVisible = false; }
  onPageShow(): void { if (!this.returning) this.headerVisible = true; }
  onBackPress(): boolean {
    if (!StorePageMotion.dismissDevicePanel()) this.back();
    return true;
  }

  private back(): void {
    if (this.returning || this.disposed || ['save', 'unlist', 'release'].includes(this.task)) return;
    this.returning = true;
    this.headerVisible = false;
    StorePageMotion.prepare();
    this.returnTimer = setTimeout(() => { if (!this.disposed) router.back(); }, 32);
  }

  private url(repo: string): string {
    if (!repo) return '';
    return repo.startsWith('gitee.com/') ? 'https://' + repo : 'https://github.com/' + repo;
  }

  private populate(config: PublishedAppConfiguration): void {
    const app = config.app;
    this.config = config;
    this.draft = ListingPresentationDraft.create(app.displayName, app.description, app.screenshots);
    this.category = app.category;
    this.primaryUrl = this.url(app.repo);
    this.sourceUrl = this.url(app.secondaryRepo);
    this.sourceExpanded = app.secondaryRepo.length > 0;
    this.source = new SubmitDraft();
    this.removeSource = false;
    this.sourceMessage = '';
  }

  private async load(): Promise<void> {
    if (this.task || this.disposed) return;
    this.task = 'load';
    this.message = '';
    try {
      const context = this.context();
      const account = await AccountSession.load(context);
      if (!account) throw new Error(I18n.t('请先在「我的」登录华为开发者账号'));
      if (!Number.isSafeInteger(this.appId) || this.appId <= 0) throw new Error(I18n.t('应用编号无效'));
      const config = await new StoreClient(context).ownedAppConfiguration(this.appId, account);
      if (this.disposed) return;
      this.account = account;
      this.populate(config);
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
    } finally { if (!this.disposed) this.task = ''; }
  }

  private async currentAccount(): Promise<DeveloperAccount> {
    const current = await AccountSession.load(this.context());
    if (!current || current.userId !== this.account?.userId || current.teamId !== this.account?.teamId) {
      throw new Error(I18n.t('账号已变更，请刷新后重试'));
    }
    return current;
  }

  private sourceChanged(): boolean {
    return this.sourceUrl.trim().replace(/\/+$/, '').toLowerCase() !== this.url(this.config.app.secondaryRepo).toLowerCase();
  }

  private canSave(): boolean {
    return !!this.config.revision && !this.task && !this.draft.processing && this.draft.name.trim().length > 0 &&
      this.config.categories.includes(this.category) && (!this.sourceChanged() || !!this.source.token || this.removeSource);
  }

  private async checkSource(): Promise<void> {
    if (this.task || !this.sourceUrl.trim()) return;
    this.task = 'source';
    this.source = new SubmitDraft();
    this.sourceMessage = I18n.t('正在检查子仓安装包…');
    try {
      const client = new StoreClient(this.context());
      const account = await this.currentAccount();
      let draft = await client.prepareAppSource(this.appId, this.sourceUrl.trim(), account);
      const deadline = Date.now() + 300000;
      while (draft.inspectionStatus !== 'ready') {
        if (this.disposed || this.returning) return;
        this.sourceMessage = I18n.t('正在后台解析安装包并核验包名…');
        await new Promise<void>((resolve) => setTimeout(resolve, 2000));
        if (this.disposed || this.returning) return;
        if (Date.now() > deadline) throw new Error(I18n.t('检查仍在后台进行，请稍后再点检查'));
        draft = await client.submitStatus(draft, account);
      }
      if (this.disposed || this.returning) return;
      const bundles = this.config.app.latestAssets.map((asset: HapAsset) => asset.bundleName);
      const matches = draft.choices.filter((choice: SubmitChoice) =>
        choice.bundleName.length > 0 && bundles.includes(choice.bundleName));
      if (matches.length === 0) throw new Error(I18n.t('子仓安装包与主仓包名不一致，无法关联'));
      this.source = draft;
      this.removeSource = false;
      this.sourceMessage = I18n.t('包名核验通过：') +
        Array.from(new Set(matches.map((choice: SubmitChoice) => choice.bundleName))).join(I18n.t('、')) +
        I18n.t('。保存后关联。');
    } catch (error) {
      if (!this.disposed && !this.returning) this.sourceMessage = errorText(error);
    } finally { if (!this.disposed) this.task = ''; }
  }

  private async save(): Promise<void> {
    if (!this.canSave()) return;
    this.task = 'save';
    this.message = '';
    try {
      const account = await this.currentAccount();
      const client = new StoreClient(this.context());
      const primary = /^https:\/\/github\.com\/([a-z0-9_.-]+\/[a-z0-9_.-]+)\/?$/i.exec(this.primaryUrl.trim())?.[1];
      if (!this.config.app.repo.startsWith('gitee.com/') && !primary) {
        throw new Error(I18n.t('请输入有效的 GitHub 仓库地址'));
      }
      const changed = primary !== undefined && primary.toLowerCase() !== this.config.app.repo.toLowerCase();
      const edits = this.draft.edits();
      const saved = await client.configureMyApp(this.config, this.category, account, this.source.token, this.removeSource,
        changed ? this.primaryUrl.trim() : '', edits);
      const app = saved.app;
      if ((changed && app.repo.toLowerCase() !== primary?.toLowerCase()) || app.category !== this.category ||
        (this.source.token && app.secondaryRepo.toLowerCase() !== this.source.repo.toLowerCase()) ||
        (this.removeSource && app.secondaryRepo.length > 0) ||
        (edits?.display_name !== undefined && app.displayName !== edits.display_name) ||
        (edits?.description !== undefined && app.description !== edits.description) ||
        (edits?.screenshots !== undefined && ((edits.screenshots.length > 0 && app.screenshots.length === 0) ||
          (edits.screenshots.length === 0 && app.screenshots.length > 0)))) {
        throw new Error(I18n.t('服务器返回的配置与提交内容不一致，请重新打开后重试'));
      }
      if (this.disposed) return;
      this.populate(saved);
      ReleaseChannelRegistry.refreshTargets(this.context(), [app], true).catch(() => {});
      promptAction.showToast({ message: I18n.t('配置已保存') });
    } catch (error) {
      if (!this.disposed) {
        this.message = errorText(error);
        promptAction.showToast({ message: this.message });
      }
    } finally { if (!this.disposed) this.task = ''; }
  }

  private async remove(releaseClaim: boolean): Promise<void> {
    if (this.task || this.draft.processing) return;
    const name = this.config.app.displayName;
    const label = I18n.t(releaseClaim ? '解除认领' : '下架应用');
    this.task = 'confirm';
    const result = await promptAction.showDialog({ title: label,
      message: releaseClaim ? I18n.t('解除后将失去作者标识，应用仍保留在已上架列表。') :
        I18n.t('确定下架「') + name + I18n.t('」？已安装的应用不会被删除。'),
      buttons: [{ text: I18n.t('取消'), color: this.colors().text },
        { text: label, color: this.colors().danger }] }).catch(() => undefined);
    if (result?.index !== 1 || this.disposed || this.returning) { this.task = ''; return; }
    this.task = releaseClaim ? 'release' : 'unlist';
    this.message = '';
    try {
      const account = await this.currentAccount();
      const client = new StoreClient(this.context());
      if (releaseClaim) {
        await client.releaseClaim(this.appId, account);
        if (!this.disposed) {
          const updated = new PublishedAppConfiguration();
          updated.app = this.config.app;
          updated.app.claimedByMe = false;
          updated.categories = this.config.categories;
          updated.revision = this.config.revision;
          this.config = updated;
        }
      } else {
        await client.removeMyApp(this.appId, account);
        this.task = '';
        this.back();
      }
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
    } finally { if (!this.disposed) this.task = ''; }
  }

  @Builder
  private sectionTitle(label: string) {
    Text(I18n.t(label)).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.colors().text).width('100%')
  }

  @Builder
  private form() {
    Column({ space: 12 }) {
      this.sectionTitle('应用资料')
      ListingPresentationEditor({ draft: this.draft, appId: this.appId, darkMode: this.darkMode, editable: !this.task })
    }.width('100%').padding(16).borderRadius(StoreLayout.cardRadius).backgroundColor(this.cardSurface())
    Column({ space: 10 }) {
      this.sectionTitle('分类')
      StoreSelect({ options: this.config.categories.map((value: string) => ({ value: I18n.category(value) } as SelectOption)),
        selectedIndex: this.config.categories.indexOf(this.category), selectedValue: I18n.category(this.category),
        controlId: 'app-config-category-select', active: !this.task,
        action: (index: number) => { this.category = this.config.categories[index] ?? ''; } })
      this.sectionTitle('主仓地址')
      TextInput({ text: this.primaryUrl, placeholder: 'https://github.com/owner/repo' }).height(44)
        .fontSize(13).fontColor(this.colors().text).backgroundColor(this.colors().fill).borderRadius(12)
        .enabled(!this.task && !this.config.app.repo.startsWith('gitee.com/')).id('app-config-primary-url')
        .onChange((value: string) => { this.primaryUrl = value; })
      Row({ space: 8 }) {
        Text(I18n.t('子仓')).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        if (this.config.app.secondaryRepo && !this.removeSource) {
          Button(I18n.t('解除关联'), { type: ButtonType.Capsule }).height(32)
            .fontSize(11).fontColor(this.colors().danger).backgroundColor(this.colors().dangerSoft)
            .enabled(!this.task).onClick(() => {
              this.sourceUrl = '';
              this.source = new SubmitDraft();
              this.removeSource = true;
              this.sourceMessage = I18n.t('保存后解除关联');
            })
        }
      }.width('100%')
      if (this.sourceExpanded) {
        TextInput({ text: this.sourceUrl, placeholder: I18n.t('GitHub / Gitee 仓库地址') }).height(44)
          .fontSize(13).fontColor(this.colors().text).backgroundColor(this.colors().fill).borderRadius(12)
          .enabled(!this.task).id('app-config-source-url').onChange((value: string) => {
            this.sourceUrl = value;
            this.source = new SubmitDraft();
            this.removeSource = false;
            this.sourceMessage = '';
          })
        Button(I18n.t(this.task === 'source' ? '正在核验包名…' : '检查子仓'), { type: ButtonType.Capsule })
          .height(38).width('100%').fontSize(12).fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
          .enabled(!this.task && !!this.sourceUrl.trim()).id('app-config-source-check').onClick(() => this.checkSource())
        if (this.sourceMessage) {
          Text(this.sourceMessage).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
        }
      } else {
        Button(I18n.t('添加子仓'), { type: ButtonType.Capsule }).height(38).width('100%').fontSize(12)
          .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft).enabled(!this.task)
          .id('app-config-source-add').onClick(() => { this.sourceExpanded = true; })
      }
    }.width('100%').padding(16).borderRadius(StoreLayout.cardRadius).backgroundColor(this.cardSurface())
    if (this.config.app.claimedByMe) {
      Button(I18n.t('解除认领'), { type: ButtonType.Capsule }).width('100%').height(44)
        .fontSize(13).fontColor(this.colors().textSecondary).backgroundColor(this.colors().surface)
        .enabled(!this.task).onClick(() => this.remove(true))
    }
  }

  @Builder
  private footer() {
    Column() {
      Blank().layoutWeight(1).hitTestBehavior(HitTestMode.None)
      Row({ space: 10 }) {
        Button(I18n.t(this.task === 'unlist' ? '下架中…' : '下架应用'), { type: ButtonType.Capsule })
          .layoutWeight(1).height(48).fontSize(14).fontColor(this.colors().danger)
          .backgroundColor(this.colors().dangerSoft)
          .enabled(!this.task && !this.draft.processing).id('app-config-unlist').onClick(() => this.remove(false))
        Button(I18n.t(this.task === 'save' ? '处理中…' : '保存配置'), { type: ButtonType.Capsule })
          .layoutWeight(1.18).height(48).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.colors().onAccent).backgroundColor(this.colors().accent)
          .enabled(this.canSave()).id('app-config-save').onClick(() => this.save())
      }.width('100%').constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
        .padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth),
          bottom: Math.max(18, this.bottomInset + 10) })
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      AppThemeBackground()
      Scroll() {
        Column({ space: 12 }) {
          if (this.config.revision) {
            this.form()
          } else if (this.task === 'load') {
            LoadingProgress().width(28).height(28).color(this.colors().accent).alignSelf(ItemAlign.Center)
          }
          if (this.message) {
            Text(this.message).fontSize(13).fontColor(this.colors().danger).width('100%')
            if (!this.config.revision) {
              Button(I18n.t('重试'), { type: ButtonType.Capsule }).height(44).width('100%')
                .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent).onClick(() => this.load())
            }
          }
        }.width('100%').padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth),
          top: this.statusInset + 72, bottom: Math.max(98, this.bottomInset + 86) })
      }.width('100%').height('100%').constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
        .scrollBar(BarState.Off)
      if (this.config.revision) this.footer()
      StorePageHeader({ title: I18n.t('应用配置'), statusInset: this.statusInset, visible: this.headerVisible,
        action: () => this.back() })
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  pageTransition() {
    PageTransitionEnter(StorePageMotion.options(RouteType.Push)).slide(SlideEffect.Right).opacity(1)
    PageTransitionEnter(StorePageMotion.stationary(RouteType.Pop)).translate({ x: 0 }).opacity(1)
    PageTransitionExit(StorePageMotion.stationary(RouteType.Push)).translate({ x: 0 }).opacity(1)
    PageTransitionExit(StorePageMotion.options(RouteType.Pop)).slide(SlideEffect.Right).opacity(1)
  }
}
