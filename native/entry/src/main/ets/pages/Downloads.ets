import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { DownloadLibrary, DownloadedPackage } from '../jobs/DownloadLibrary';
import { DownloadShare } from '../jobs/DownloadShare';
import { DownloadDirectoryOpen } from '../jobs/DownloadDirectoryOpen';
import { DownloadPreferences } from '../jobs/DownloadPreferences';
import { JobStore } from '../jobs/JobStore';
import { errorText } from '../jobs/ErrorText';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { DownloadIconCache } from '../jobs/DownloadIconCache';
import { DownloadAnalysis } from '../jobs/DownloadAnalysis';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { InspectionField, InspectionSection } from '../data/InstalledInspection';
import { ListDataSource } from '../data/ListDataSource';
import { CatalogAppTitle } from '../components/CatalogAppTitle';
import { Palette } from '../theme/Palette';
import { StoreLayout, StorePageHeader, StoreImmersiveIconButton, StoreIconButton } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';
import { I18n } from '../data/I18n';

@Entry
@Component
struct Downloads {
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @StorageProp('windowWidth') private windowWidth: number = 0;
  @StorageProp('windowHeight') private windowHeight: number = 0;
  @StorageProp('navigationBottomInset') private navigationBottomInset: number = 0;
  @State private rows: DownloadedPackage[] = [];
  @State private icons: Map<string, image.PixelMap> = new Map();
  private decodedIcons: Map<string, image.PixelMap> = new Map();
  private iconFlights: Map<string, Promise<image.PixelMap | undefined>> = new Map();
  @State private loading: boolean = true;
  @State private working: boolean = false;
  @State private headerVisible: boolean = true;
  @State private notice: string = '';
  @State private showSettings: boolean = false;
  @State private autoClean: boolean = false;
  @State private settingsReading: boolean = false;
  @State private settingsNotice: string = '';
  @State private showAnalysis: boolean = false;
  @State private analysisRow: DownloadedPackage | undefined = undefined;
  @State private analysisSections: InspectionSection[] = [];
  @State private analysisLoading: boolean = false;
  @State private analysisNotice: string = '';
  private analysisToken: number = 0;
  private pageActive: boolean = true;
  private disposed: boolean = false;
  private returning: boolean = false;
  private sharing: boolean = false;
  private directoryOpening: boolean = false;
  private directoryToken: number = 0;
  private shareSession: DownloadShare = new DownloadShare();
  private showingClear: boolean = false;
  private readToken: number = 0;
  private backTimer: number = -1;
  private settingsOpening: boolean = false;
  private settingsReadToken: number = 0;
  private settingsVersion: number = 0;
  private settingsWrites: Promise<void> = Promise.resolve();
  private listRows: ListDataSource<DownloadedPackage> = new ListDataSource<DownloadedPackage>(
    (row: DownloadedPackage): string => row.id,
    (row: DownloadedPackage): string => JSON.stringify(row));

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  aboutToAppear(): void { this.disposed = false; }
  onPageShow(): void {
    this.pageActive = true;
    if (this.disposed || this.returning) return;
    this.headerVisible = !this.showingClear && !this.sharing &&
      !this.showSettings && !this.settingsOpening && !this.showAnalysis;
    this.load();
  }
  onPageHide(): void {
    this.pageActive = false; this.headerVisible = false; this.readToken++;
    this.directoryToken++;
    this.showSettings = false; this.settingsOpening = false; this.settingsReadToken++;
    this.closeAnalysis();
  }
  aboutToDisappear(): void {
    this.disposed = true; this.pageActive = false; this.headerVisible = false;
    this.directoryToken++;
    this.readToken++; this.settingsReadToken++; this.showSettings = false;
    this.closeAnalysis();
    clearTimeout(this.backTimer); this.shareSession.cancel();
    for (const pixels of this.decodedIcons.values()) pixels.release();
    this.decodedIcons.clear(); this.icons = new Map();
  }
  onBackPress(): boolean {
    if(StorePageMotion.dismissDevicePanel?.())return true;
    if (this.showAnalysis) { this.closeAnalysis(); return true; }
    if (this.showSettings) { this.closeSettings(); return true; }
    this.back(); return true;
  }
  private back(): void {
    if (this.disposed || this.returning) return;
    this.returning = true; this.headerVisible = false;
    this.directoryToken++;
    this.shareSession.cancel();
    StorePageMotion.prepare();
    this.backTimer = setTimeout(() => { if (!this.disposed) router.back(); }, 32);
  }
  private restoreHeader(): void {
    if (!this.disposed && !this.returning && this.pageActive && !this.sharing &&
      !this.showingClear && !this.showSettings && !this.settingsOpening && !this.showAnalysis) this.headerVisible = true;
  }
  private async load(): Promise<void> {
    const token = ++this.readToken;
    this.loading = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      let locationFailure = '';
      let archiveFailure = '';
      try {
        await DownloadLibrary.getLocation(context);
        if (this.disposed || !this.pageActive || token !== this.readToken) return;
      } catch (error) {
        if (this.disposed || !this.pageActive || token !== this.readToken) return;
        locationFailure = errorText(error);
      }
      if (!locationFailure) {
        try {
          const store = await JobStore.open(context);
          if (this.disposed || !this.pageActive || token !== this.readToken) return;
          await store.pruneCompleted(context);
        } catch (error) { archiveFailure = errorText(error); }
        if (this.disposed || !this.pageActive || token !== this.readToken) return;
      }
      const rows = await DownloadLibrary.list(context);
      if (this.disposed || !this.pageActive || token !== this.readToken) return;
      this.rows = rows; this.listRows.update(rows);
      this.pruneIcons(rows);
      this.loadIcons(context, rows, token);
      this.notice = locationFailure ? I18n.t('下载位置暂不可用：') + locationFailure :
        archiveFailure ? I18n.t('下载文件归档暂未完成：') + archiveFailure : '';
    } catch (error) {
      if (!this.disposed && this.pageActive && token === this.readToken) this.notice = errorText(error);
    } finally { if (!this.disposed && this.pageActive && token === this.readToken) this.loading = false; }
  }
  private downloadIcon(row: DownloadedPackage): image.PixelMap | undefined {
    return this.icons.get(DownloadIconCache.key(row));
  }
  private pruneIcons(rows: DownloadedPackage[]): void {
    const keys = new Set(rows.map((row: DownloadedPackage) => DownloadIconCache.key(row)));
    const current = new Map(this.icons);
    for (const key of current.keys()) if (!keys.has(key)) current.delete(key);
    if (current.size !== this.icons.size) this.icons = current;
    for (const key of this.decodedIcons.keys()) {
      if (!keys.has(key) && !this.iconFlights.has(key)) {
        this.decodedIcons.get(key)?.release(); this.decodedIcons.delete(key);
      }
    }
  }
  private readIcon(context: common.UIAbilityContext, row: DownloadedPackage): Promise<image.PixelMap | undefined> {
    const key = DownloadIconCache.key(row), pending = this.iconFlights.get(key);
    if (pending) return pending;
    const task = DownloadIconCache.load(context, row).then(async (bytes: ArrayBuffer | undefined): Promise<image.PixelMap | undefined> => {
      if (!bytes || this.disposed || !this.rows.some((current: DownloadedPackage) => DownloadIconCache.key(current) === key)) return undefined;
      const cached = this.decodedIcons.get(key);
      if (cached) return cached;
      const source = image.createImageSource(bytes);
      try {
        const info = await source.getImageInfo();
        if (!(info.size.width > 0 && info.size.height > 0) || info.size.width * info.size.height > 16777216) return undefined;
        const pixels = await source.createPixelMap({ desiredSize: { width: 96, height: 96 } });
        if (this.disposed || !this.rows.some((current: DownloadedPackage) => DownloadIconCache.key(current) === key)) {
          pixels.release(); return undefined;
        }
        this.decodedIcons.set(key, pixels); return pixels;
      } finally { source.release(); }
    }).catch((): image.PixelMap | undefined => undefined).finally(() => { this.iconFlights.delete(key); });
    this.iconFlights.set(key, task);
    return task;
  }
  private async loadIcons(context: common.UIAbilityContext, rows: DownloadedPackage[], token: number): Promise<void> {
    for (const row of rows) {
      if (this.disposed || !this.pageActive || token !== this.readToken) return;
      const pixels = await this.readIcon(context, row);
      if (this.disposed || !this.pageActive || token !== this.readToken ||
        !this.rows.some((current: DownloadedPackage) => current.id === row.id &&
          current.bundleName === row.bundleName && current.path === row.path)) return;
      const key = DownloadIconCache.key(row);
      if (pixels === this.icons.get(key)) continue;
      const current = new Map(this.icons);
      if (pixels) current.set(key, pixels); else current.delete(key);
      this.icons = current;
    }
  }
  private fileSize(bytes: number): string {
    if (!(bytes > 0)) return '0 B';
    if (bytes < 1024) return String(Math.round(bytes)) + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    return (bytes / 1073741824).toFixed(1) + ' GB';
  }
  private async remove(row: DownloadedPackage): Promise<void> {
    if (this.working || this.showAnalysis || this.disposed || this.returning) return;
    this.working = true; this.readToken++; this.loading = false;
    try {
      const removed = await DownloadLibrary.remove(getContext(this) as common.UIAbilityContext, row.id);
      if (!this.disposed) {
        await this.load();
        if (!this.disposed) promptAction.showToast({ message: removed ? I18n.t('已删除下载文件') : I18n.t('文件正在使用或已移除，请稍后重试') });
      }
    } catch (error) {
      if (!this.disposed) {
        const message = errorText(error); await this.load();
        if (!this.disposed) { this.notice = message; promptAction.showToast({ message: message }); }
      }
    } finally { if (!this.disposed) this.working = false; }
  }
  private async requestClear(): Promise<void> {
    if (this.working || this.showAnalysis || this.loading || !this.rows.length || this.disposed || this.returning) return;
    this.showingClear = true; this.headerVisible = false;
    await StorePageMotion.dismissFrame();
    if (this.disposed || this.returning || !this.pageActive) { this.showingClear = false; return; }
    try {
      AlertDialog.show({ title: I18n.t('删除全部下载文件？'), message: I18n.t('已安装的应用不受影响。'),
        cancel: () => { this.showingClear = false; this.restoreHeader(); },
        primaryButton: { value: I18n.t('取消'), action: () => { this.showingClear = false; this.restoreHeader(); } },
        secondaryButton: { value: I18n.t('删除'), action: () => { this.showingClear = false; this.restoreHeader(); this.clear(); } }
      });
    } catch (error) { this.showingClear = false; this.notice = errorText(error); this.restoreHeader(); }
  }
  private async clear(): Promise<void> {
    if (this.working || this.showAnalysis || this.disposed || this.returning) return;
    this.working = true; this.readToken++; this.loading = false;
    try {
      const count = await DownloadLibrary.clear(getContext(this) as common.UIAbilityContext);
      if (!this.disposed) {
        await this.load();
        if (!this.disposed) promptAction.showToast({ message: this.rows.length > 0 ?
          I18n.t('已删除 ') + count + I18n.t(' 个，未删除文件已保留，请稍后再试') : I18n.t('已删除 ') + count + I18n.t(' 个下载文件') });
      }
    } catch (error) {
      if (!this.disposed) {
        const message = errorText(error); await this.load();
        if (!this.disposed) { this.notice = message; promptAction.showToast({ message: message }); }
      }
    } finally { if (!this.disposed) this.working = false; }
  }
  private async share(row: DownloadedPackage): Promise<void> {
    if (this.working || this.showAnalysis || this.loading || this.disposed || this.returning) return;
    this.working = true; this.sharing = true; this.headerVisible = false; this.notice = '';
    let failure = '';
    try {
      await StorePageMotion.dismissFrame();
      if (this.disposed || this.returning || !this.pageActive) return;
      await this.shareSession.open(getContext(this) as common.UIAbilityContext, row.id);
    } catch (error) { failure = errorText(error); }
    finally {
      this.sharing = false;
      if (!this.disposed && !this.returning) {
        this.working = false; this.restoreHeader(); await this.load();
        if (!this.disposed && failure) this.notice = failure;
      }
    }
  }
  private async openDirectory(): Promise<void> {
    if (this.working || this.directoryOpening || this.showAnalysis || this.showSettings ||
      this.settingsOpening || this.showingClear || this.disposed || this.returning || !this.pageActive) return;
    const token = ++this.directoryToken;
    const isCurrent = (): boolean => token === this.directoryToken &&
      !this.disposed && !this.returning && this.pageActive;
    this.working = true; this.directoryOpening = true; this.notice = '';
    try {
      if (!isCurrent()) return;
      await DownloadDirectoryOpen.open(getContext(this) as common.UIAbilityContext, isCurrent);
    } catch (error) {
      if (isCurrent()) {
        this.notice = I18n.t('无法打开下载目录：') + errorText(error);
        promptAction.showToast({ message: this.notice });
      }
    } finally {
      this.directoryOpening = false;
      if (!this.disposed) { this.working = false; this.restoreHeader(); }
    }
  }
  private async openSettings(): Promise<void> {
    if (this.working || this.showAnalysis || this.showSettings || this.settingsOpening || this.disposed || this.returning) return;
    this.settingsOpening = true; this.headerVisible = false;
    await StorePageMotion.dismissFrame();
    this.settingsOpening = false;
    if (this.disposed || this.returning || !this.pageActive) return;
    this.showSettings = true; this.settingsReading = true; this.settingsNotice = '';
    const token = ++this.settingsReadToken;
    try {
      await this.settingsWrites;
      if (this.disposed || !this.showSettings || token !== this.settingsReadToken) return;
      const enabled = await DownloadPreferences.load(getContext(this) as common.UIAbilityContext);
      if (!this.disposed && this.showSettings && token === this.settingsReadToken) this.autoClean = enabled;
    } catch (error) {
      if (!this.disposed && this.showSettings && token === this.settingsReadToken) this.settingsNotice = errorText(error);
    } finally {
      if (!this.disposed && token === this.settingsReadToken) this.settingsReading = false;
    }
  }
  private closeSettings(): void {
    this.showSettings = false; this.settingsReadToken++; this.restoreHeader();
  }
  private changeAutoClean(enabled: boolean): void {
    if (this.settingsReading || this.disposed || this.returning || !this.showSettings || enabled === this.autoClean) return;
    this.autoClean = enabled; this.settingsNotice = '';
    const version = ++this.settingsVersion;
    const context = getContext(this) as common.UIAbilityContext;
    this.settingsWrites = this.settingsWrites.then(() => this.saveAutoClean(context, enabled, version));
  }
  private async saveAutoClean(context: common.UIAbilityContext, enabled: boolean, version: number): Promise<void> {
    try { await DownloadPreferences.save(context, enabled); }
    catch (error) {
      if (version !== this.settingsVersion) return;
      let previous = false;
      try { previous = await DownloadPreferences.load(context); } catch (_) {}
      if (!this.disposed && version === this.settingsVersion) {
        this.autoClean = previous; this.settingsNotice = I18n.t('保存失败：') + errorText(error);
      }
    }
  }
  private async analyze(row: DownloadedPackage): Promise<void> {
    if (this.working || this.loading || this.showAnalysis || this.showSettings || this.settingsOpening ||
      this.showingClear || this.disposed || this.returning || !this.pageActive) return;
    const token = ++this.analysisToken;
    this.analysisRow = row; this.analysisSections = []; this.analysisNotice = '';
    this.analysisLoading = true; this.showAnalysis = true; this.headerVisible = false;
    try {
      await StorePageMotion.dismissFrame();
      if (!this.analysisCurrent(token)) return;
      const sections = await DownloadAnalysis.read(getContext(this) as common.UIAbilityContext, row);
      if (this.analysisCurrent(token)) this.analysisSections = this.visibleAnalysisSections(sections);
    } catch (error) {
      if (this.analysisCurrent(token)) this.analysisNotice = errorText(error);
    } finally { if (this.analysisCurrent(token)) this.analysisLoading = false; }
  }
  private analysisCurrent(token: number): boolean {
    return !this.disposed && !this.returning && this.pageActive && this.showAnalysis && token === this.analysisToken;
  }
  private visibleAnalysisSections(sections: InspectionSection[]): InspectionSection[] {
    const visible: InspectionSection[] = [];
    for (const section of sections) {
      const fields = section.fields.filter((field: InspectionField) => {
        const value = field.value.trim(); return value.length > 0 && value !== '[]' && value !== '{}';
      });
      if (!fields.length) continue;
      const next = new InspectionSection(); next.name = section.name; next.fields = fields; visible.push(next);
    }
    return visible;
  }
  private closeAnalysis(): void {
    this.analysisToken++; this.showAnalysis = false; this.analysisLoading = false;
    this.analysisRow = undefined; this.analysisSections = []; this.analysisNotice = ''; this.restoreHeader();
  }
  private async copyAnalysisValue(value: string): Promise<void> {
    const token = this.analysisToken;
    if (!value.trim() || !this.analysisCurrent(token)) return;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
      if (this.analysisCurrent(token)) promptAction.showToast({ message: value, duration: 2500 });
    } catch (_) { if (this.analysisCurrent(token)) promptAction.showToast({ message: I18n.t('暂时无法复制，请重试') }); }
  }
  @Builder private tools() {
    Row({ space: 8 }) {
      StoreImmersiveIconButton({ symbol: $r('sys.symbol.trash'), label: I18n.t('删除全部下载文件'),
        controlId: 'downloads-clear', active: !this.working && !this.loading && this.rows.length > 0,
        visible: this.headerVisible, action: () => { this.requestClear(); }, backAction: () => { this.onBackPress(); } })
      StoreImmersiveIconButton({ symbol: $r('sys.symbol.gearshape'), label: I18n.t('下载设置'),
        controlId: 'downloads-settings', active: !this.working, visible: this.headerVisible,
        action: () => { this.openSettings(); }, backAction: () => { this.onBackPress(); } })
      StoreImmersiveIconButton({ symbol: $r('sys.symbol.folder'), label: I18n.t('打开下载目录'),
        controlId: 'downloads-directory', active: !this.working, visible: this.headerVisible,
        action: () => { this.openDirectory(); }, backAction: () => { this.onBackPress(); } })
    }
  }
  @Builder private deleteAction(row: DownloadedPackage) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(20).fontColor([this.colors().accent])
          Text(I18n.t('分析')).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().accent)
        }.justifyContent(FlexAlign.Center)
      }.width(64).height('100%').padding(0).enabled(!this.working && !this.loading && !this.showAnalysis)
        .backgroundColor(this.colors().accentSoft).borderRadius(16).accessibilityText(I18n.t('分析 ') + row.name)
        .id('downloads-analysis-' + row.id).onClick(() => { this.analyze(row); })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.share')).fontSize(20).fontColor([this.colors().accent])
          Text(I18n.t('分享')).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().accent)
        }.justifyContent(FlexAlign.Center)
      }.width(64).height('100%').padding(0).enabled(!this.working && !this.loading && !this.showAnalysis)
        .backgroundColor(this.colors().accentSoft).borderRadius(16).accessibilityText(I18n.t('分享 ') + row.name)
        .id('downloads-share-' + row.id).onClick(() => { this.share(row); })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.trash')).fontSize(20).fontColor([this.colors().onAccent])
          Text(I18n.t('删除')).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().onAccent)
        }.justifyContent(FlexAlign.Center)
      }.width(64).height('100%').padding(0).enabled(!this.working && !this.showAnalysis)
        .backgroundColor(this.colors().danger).borderRadius(16).accessibilityText(I18n.t('删除 ') + row.name)
        .id('downloads-delete-' + row.id).onClick(() => { this.remove(row); })
    }.height('100%').padding({ left: 8 })
  }
  @Builder private analysisDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.closeAnalysis())
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          if (this.analysisRow && this.downloadIcon(this.analysisRow)) {
            Image(this.downloadIcon(this.analysisRow)).width(40).height(40).borderRadius(11).objectFit(ImageFit.Contain)
          }
          Column({ space: 4 }) {
            Text(this.analysisRow?.title || this.analysisRow?.name || I18n.t('包分析')).fontSize(18)
              .fontWeight(FontWeight.Bold).fontColor(this.colors().text).maxLines(2)
            Text(this.analysisRow?.name || '').fontSize(11).fontColor(this.colors().textTertiary)
              .maxLines(2).wordBreak(WordBreak.BREAK_ALL)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          StoreIconButton({ label: I18n.t('关闭包分析'), action: () => this.closeAnalysis() })
        }.width('100%')
        Scroll() {
          Column({ space: 14 }) {
            if (this.analysisLoading) {
              Row({ space: 10 }) {
                LoadingProgress().width(22).height(22).color(this.colors().accent)
                Text(I18n.t('正在分析安装包')).fontSize(13).fontColor(this.colors().textSecondary)
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 18, bottom: 18 })
            }
            if (this.analysisNotice) {
              Text(this.analysisNotice).fontSize(12).fontColor(this.colors().danger).width('100%')
            } else if (!this.analysisLoading && !this.analysisSections.length) {
              Text(I18n.t('未读取到包信息')).fontSize(13).fontColor(this.colors().textSecondary).width('100%')
            }
            ForEach(this.analysisSections, (section: InspectionSection) => {
              Column({ space: 11 }) {
                Text(section.name).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.colors().text).width('100%')
                ForEach(section.fields, (field: InspectionField) => {
                  Row({ space: 12 }) {
                    Text(field.key).width('34%').fontSize(12).wordBreak(WordBreak.BREAK_ALL)
                      .fontColor(this.colors().textSecondary)
                    Text(field.value).layoutWeight(1).fontSize(13).wordBreak(WordBreak.BREAK_ALL)
                      .textAlign(TextAlign.End).fontColor(this.colors().text)
                      .onClick(() => { this.copyAnalysisValue(field.value); })
                  }.width('100%').alignItems(VerticalAlign.Top)
                }, (field: InspectionField, index: number) => field.key + ':' + index)
              }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
                .backgroundColor(this.colors().fill).borderRadius(14)
            }, (section: InspectionSection, index: number) => section.name + ':' + index)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
        .height(this.windowHeight > 0 ? Math.min(this.windowHeight * 0.72,
          StoreLayout.sheetMaxHeight(this.windowHeight, this.statusInset, this.navigationBottomInset)) : '72%')
        .padding(22).backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius).onClick(() => {})
    }.width('100%').height('100%').expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
  @Builder private settingsDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.closeSettings())
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text(I18n.t('下载设置')).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
          StoreIconButton({ action: () => this.closeSettings() })
        }.width('100%')
        Row({ space: 12 }) {
          Text(I18n.t('安装后自动清理')).fontSize(15).fontColor(this.colors().text).layoutWeight(1)
          if (this.settingsReading) { LoadingProgress().width(24).height(24).color(this.colors().accent); }
          else { Toggle({ type: ToggleType.Switch, isOn: this.autoClean }).selectedColor(this.colors().accent)
            .id('downloads-auto-clean').onChange((enabled: boolean) => this.changeAutoClean(enabled)); }
        }.width('100%').height(44)
        if (this.settingsNotice) { Text(this.settingsNotice).fontSize(12).fontColor(this.colors().danger).width('100%'); }
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
        .padding(22).backgroundColor(this.colors().surface).borderRadius(22).onClick(() => {})
    }.width('100%').height('100%').expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
  build() {
    Stack({ alignContent: Alignment.Top }) {
      List({ space: 11 }) {
        if (this.notice) { ListItem() { Text(this.notice).fontSize(12).fontColor(this.colors().danger).width('100%'); } }
        if (this.loading && this.rows.length === 0) {
          ListItem() { Row({ space: 10 }) {
            LoadingProgress().width(20).height(20).color(this.colors().accent)
            Text(I18n.t('正在读取下载文件')).fontSize(14).fontColor(this.colors().textSecondary)
          }.width('100%').justifyContent(FlexAlign.Center).padding(24); }
        } else if (!this.rows.length && !this.notice) {
          ListItem() { Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.arrow_down_to_line')).fontSize(32).fontColor([this.colors().accent])
            Text(I18n.t('暂无下载文件')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          }.width('100%').padding(32).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius); }
        }
        LazyForEach(this.listRows, (row: DownloadedPackage) => {
          ListItem() {
            Row({ space: 12 }) {
              if (this.downloadIcon(row)) {
                Image(this.downloadIcon(row)).width(46).height(46).borderRadius(13).objectFit(ImageFit.Contain)
              } else {
                Stack() { SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([this.colors().accent]); }
                  .width(46).height(46).backgroundColor(this.colors().accentSoft).borderRadius(13)
              }
              Column({ space: 5 }) {
                CatalogAppTitle({ title: row.title || row.name, titleSize: 15, titleLines: 2,
                  version: row.version, color: this.colors().text, versionColor: this.colors().surface,
                  versionBackground: this.colors().text })
                Text(row.name).fontSize(11).fontColor(this.colors().textSecondary).maxLines(2)
                  .wordBreak(WordBreak.BREAK_ALL)
                Text(this.fileSize(row.bytes)).fontSize(11).fontColor(this.colors().textTertiary)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding(15).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
          }.swipeAction({ end: { builder: () => { this.deleteAction(row); }, actionAreaDistance: 216 },
            edgeEffect: SwipeEdgeEffect.Spring })
        }, (row: DownloadedPackage) => this.listRows.key(row))
      }.width('100%').height('100%').align(Alignment.Top)
        .constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
        .padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth) })
        .contentStartOffset(this.statusInset + 76).contentEndOffset(Math.max(28, this.navigationBottomInset + 16))
        .scrollBar(BarState.Off).onDidScroll(() => ForegroundIdle.interaction())
      StorePageHeader({ title: I18n.t('下载'), statusInset: this.statusInset, visible: this.headerVisible,
        action: () => { this.onBackPress(); }, backAction: () => { this.onBackPress(); },
        tools: () => { this.tools(); } }).position({ x: 0, y: 0 })
      if (this.showSettings) { this.settingsDialog(); }
      if (this.showAnalysis) { this.analysisDialog(); }
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
