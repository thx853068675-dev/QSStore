import { DiscoverSort } from '../data/DiscoverSort';
import { Palette } from '../theme/Palette';
import { StoreImmersiveAction } from '../theme/StoreDesign';
import { deviceInfo } from '@kit.BasicServicesKit';
import { StoreMaterial } from '../theme/StoreMaterial';
import { I18n } from '../data/I18n';

/** A fixed capsule keeps sorting independent of the search/category morph and viewport mask. */
@Component
export struct DiscoverSortControl {
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') @Watch('closeMenuWhenHidden') private routeTransitioning: boolean = false;
  @Prop @Watch('closeMenuWhenHidden') active: boolean = true;
  @Prop @Watch('closeMenuWhenHidden') foreground: boolean = true;
  @Prop darkMode: boolean = false;
  @Prop sortKey: string = 'stars';
  @Prop sortDirection: string = 'desc';
  @Prop layoutMode: string = 'normal';
  onLayoutChange: (layout: string) => void = () => {};
  @Prop loading: boolean = false;
  @State private menuOpen: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverse: () => void = () => {};
  backAction: () => void = () => {};

  private closeMenuWhenHidden(): void {
    if (!this.active || !this.foreground || this.routeTransitioning) this.menuOpen = false;
  }
  private choose(key: string): void { this.menuOpen = false; this.onSort(key); }
  private chooseDirection(direction: string): void {
    this.menuOpen = false;
    if (direction !== this.sortDirection) this.onReverse();
  }

  private materialBack(): void {
    if (!this.active || !this.foreground || this.routeTransitioning) return;
    if (this.menuOpen) this.menuOpen = false;
    else this.backAction();
  }

  @Builder private layoutOption(layout: string, symbol: Resource, label: string) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph(symbol).fontSize(22)
        .fontColor([this.layoutMode === layout ? Palette.forMode(this.darkMode).accent : Palette.forMode(this.darkMode).textSecondary])
    }.layoutWeight(1).height(42).padding(0).borderRadius(12)
      .backgroundColor(this.layoutMode === layout ? Palette.forMode(this.darkMode).accentSoft : Color.Transparent)
      .accessibilityText(label).accessibilitySelected(this.layoutMode === layout)
      .id('discover-layout-' + layout)
      .onClick(() => { this.menuOpen = false; this.onLayoutChange(layout); })
  }

  @Builder private layoutPicker() {
    Row({ space: 6 }) {
      this.layoutOption('normal', $r('sys.symbol.list_bullet'), I18n.t('普通模式'))
      this.layoutOption('sidebar', $r('sys.symbol.rectangle_split_2x1'), I18n.t('侧边分栏'))
    }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  @Builder private sortOption(label: string, selected: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Text(label).fontSize(14).fontColor(Palette.forMode(this.darkMode).text).layoutWeight(1)
        if (selected) { SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14)
          .fontColor([Palette.forMode(this.darkMode).accent]) }
      }.width('100%')
    }.width('100%').height(42).padding({ left: 12, right: 12 }).borderRadius(10)
      .backgroundColor(Color.Transparent).onClick(action)
  }

  @Builder private sortMenu() {
    Column() {
      this.sortOption(I18n.sortLabel('stars'), this.sortKey === 'stars', () => this.choose('stars'))
      this.sortOption(I18n.sortLabel('downloads'), this.sortKey === 'downloads', () => this.choose('downloads'))
      this.sortOption(I18n.sortLabel('new'), this.sortKey === 'new', () => this.choose('new'))
      Divider().color(Palette.forMode(this.darkMode).border).margin({ top: 4, bottom: 4 })
      this.sortOption(I18n.t('升序'), this.sortDirection === 'asc', () => this.chooseDirection('asc'))
      this.sortOption(I18n.t('降序'), this.sortDirection === 'desc', () => this.chooseDirection('desc'))
      Divider().color(Palette.forMode(this.darkMode).border).margin({ top: 4, bottom: 4 })
      this.layoutPicker()
    }.width(196).padding(6)
  }

  @Builder private contents(immersive: boolean) {
    Button({ type: ButtonType.Normal }) {
      Text(DiscoverSort.label(this.sortKey)).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(StoreMaterial.foreground(this.darkMode,false,this.materialMode)).maxLines(1)
        .opacity(this.loading ? 0.65 : 1)
    }.width(44).height(44).padding(0).borderRadius(22).focusOnTouch(false)
      .backgroundColor(Color.Transparent).id('discover-sort-menu')
      .accessibilityText(I18n.t('排序，') + DiscoverSort.label(this.sortKey) + I18n.t('，') +
        (this.sortDirection === 'asc' ? I18n.t('升序') : I18n.t('降序')))
      .onClick(() => { this.menuOpen = !this.menuOpen; })
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : StoreMaterial.blurStyle(this.materialMode),
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .enabled(this.active && !this.routeTransitioning && (deviceInfo.sdkApiVersion < 26 || this.foreground))
      .bindPopup(this.menuOpen, {
        builder: this.sortMenu, width: 196, placement: Placement.BottomRight,
        targetSpace: 8, enableArrow: false, autoCancel: true, focusable: false,
        popupColor: Palette.forMode(this.darkMode).surface, backgroundBlurStyle: BlurStyle.NONE, radius: 18,
        onStateChange: (event: PopupStateChangeParam) => { if (!event.isVisible) this.menuOpen = false; }
      })
  }

  build() {
    // Inline controls remain mounted on API 24/25 while backgrounded. Only separate material windows need hiding.
    StoreImmersiveAction({ visible: this.active && (deviceInfo.sdkApiVersion < 26 || this.foreground), controlHeight: 44, controlRadius: 22,
      colored: false, tint: Palette.forMode(this.darkMode).surface, followsTarget: true,
      anchorAtStart: true, popupShadow: false,
      backAction: () => this.materialBack(),
      content: (immersive: boolean) => { this.contents(immersive); } }).width(44).height(44)
  }
}
