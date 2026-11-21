import { DiscoverSort } from '../data/DiscoverSort';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreImmersiveAction, StoreLayout } from '../theme/StoreDesign';
import { deviceInfo } from '@kit.BasicServicesKit';
import { StoreMaterial } from '../theme/StoreMaterial';
import { I18n } from '../data/I18n';

const CATEGORY_ROW_HEIGHT: number = 48;
const CATEGORY_ROW_GAP: number = 6;

@CustomDialog
struct DiscoverCategoryOrderDialog {
  controller?: CustomDialogController;
  initialOrder: string[] = [];
  onSave: (order: string[]) => Promise<void> = () => Promise.resolve();
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('windowHeight') private windowHeight: number = 0;
  @State private draft: string[] = [];
  @State private saving: boolean = false;
  @State private saveFailed: boolean = false;

  aboutToAppear(): void {
    this.draft = this.initialOrder.slice();
  }

  private move(from: number, to: number): void {
    if (this.saving || from === to || from < 0 || to < 0 ||
      from >= this.draft.length || to >= this.draft.length) return;
    const category = this.draft.splice(from, 1)[0];
    this.draft.splice(to, 0, category);
  }

  private async save(order: string[]): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    this.saveFailed = false;
    try {
      await this.onSave(order);
      this.controller?.close();
    } catch (_) {
      this.saveFailed = true;
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(I18n.t('分类顺序')).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(Palette.forMode(this.darkMode).text).layoutWeight(1)
        StoreIconButton({ active: !this.saving, action: (): void => { this.controller?.close(); } })
      }.width('100%')
      List({ space: CATEGORY_ROW_GAP }) {
        ForEach(this.draft, (category: string) => {
          ListItem() {
            Row({ space: 8 }) {
              Blank().width(28)
              Text(I18n.category(category)).fontSize(15).fontColor(Palette.forMode(this.darkMode).text)
                .textAlign(TextAlign.Center).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Column({ space: 3 }) {
                ForEach([0, 1, 2], (_row: number) => {
                  Row({ space: 3 }) {
                    Circle().width(3).height(3).fill(Palette.forMode(this.darkMode).textTertiary)
                    Circle().width(3).height(3).fill(Palette.forMode(this.darkMode).textTertiary)
                  }
                }, (row: number) => String(row))
              }.width(28).alignItems(HorizontalAlign.Center).accessibilityLevel('no-hide-descendants')
            }.width('100%').height(CATEGORY_ROW_HEIGHT).padding({ left: 6, right: 6 })
          }.width('90%').borderRadius(12).backgroundColor(Palette.forMode(this.darkMode).fill)
            .accessibilityDescription(I18n.t('长按拖动排序'))
        }, (category: string) => category)
          .onMove((from: number, to: number) => this.move(from, to))
      }.width('100%').height(Math.min(this.draft.length * (CATEGORY_ROW_HEIGHT + CATEGORY_ROW_GAP) + CATEGORY_ROW_GAP,
        this.windowHeight > 0 ? this.windowHeight * 0.48 : 280))
        .alignListItem(ListItemAlign.Center).contentStartOffset(CATEGORY_ROW_GAP).contentEndOffset(CATEGORY_ROW_GAP)
        .scrollBar(BarState.Auto).enabled(!this.saving)
      if (this.saveFailed) {
        Text(I18n.t('排序设置保存失败')).fontSize(12).fontColor(Palette.forMode(this.darkMode).danger)
      }
      Row({ space: 10 }) {
        Button(I18n.t('恢复默认')).layoutWeight(1).height(44)
          .backgroundColor(Palette.forMode(this.darkMode).fill).fontColor(Palette.forMode(this.darkMode).text)
          .enabled(!this.saving).onClick(() => this.save([]))
        Button(I18n.t('完成')).layoutWeight(1).height(44)
          .backgroundColor(Palette.forMode(this.darkMode).accent).fontColor(Palette.forMode(this.darkMode).onAccent)
          .enabled(!this.saving).onClick(() => this.save(this.draft))
      }.width('100%')
    }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
      .padding(20).borderRadius(StoreLayout.dialogRadius).backgroundColor(Palette.forMode(this.darkMode).surface)
  }
}

/** A fixed capsule keeps sorting independent of the search/category morph and viewport mask. */
@Component
export struct DiscoverSortControl {
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') @Watch('closeMenuWhenHidden') private routeTransitioning: boolean = false;
  @Prop @Watch('closeMenuWhenHidden') active: boolean = true;
  @Prop @Watch('closeMenuWhenHidden') foreground: boolean = true;
  @Prop @Watch('closeMenuWhenHidden') suspendPopup: boolean = false;
  @Prop darkMode: boolean = false;
  @Prop sortKey: string = 'stars';
  @Prop sortDirection: string = 'desc';
  @Prop layoutMode: string = 'normal';
  onLayoutChange: (layout: string) => void = () => {};
  @Prop toolbarRows: number = 1;
  onToolbarRowsChange: (rows: number) => void = () => {};
  @Prop menuMaxHeight: number = 360;
  @Prop loading: boolean = false;
  @State private menuOpen: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverse: () => void = () => {};
  @Prop categories: string[] = [];
  onSaveCategoryOrder: (order: string[]) => Promise<void> = () => Promise.resolve();
  private categoryOrderDialog?: CustomDialogController;
  backAction: () => void = () => {};

  aboutToDisappear(): void {
    this.categoryOrderDialog?.close();
  }

  private openCategoryOrder(): void {
    this.menuOpen = false;
    this.categoryOrderDialog?.close();
    this.categoryOrderDialog = new CustomDialogController({
      builder: DiscoverCategoryOrderDialog({ initialOrder: this.categories.slice(), onSave: this.onSaveCategoryOrder }),
      alignment: DialogAlignment.Center, autoCancel: true, customStyle: true
    });
    this.categoryOrderDialog.open();
  }

  private closeMenuWhenHidden(): void {
    if (!this.active || !this.foreground || this.routeTransitioning || this.suspendPopup) this.menuOpen = false;
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

  @Builder private toolbarOption(rows: number, label: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        ForEach(rows === 2 ? [0, 1] : [0], (_line: number) => {
          Row().width(22).height(5).borderRadius(2.5)
            .backgroundColor(this.toolbarRows === rows ? Palette.forMode(this.darkMode).accent :
              Palette.forMode(this.darkMode).textSecondary)
        }, (line: number) => String(line))
      }
    }.layoutWeight(1).height(42).padding(0).borderRadius(12)
      .backgroundColor(this.toolbarRows === rows ? Palette.forMode(this.darkMode).accentSoft : Color.Transparent)
      .accessibilityText(label).accessibilitySelected(this.toolbarRows === rows)
      .id('discover-toolbar-rows-' + rows)
      .onClick(() => { this.menuOpen = false; this.onToolbarRowsChange(rows); })
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
    Scroll() {
      Column() {
        this.sortOption(I18n.sortLabel('stars'), this.sortKey === 'stars', () => this.choose('stars'))
        this.sortOption(I18n.sortLabel('downloads'), this.sortKey === 'downloads', () => this.choose('downloads'))
        this.sortOption(I18n.sortLabel('new'), this.sortKey === 'new', () => this.choose('new'))
        Divider().color(Palette.forMode(this.darkMode).border).margin({ top: 4, bottom: 4 })
        this.sortOption(I18n.t('升序'), this.sortDirection === 'asc', () => this.chooseDirection('asc'))
        this.sortOption(I18n.t('降序'), this.sortDirection === 'desc', () => this.chooseDirection('desc'))
        Divider().color(Palette.forMode(this.darkMode).border).margin({ top: 4, bottom: 4 })
        if (this.categories.length > 1) {
          this.sortOption(I18n.t('分类顺序'), false, () => this.openCategoryOrder())
          Divider().color(Palette.forMode(this.darkMode).border).margin({ top: 4, bottom: 4 })
        }
        this.layoutPicker()
        Row({ space: 6 }) {
          this.toolbarOption(1, I18n.t('单行工具栏'))
          this.toolbarOption(2, I18n.t('双行工具栏'))
        }.width('100%').padding({ left: 8, right: 8, top: 2, bottom: 6 })
      }.width('100%').padding(6)
    }.width(196).constraintSize({ maxHeight: this.menuMaxHeight }).scrollBar(BarState.Auto)
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
    StoreImmersiveAction({ visible: this.active && (deviceInfo.sdkApiVersion < 26 || this.foreground),
      suspendPopup: this.suspendPopup, controlHeight: 44, controlRadius: 22,
      colored: false, tint: Palette.forMode(this.darkMode).surface, followsTarget: true,
      anchorAtStart: true, popupShadow: false,
      backAction: () => this.materialBack(),
      content: (immersive: boolean) => { this.contents(immersive); } }).width(44).height(44)
  }
}
