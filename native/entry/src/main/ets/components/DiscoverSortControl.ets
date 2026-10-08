import { DiscoverSort } from '../data/DiscoverSort';
import { Palette } from '../theme/Palette';
import { StoreImmersiveAction } from '../theme/StoreDesign';
import { deviceInfo } from '@kit.BasicServicesKit';

/** A fixed capsule keeps sorting independent of the search/category morph and viewport mask. */
@Component
export struct DiscoverSortControl {
  @StorageProp('routeTransitioning') @Watch('closeMenuWhenHidden') private routeTransitioning: boolean = false;
  @Prop @Watch('closeMenuWhenHidden') active: boolean = true;
  @Prop @Watch('closeMenuWhenHidden') foreground: boolean = true;
  @Prop darkMode: boolean = false;
  @Prop sortKey: string = 'discover';
  @Prop sortDirection: string = 'desc';
  @Prop loading: boolean = false;
  @State private menuOpen: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverse: () => void = () => {};

  private closeMenuWhenHidden(): void {
    if (!this.active || !this.foreground || this.routeTransitioning) this.menuOpen = false;
  }
  private choose(key: string): void { this.menuOpen = false; this.onSort(key); }
  private chooseDirection(direction: string): void {
    this.menuOpen = false;
    if (direction !== this.sortDirection) this.onReverse();
  }

  @Builder private sortMenu() {
    Menu() {
      MenuItem({ content: '推荐', labelInfo: this.sortKey === 'discover' ? '✓' : '' })
        .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(() => this.choose('discover'))
      MenuItem({ content: '星数', labelInfo: this.sortKey === 'stars' ? '✓' : '' })
        .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(() => this.choose('stars'))
      MenuItem({ content: '下载', labelInfo: this.sortKey === 'downloads' ? '✓' : '' })
        .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(() => this.choose('downloads'))
      MenuItem({ content: '上架', labelInfo: this.sortKey === 'new' ? '✓' : '' })
        .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(() => this.choose('new'))
      MenuItemGroup() {
        MenuItem({ content: '升序', labelInfo: this.sortDirection === 'asc' ? '✓' : '' })
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent)
          .onClick(() => this.chooseDirection('asc'))
        MenuItem({ content: '降序', labelInfo: this.sortDirection === 'desc' ? '✓' : '' })
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent)
          .onClick(() => this.chooseDirection('desc'))
      }
    }
  }

  @Builder private contents(immersive: boolean) {
    Button({ type: ButtonType.Normal }) {
      Text(DiscoverSort.label(this.sortKey)).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(Palette.forMode(this.darkMode).text).maxLines(1)
        .opacity(this.loading ? 0.65 : 1)
    }.width(48).height(44).padding(0).borderRadius(22).focusOnTouch(false)
      .backgroundColor(Color.Transparent).id('discover-sort-menu')
      .accessibilityText('排序，' + DiscoverSort.label(this.sortKey) + '，' +
        (this.sortDirection === 'asc' ? '升序' : '降序'))
      .onClick(() => { this.menuOpen = !this.menuOpen; })
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : BlurStyle.COMPONENT_THIN,
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .enabled(this.active && !this.routeTransitioning && (deviceInfo.sdkApiVersion < 26 || this.foreground))
      .bindMenu(this.menuOpen, this.sortMenu, {
        placement: Placement.BottomRight, backgroundColor: Palette.forMode(this.darkMode).surface,
        backgroundBlurStyle: BlurStyle.NONE, borderRadius: 18,
        onDisappear: () => { this.menuOpen = false; }
      })
  }

  build() {
    // Inline controls remain mounted on API 24/25 while backgrounded. Only separate material windows need hiding.
    StoreImmersiveAction({ visible: this.active && (deviceInfo.sdkApiVersion < 26 || this.foreground), controlHeight: 44, controlRadius: 22,
      colored: false, tint: Palette.forMode(this.darkMode).surface, followsTarget: true,
      anchorAtStart: true, popupShadow: false,
      backAction: () => { this.menuOpen = false; },
      content: (immersive: boolean) => { this.contents(immersive); } }).width(48).height(44)
  }
}
