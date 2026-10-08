import { common, bundleManager } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { AppearanceMode, AppearancePreferences } from '../data/AppearancePreferences';
import { SettingsCache } from '../data/SettingsCache';
import { errorText } from '../jobs/ErrorText';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { Palette } from '../theme/Palette';
import { StoreLayout, StorePageHeader } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';

@Entry
@Component
struct Settings {
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('appearanceMode') private mode: string = 'system';
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @State private visible: boolean = true;
  @State private appearanceBusy: boolean = false;
  @State private appearanceMenuOpen: boolean = false;
  @State private cacheBusy: boolean = false;
  @State private cacheReading: boolean = true;
  @State private cacheSize: number = 0;
  @State private version: string = '';
  @State private versionCode: string = '';
  private disposed: boolean = false;
  private returning: boolean = false;
  private backTimer: number = -1;

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  aboutToAppear(): void {
    this.disposed = false;
    this.readCache();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        if (!this.disposed) { this.version = info.versionName; this.versionCode = String(info.versionCode); }
      }).catch(() => { if (!this.disposed) this.version = '暂时无法读取'; });
  }
  aboutToDisappear(): void {
    this.disposed = true; this.visible = false; this.appearanceMenuOpen = false;
    if (this.backTimer !== -1) clearTimeout(this.backTimer);
  }
  onPageShow(): void { if (!this.disposed && !this.returning) this.visible = true; }
  onPageHide(): void { this.visible = false; this.appearanceMenuOpen = false; }
  onBackPress(): boolean { this.back(); return true; }

  private back(): void {
    if (this.appearanceMenuOpen) { this.appearanceMenuOpen = false; return; }
    if (this.disposed || this.returning) return;
    this.returning = true;
    this.visible = false;
    // 收起材质浮层后只回到主页面，合并按钮和系统手势的重复返回回调。
    StorePageMotion.prepare();
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
        promptAction.showToast({ message: before > after ? '已释放 ' + SettingsCache.format(before - after) : '暂无可清理的闲置文件' });
      }
    } catch (error) { if (!this.disposed) promptAction.showToast({ message: errorText(error) }); }
    finally { if (!this.disposed) this.cacheBusy = false; }
  }

  @Builder private sectionTitle(title: string) {
    Text(title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
      .width('100%').padding({ left: 4 })
  }

  @Builder private settingRows() {
    Column() {
      Row({ space: 12 }) {
        Text('外观').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .layoutWeight(1).maxLines(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Text(this.mode === 'light' ? '浅色' : this.mode === 'dark' ? '深色' : '跟随系统')
              .fontSize(14).fontColor(this.colors().text)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.colors().textSecondary])
              .rotate({ angle: this.appearanceMenuOpen ? 180 : 0 })
              .animation({ duration: 180, curve: Curve.EaseOut })
          }.justifyContent(FlexAlign.Center)
        }.width(132).height(44).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.appearanceBusy).id('settings-appearance-select')
          .accessibilityText('外观，' + (this.mode === 'light' ? '浅色' : this.mode === 'dark' ? '深色' : '跟随系统'))
          .onClick(() => { this.appearanceMenuOpen = !this.appearanceMenuOpen; })
          .bindMenu(this.appearanceMenuOpen, [
            { value: '跟随系统', action: () => this.selectAppearance('system') },
            { value: '浅色', action: () => this.selectAppearance('light') },
            { value: '深色', action: () => this.selectAppearance('dark') }
          ], { placement: Placement.BottomRight, backgroundColor: this.colors().surface,
            backgroundBlurStyle: BlurStyle.NONE, borderRadius: 12,
            onDisappear: () => { this.appearanceMenuOpen = false; } })
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
      Divider().strokeWidth(0.5).color(this.colors().border).margin({ left: 16, right: 16 })
      Row({ space: 12 }) {
        Text('缓存管理').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .layoutWeight(1).maxLines(1)
        Text(this.cacheReading ? '读取中…' : SettingsCache.format(this.cacheSize))
          .fontSize(12).fontColor(this.colors().textSecondary).maxLines(1)
          .accessibilityText('图标、目录及安装临时文件缓存 ' + SettingsCache.format(this.cacheSize))
        Button({ type: ButtonType.Normal }) {
          if (this.cacheBusy) {
            LoadingProgress().width(18).height(18).color(this.colors().textSecondary)
          } else {
            Text('清理').fontSize(14).fontColor(this.colors().text)
          }
        }.width(132).height(44).borderRadius(12).backgroundColor(this.colors().fill).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 12 })
          .enabled(!this.cacheBusy && !this.cacheReading).id('settings-clean-cache')
          .accessibilityText(this.cacheBusy ? '正在清理缓存' : '清理图标、目录及闲置安装文件')
          .accessibilityDescription('保留未完成任务和签名材料').onClick(() => this.cleanCache())
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 })
    }.width('100%').backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius).clip(true)
  }

  @Builder private information(label: string, value: () => string) {
    Row({ space: 16 }) {
      Text(label).fontSize(14).fontColor(this.colors().textSecondary)
      Text(value() || '读取中…').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(2)
    }.width('100%').constraintSize({ minHeight: 28 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column({ space: 18 }) {
          this.settingRows()
          Column({ space: 8 }) {
            this.sectionTitle('版本信息')
            Column({ space: 4 }) {
              this.information('应用', () => '轻启·安装器')
              this.information('版本', () => this.version)
              this.information('内部编号', () => this.versionCode)
            }.width('100%').padding(16).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
          }.width('100%')
        }.width('100%').constraintSize({ maxWidth: StoreLayout.contentWidth })
          .padding({ left: 24, right: 24, top: this.statusInset + 72, bottom: 28 })
      }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
        .onDidScroll(() => ForegroundIdle.interaction())
      StorePageHeader({ title: '设置', statusInset: this.statusInset, visible: this.visible,
        action: () => { this.onBackPress(); }, backAction: () => { this.onBackPress(); } }).position({ x: 0, y: 0 })
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
