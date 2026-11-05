import { bundleManager, common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { InstalledApplications } from '../data/InstalledApplications';
import { InstalledInspection, InstalledSelection } from '../data/InstalledInspection';
import { InstalledIconCache } from '../data/InstalledIconCache';
import { applicationIcons } from '../data/ApplicationIcons';
import { ListDataSource } from '../data/ListDataSource';
import { InstalledDeviceApp } from '../jobs/InstalledAppRegistry';
import { LocalBundles } from '../jobs/LocalBundles';
import { Palette } from '../theme/Palette';
import { StoreLayout, StorePageHeader, StoreImmersiveIconButton } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';
import { I18n } from '../data/I18n';

@Component
struct InstalledApplicationIcon {
  @Prop app: InstalledDeviceApp;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @State private pixels: image.PixelMap | undefined = undefined;
  @State private market: string = '';
  private alive: boolean = false;
  aboutToAppear(): void {
    this.alive = true;
    // Disk thumbnails are ready before permission-bound local lookups or network refreshes.
    this.market = applicationIcons((getContext(this) as common.UIAbilityContext).cacheDir).cached(this.app.bundleName);
    this.read();
  }
  aboutToDisappear(): void { this.alive = false; this.pixels?.release().catch(() => {}); this.pixels = undefined; }
  private async read(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const bytes = await InstalledIconCache.load(context, this.app.bundleName, this.app.versionCode);
      if (bytes && this.alive) {
        const source = image.createImageSource(bytes);
        try { const pixels = await source.createPixelMap({ desiredSize: { width: 160, height: 160 } });
          if (this.alive) this.pixels = pixels; else pixels.release(); }
        finally { source.release(); }
      }
      if (!this.alive || this.pixels) return;
      if (this.market) {
        const refreshed = await applicationIcons(context.cacheDir).load(this.app.bundleName, () => this.alive);
        if (this.alive && refreshed) this.market = refreshed;
        return;
      }
      const pixels = await LocalBundles.installedIcon(context, this.app.bundleName, this.app.abilityName);
      if (pixels) { if (this.alive) this.pixels = pixels; else pixels.release(); return; }
      if (!this.alive) return;
      try {
        const info = await bundleManager.getBundleInfo(this.app.bundleName,
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        if (info.name === this.app.bundleName && info.appInfo?.iconResource) {
          const nativeIcon = context.resourceManager.getDrawableDescriptor(info.appInfo.iconResource)?.getPixelMap();
          if (nativeIcon) { if (this.alive) this.pixels = nativeIcon; else nativeIcon.release(); return; }
        }
      } catch (_) { /* Visibility rules may deny another package's resources. */ }
      if (!this.alive) return;
      const market = await applicationIcons(context.cacheDir).load(this.app.bundleName, () => this.alive);
      if (this.alive) this.market = market;
    } catch (_) { /* An unavailable icon must not block the list. */ }
  }
  build() {
    Stack() {
      if (this.pixels) { Image(this.pixels).width(48).height(48).borderRadius(13).objectFit(ImageFit.Cover) }
      else if (this.market) { Image(this.market).width(48).height(48).borderRadius(13).objectFit(ImageFit.Cover) }
      else { Text((this.app.displayName || this.app.bundleName).substring(0, 1)).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(Palette.forMode(this.darkMode).accent).width(48).height(48).textAlign(TextAlign.Center)
        .backgroundColor(Palette.forMode(this.darkMode).accentSoft).borderRadius(13) }
    }.width(48).height(48)
  }
}

@Entry
@Component
struct InstalledApplicationsPage {
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('windowWidth') private windowWidth: number = 0;
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @StorageProp('navigationBottomInset') private bottomInset: number = 0;
  @State private rows: InstalledDeviceApp[] = [];
  @State private query: string = '';
  @State private busy: boolean = false;
  @State private notice: string = '';
  @State private headerVisible: boolean = true;
  private disposed: boolean = false;
  private returning: boolean = false;
  private timer: number = -1;
  private searchTimer: number = -1;
  private list: ListScroller = new ListScroller();
  private source: ListDataSource<InstalledDeviceApp> = new ListDataSource<InstalledDeviceApp>(
    (row: InstalledDeviceApp): string => row.bundleName,
    (row: InstalledDeviceApp): string => JSON.stringify(row));
  private colors(): Palette { return Palette.forMode(this.darkMode); }
  aboutToAppear(): void {
    InstalledApplications.cached(getContext(this) as common.UIAbilityContext).then((rows: InstalledDeviceApp[]) => {
      if (this.disposed) return; this.rows = rows; this.filter(); this.refresh();
    }).catch(() => this.refresh());
  }
  aboutToDisappear(): void { this.disposed = true; clearTimeout(this.timer); clearTimeout(this.searchTimer); }
  onPageShow(): void { if (!this.returning) this.headerVisible = true; }
  onPageHide(): void { this.headerVisible = false; }
  onBackPress(): boolean { if (StorePageMotion.dismissDevicePanel?.()) return true; this.back(); return true; }
  private back(): void {
    if (this.returning || this.disposed) return;
    this.returning = true; this.headerVisible = false; StorePageMotion.prepare();
    this.timer = setTimeout(() => { if (!this.disposed) router.back(); }, 32);
  }
  private filter(): void {
    const query = this.query.trim().toLowerCase();
    this.source.update(this.rows.filter((row: InstalledDeviceApp) => !query ||
      row.displayName.toLowerCase().includes(query) || row.bundleName.toLowerCase().includes(query)));
  }
  private search(value: string, preview?: PreviewText): void {
    if (preview?.value) return; clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => { this.query = value; this.filter(); }, 180);
  }
  private async refresh(): Promise<void> {
    if (this.busy || this.disposed) return; this.busy = true; this.notice = '';
    try { const rows = await InstalledApplications.refresh(getContext(this) as common.UIAbilityContext);
      if (!this.disposed) { this.rows = rows; this.filter(); } }
    catch (_) { if (!this.disposed) this.notice = I18n.t('连接无线调试并刷新，可读取完整应用列表'); }
    finally { if (!this.disposed) this.busy = false; }
  }
  private async copy(bundle: string): Promise<void> {
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, bundle));
      promptAction.showToast({ message: I18n.t('已复制：') + bundle }); }
    catch (_) { promptAction.showToast({ message: I18n.t('暂时无法复制，请重试') }); }
  }
  private information(row: InstalledDeviceApp): void {
    this.list.closeAllSwipeActions(); InstalledInspection.selectedIcon = undefined;
    const info = new InstalledSelection(); info.bundleName = row.bundleName; info.title = row.displayName;
    info.versionCode = row.versionCode; info.versionName = row.versionName; info.moduleName = row.moduleName;
    info.mainAbility = row.abilityName; info.source = I18n.t('设备识别');
    StorePageMotion.pushUrl({ url: 'pages/InstalledDetail', params: { selection: JSON.stringify(info) } });
  }
  @Builder private infoAction(row: InstalledDeviceApp) {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([this.colors().accent])
      Text(I18n.t('信息')).fontSize(12).fontColor(this.colors().accent)
    }.width(68).height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.colors().accentSoft)
      .borderRadius(18).margin({ left: 8 }).onClick(() => this.information(row))
  }
  build() {
    Stack({ alignContent: Alignment.Top }) {
      List({ space: 10, scroller: this.list }) {
        ListItem() { Search({ placeholder: I18n.t('搜索应用名或包名') }).height(44)
          .backgroundColor(this.colors().surface).borderRadius(16).enablePreviewText(true)
          .onChange((value: string, preview?: PreviewText) => this.search(value, preview)) }
        if (this.notice) { ListItem() { Text(this.notice).fontSize(12).fontColor(this.colors().textSecondary).width('100%').padding(8) } }
        if (this.busy && this.rows.length === 0) { ListItem() { LoadingProgress().width(28).height(28).color(this.colors().accent) } }
        LazyForEach(this.source, (row: InstalledDeviceApp) => {
          ListItem() {
            Row({ space: 13 }) {
              InstalledApplicationIcon({ app: row })
              Column({ space: 4 }) {
                Text(row.displayName || row.bundleName).fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor(this.colors().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(row.bundleName).fontSize(11).fontColor(this.colors().textSecondary).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding(14).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
              .onClick(() => this.copy(row.bundleName)).accessibilityText(row.displayName + I18n.t('，点按复制包名'))
          }.swipeAction({ end: { builder: () => { this.infoAction(row); }, actionAreaDistance: 76 }, edgeEffect: SwipeEdgeEffect.Spring })
        }, (row: InstalledDeviceApp) => this.source.key(row))
      }.width('100%').height('100%').scrollBar(BarState.Off).cachedCount(4)
        .constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
        .padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth) })
        .contentStartOffset(this.statusInset + 72).contentEndOffset(Math.max(28, this.bottomInset + 16))
      StorePageHeader({ title: I18n.t('应用列表'), statusInset: this.statusInset, visible: this.headerVisible,
        action: () => this.back(), backAction: () => this.back(), tools: () => { this.refreshButton(); } })
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
  @Builder private refreshButton() {
    StoreImmersiveIconButton({ symbol: $r('sys.symbol.arrow_clockwise'), label: I18n.t('刷新'),
      loading: this.busy, visible: this.headerVisible, action: () => this.refresh(), backAction: () => this.back() })
  }
  pageTransition() {
    PageTransitionEnter(StorePageMotion.options(RouteType.Push)).slide(SlideEffect.Right).opacity(1)
    PageTransitionEnter(StorePageMotion.stationary(RouteType.Pop)).translate({ x: 0 }).opacity(1)
    PageTransitionExit(StorePageMotion.stationary(RouteType.Push)).translate({ x: 0 }).opacity(1)
    PageTransitionExit(StorePageMotion.options(RouteType.Pop)).slide(SlideEffect.Right).opacity(1)
  }
}
