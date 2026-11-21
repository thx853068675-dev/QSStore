import { DiscoverCategorySlice } from './DiscoverCategorySlice';
import { DiscoverSortControl } from './DiscoverSortControl';
import { afterPaint } from '../theme/AfterPaint';
import { HomeVisibility } from '../theme/HomeVisibility';
import { AnimatorOptions, AnimatorResult, PathShape } from '@kit.ArkUI';
import { Palette } from '../theme/Palette';
import { StoreLayout, StoreImmersiveAction } from '../theme/StoreDesign';
import { StoreMaterial } from '../theme/StoreMaterial';
import { I18n } from '../data/I18n';

/** Search resizing and category reveal share one timing curve. */
export class DiscoverToolbarMotion {
  static readonly controlHeight: number = 44;
  static readonly feedbackInset: number = 14;
  static readonly paintHeight: number = DiscoverToolbarMotion.controlHeight + 2 * DiscoverToolbarMotion.feedbackInset;
  static readonly channelHeight: number = 52;
  static readonly secondRowOffset: number = 54;
  static height(rows: number): number { return 70 + (rows === 2 ? DiscoverToolbarMotion.secondRowOffset : 0); }
  static options(begin: number, end: number): AnimatorOptions {
    return { duration: 420, easing: 'cubic-bezier(0.32, 0.08, 0.2, 1)', begin: begin, end: end,
      delay: 0, fill: 'forwards', direction: 'normal', iterations: 1 };
  }
  static searchControlWidth(width: number, landscape: boolean, progress: number): number {
    if (landscape) return Math.max(44, width / 4);
    const full = Math.max(44, width - 108);
    return full + (44 - full) * progress;
  }
  static categoryControlWidth(width: number, landscape: boolean, progress: number): number {
    if (landscape) return Math.max(44, width - DiscoverToolbarMotion.searchControlWidth(width, true, 1) - 64);
    return 44 + (Math.max(44, width - 108) - 44) * progress;
  }
}

/** The visible edges follow the 44 vp pills, independently of their vertical feedback room. */
export class DiscoverToolbarViewport {
  // Path commands use physical pixels; all inputs must be converted together by the owning UIContext.
  static path(width: number, height: number, inset: number): string {
    const totalHeight = height + 2 * inset;
    // A closed entry contains a single circular material; only horizontal overflow needs clipping.
    if (width <= height + 0.01) return 'M 0 0 H ' + width + ' V ' + totalHeight + ' H 0 Z';
    const radius = height / 2;
    const end = width - radius;
    const middle = inset + radius;
    const bottom = inset + height;
    // Union a central feedback strip with an exact-height capsule. Extra height cannot flatten either arc.
    return 'M ' + radius + ' 0 H ' + end + ' V ' + totalHeight + ' H ' + radius + ' Z ' +
      'M ' + radius + ' ' + inset + ' H ' + end +
      ' A ' + radius + ' ' + radius + ' 0 0 1 ' + width + ' ' + middle +
      ' A ' + radius + ' ' + radius + ' 0 0 1 ' + end + ' ' + bottom + ' H ' + radius +
      ' A ' + radius + ' ' + radius + ' 0 0 1 0 ' + middle +
      ' A ' + radius + ' ' + radius + ' 0 0 1 ' + radius + ' ' + inset + ' Z';
  }
}

/** Native scroll callbacks can run while ArkUI is still collecting UI reads. */
class DiscoverScrollBaseline {
  startOffset: number = 0;
  lastDistance: number = 0;
}

/** 只通知顶部组件；滚动不能触发整页卡片及同步安装状态查询。 */
@Observed
export class DiscoverMotion {
  @Track scrollOffset: number = 0;
  @Track pullOffset: number = 0;
  @Track showTop: boolean = false;
  // Track the stable reference so reentrant layout reads are legal. The plain
  // baseline itself does not notify UI observers on every scroll sample.
  @Track private baseline: DiscoverScrollBaseline = new DiscoverScrollBaseline();

  reachStart(offset: number): void {
    if (Number.isFinite(offset)) this.baseline.startOffset = offset;
    this.baseline.lastDistance = 0;
    this.revealChannelRow();
    this.showTop = false;
  }

  revealChannelRow(): void {
    this.scrollOffset = 0;
  }

  scroll(offset: number, fromUser: boolean): number {
    if (!Number.isFinite(offset)) return this.baseline.lastDistance;
    const distance = this.pullOffset > 0 ? 0 : Math.max(0, offset - this.baseline.startOffset);
    const delta = fromUser ? distance - this.baseline.lastDistance : 0;
    this.baseline.lastDistance = distance;
    // Restoring a saved position updates the baseline without hiding the row.
    const hidden = Math.max(0, Math.min(distance, DiscoverToolbarMotion.channelHeight, this.scrollOffset + delta));
    if (hidden !== this.scrollOffset) this.scrollOffset = hidden;
    const showTop = distance > 240;
    if (showTop !== this.showTop) this.showTop = showTop;
    return distance;
  }

  pull(offset: number): void {
    const next = Math.max(0, offset);
    if (next !== this.pullOffset) this.pullOffset = next;
    if (next > 0) {
      this.baseline.lastDistance = 0;
      this.scrollOffset = 0;
    }
  }

}

/** Native light material is mounted inside the fixed rounded NavDestination viewport. */
@Component
struct DiscoverGlassButton {
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') private routeTransitioning: boolean = false;
  @ObjectLink slice: DiscoverCategorySlice;
  @Prop darkMode: boolean = false;
  @Prop active: boolean = true;
  @Prop suspendPopup: boolean = false;
  @Prop controlWidth: number = 100;
  @Prop controlHeight: number = 44;
  @Prop label: string = '';
  @Prop morphing: boolean = false;
  @Prop morphProgress: number = 1;
  @Prop controlOpacity: number = 1;
  @Prop symbol: Resource | undefined = undefined;
  @Prop selected: boolean = false;
  controlId: string = '';
  accessibilityLabel: string = '';
  action: () => void = () => {};
  backAction: () => void = () => {};
  relayHorizontalDrag: boolean = false;
  dragStart: () => void = () => {};
  dragUpdate: (offset: number) => void = () => {};
  dragEnd: (velocity: number) => void = () => {};

  private selectedFill(): string {
    if (!this.selected) return '#00000000';
    const alpha = Math.round(235 * (this.morphing ? this.morphProgress : 1));
    return '#' + alpha.toString(16).padStart(2, '0') + Palette.forMode(this.darkMode).selectionRose.substring(1);
  }

  private contentColor(): ResourceColor {
    return this.selected && (!this.morphing || this.morphProgress > 0.5) ? '#FFFFFF' :
      StoreMaterial.foreground(this.darkMode,false,this.materialMode);
  }

  private contentIconColor(): ResourceColor {
    return this.selected && (!this.morphing || this.morphProgress > 0.5) ? '#FFFFFF' :
      StoreMaterial.icon(this.darkMode,this.materialMode);
  }

  @Builder
  private buttonContents() {
    if (this.morphing) {
      Stack() {
        SymbolGlyph(this.symbol).fontSize(17).fontColor([this.contentIconColor()])
          .opacity(1 - this.morphProgress).scale({ x: 1 - 0.12 * this.morphProgress, y: 1 - 0.12 * this.morphProgress })
          .rotate({ angle: 45 * this.morphProgress }).accessibilityLevel('no')
        Text(this.label).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.contentColor())
          .opacity(this.morphProgress).translate({ x: 6 * (1 - this.morphProgress) })
          .scale({ x: 0.9 + 0.1 * this.morphProgress, y: 0.9 + 0.1 * this.morphProgress })
          .accessibilityLevel('no')
      }.width('100%').height('100%')
    } else {
      Row({ space: 7 }) {
        if (this.symbol !== undefined) {
          SymbolGlyph(this.symbol).fontSize(17).fontColor([this.contentIconColor()])
        }
        Text(this.label).fontSize(14).fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.contentColor()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.justifyContent(FlexAlign.Center)
    }
  }

  @Styles
  private controlLayout() {
    .width(this.controlWidth).height(this.controlHeight).borderRadius(this.controlHeight / 2)
      .padding(0).opacity(this.controlOpacity)
      .accessibilitySelected(this.selected && (!this.morphing || this.morphProgress > 0.5))
      .id(this.controlId).accessibilityText(this.accessibilityLabel || this.label)
      .enabled(this.active && !this.routeTransitioning).onClick(() => this.action())
  }

  @Builder
  private actionContents(immersive: boolean) {
    Button({ type: ButtonType.Normal }) {
      Stack() {
        // The fallback tint belongs above the blur, not behind its opaque light
        // material. At morphProgress=0 only the circular glass base remains.
        if (!immersive && this.selected) {
          Row().width('100%').height('100%').borderRadius(this.controlHeight / 2)
            .backgroundColor(this.selectedFill()).hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no-hide-descendants')
        }
        Stack() { this.buttonContents() }.width('100%').height('100%').padding({ left: 12, right: 12 })
      }.width('100%').height('100%')
    }
      .controlLayout().stateEffect(true)
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : StoreMaterial.blurStyle(this.materialMode),
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .parallelGesture(PanGesture({direction:this.relayHorizontalDrag&&immersive?PanDirection.Horizontal:PanDirection.None})
        .onActionStart(()=>this.dragStart()).onActionUpdate((event:GestureEvent)=>this.dragUpdate(event.offsetX))
        .onActionEnd((event:GestureEvent)=>this.dragEnd(event.velocityX)))
  }

  build() {
    StoreImmersiveAction({ visible: this.active && this.slice.materialVisible, controlHeight: this.controlHeight,
      suspendPopup: this.suspendPopup,
      embedded: true, viewportOffset: this.slice.viewportOffset, popupShadow: false,
      controlRadius: this.controlHeight / 2, followsTarget: true, anchorAtStart: true,
      colored: this.selected, tint: this.selected ? Palette.forMode(this.darkMode).selectionRose :
        Palette.forMode(this.darkMode).surface, tintStrength: this.morphing ? this.morphProgress : 1,
      backAction: this.backAction,
      content: (immersive: boolean) => { this.actionContents(immersive); } })
      .width(this.controlWidth).height(this.controlHeight)
  }

}

@Component
export struct DiscoverHeader {
  @StorageProp('windowWidth') @Watch('onViewportChanged') private windowWidth: number = 0;
  @StorageProp('windowHeight') @Watch('onViewportChanged') private windowHeight: number = 0;
  @StorageProp('installTargetCount') private installTargetCount:number=1;
  @StorageProp('installTargetName') private installTargetName:string='';
  @StorageProp('materialMode') @Watch('onMaterialChanged') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') @Watch('refreshPopup') private routeTransitioning:boolean=false;
  @ObjectLink motion: DiscoverMotion;
  @ObjectLink @Watch('refreshPopup') homeVisibility: HomeVisibility;
  @Prop darkMode: boolean = false;
  @Prop starfield: boolean = false;
  @Prop statusInset: number = 0;
  @Prop inset: number = 20;
  @Prop @Watch('refreshPopup') active: boolean = true;
  @Prop @Watch('onCategoriesChanged') categories: string[] = [];
  @Prop selectedCategory: string = '';
  @Prop sortKey: string = 'stars';
  @Prop sortDirection: string = 'desc';
  @Prop layoutMode: string = 'normal';
  onLayoutChange: (layout: string) => void = () => {};
  @Prop @Watch('onViewportChanged') toolbarRows: number = 1;
  onToolbarRowsChange: (rows: number) => void = () => {};
  /** 顶部频道：discover=合集推荐，apps=全量应用（保留搜索、分类与排序工具栏）。 */
  @Prop @Watch('refreshPopup') channel: string = 'discover';
  @Prop @Watch('refreshPopup') channelInMotion: boolean = false;
  /** 横滑进度同时驱动频道强调和工具栏淡入。 */
  @Prop channelProgress: number = 0;
  onChannel: (channel: string) => void = () => {};
  @Prop sortLoading: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverseSort: () => void = () => {};
  onSaveCategoryOrder: (order: string[]) => Promise<void> = () => Promise.resolve();
  @Prop @Watch('onToolbarModeChanged') categoriesExpanded: boolean = false;
  @State private categoriesOpen: boolean = false;
  @State private toolbarProgress: number = 0;
  @BuilderParam searchContent: () => void;
  onToggleCategories: () => void = () => {};
  onOpenSearch: () => void = () => {};
  onMotionStateChanged: (moving: boolean) => void = () => {};
  onCategory: (category: string) => void = () => {};
  backAction: () => void = () => {};
  private categoryScroller: Scroller = new Scroller();
  private categoryOffset: number = 0;
  private categoryDragOffset: number = 0;
  private categorySlices: Map<string, DiscoverCategorySlice> = new Map();
  @State private popupReady: boolean = false;
  private popupGeneration: number = 0;
  private toolbarMotionGeneration: number = 0;
  private toolbarAnimator: AnimatorResult | undefined = undefined;
  private disposed: boolean = false;
  @State private searchPopupVisible: boolean = false;
  @State private immersiveSupported: boolean = StoreMaterial.supported(this.materialMode);
  @State private firstChannelWidth: number = 44;


  aboutToAppear(): void {
    this.disposed = false;
    this.categoriesOpen = this.toolbarRows === 2 || this.isLandscape() || this.categoriesExpanded;
    this.toolbarProgress = this.categoriesOpen ? 1 : 0;
    if (!this.categoriesOpen) this.categoryOffset = 0;
    this.refreshCategorySlices();
    this.refreshPopup();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.popupGeneration++;
    this.popupReady = false;
    this.searchPopupVisible = false;
    this.toolbarMotionGeneration++;
    this.toolbarAnimator?.cancel();
    this.toolbarAnimator = undefined;
    this.onMotionStateChanged(false);
  }

  private onToolbarModeChanged(): void {
    const expanded = this.toolbarRows === 2 || this.isLandscape() || this.categoriesExpanded;
    if (this.categoriesOpen === expanded) return;
    const generation = ++this.toolbarMotionGeneration;
    this.toolbarAnimator?.cancel();
    this.categoriesOpen = expanded;
    const target = this.categoriesOpen ? 1 : 0;
    const startProgress = this.toolbarProgress;
    const startOffset = this.categoryOffset;
    this.onMotionStateChanged(true);
    const animation = this.getUIContext().createAnimator(DiscoverToolbarMotion.options(this.toolbarProgress, target));
    this.toolbarAnimator = animation;
    animation.onFrame = (progress: number): void => {
      if (this.disposed || generation !== this.toolbarMotionGeneration) return;
      this.toolbarProgress = Math.min(1, Math.max(0, progress));
      if (target === 0 && startProgress > 0 && startOffset > 0) {
        this.categoryOffset = startOffset * this.toolbarProgress / startProgress;
        this.categoryScroller.scrollTo({ xOffset: this.categoryOffset, yOffset: 0, animation: false });
      }
      this.refreshCategorySlices();
    };
    animation.onFinish = (): void => {
      if (this.disposed || generation !== this.toolbarMotionGeneration) return;
      this.toolbarProgress = target;
      if (target === 0 && this.categoryOffset !== 0) {
        this.categoryOffset = 0;
        this.categoryScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      }
      this.refreshCategorySlices();
      this.toolbarAnimator = undefined;
      this.onMotionStateChanged(false);
    };
    animation.play();
  }

  private searchControlWidth(): number {
    if (this.toolbarRows === 2) return Math.max(44, this.toolbarWidth());
    return DiscoverToolbarMotion.searchControlWidth(this.toolbarWidth(), this.isLandscape(), this.toolbarProgress);
  }

  private categoryControlWidth(): number {
    if (this.toolbarRows === 2) return Math.max(44, this.toolbarWidth() - DiscoverToolbarMotion.secondRowOffset);
    return DiscoverToolbarMotion.categoryControlWidth(this.toolbarWidth(), this.isLandscape(), this.toolbarProgress);
  }

  private isLandscape(): boolean { return this.windowWidth > this.windowHeight && this.windowHeight > 0; }
  /** 与首页正文同宽：横屏放宽到双列版面，避免标题栏和卡片左右错位。 */
  private contentWidth(): number {
    return StoreLayout.discoverContentWidth(this.windowWidth, this.windowHeight);
  }

  private toolbarWidth(): number {
    // Both rows use the same viewport geometry, including on their first frame.
    return Math.max(0, this.windowWidth - 2 * StoreLayout.contentInset(this.windowWidth, this.windowHeight));
  }

  private sortMenuMaxHeight(): number {
    if (this.windowHeight <= 0) return 360;
    const heading = DiscoverToolbarMotion.channelHeight - this.motion.scrollOffset;
    const available = this.windowHeight - this.statusInset - heading - DiscoverToolbarMotion.height(this.toolbarRows) - 16;
    return Math.max(100, Math.min(360, available));
  }

  private onViewportChanged(): void {
    if (this.disposed) return;
    const generation = ++this.toolbarMotionGeneration;
    this.toolbarAnimator?.cancel(); this.toolbarAnimator = undefined;
    this.categoriesOpen = this.toolbarRows === 2 || this.isLandscape() || this.categoriesExpanded;
    this.toolbarProgress = this.categoriesOpen ? 1 : 0;
    if (!this.categoriesOpen) {
      this.categoryOffset = 0;
      if (this.channel === 'apps') {
        afterPaint(this.getUIContext(), () => {
          if (this.disposed || generation !== this.toolbarMotionGeneration ||
            this.categoriesOpen || !this.toolbarInteractive() || this.toolbarWidth() <= 0) return;
          try {
            if (this.categoryScroller.currentOffset().xOffset > 0) {
              this.categoryScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
            }
          } catch (_) { /* The scroller can still be unbound if the channel just changed. */ }
        });
      }
    }
    this.refreshCategorySlices();
    // A rotation changes popup coordinates as well as width. Retire old hit regions before remounting.
    this.popupGeneration++; this.popupReady = false; this.searchPopupVisible = false; this.refreshPopup();
    this.onMotionStateChanged(false);
  }

  private onMaterialChanged(): void {
    if(this.disposed)return;
    this.popupGeneration++;this.popupReady=false;this.searchPopupVisible=false;
    this.immersiveSupported=StoreMaterial.supported(this.materialMode);
    this.refreshPopup();
  }

  private refreshPopup(): void {
    // API 24/25 render inline controls; they have no native popup to remount on return.
    if (!this.immersiveSupported) { this.popupReady = true; return; }
    const generation = ++this.popupGeneration;
    if (!this.nativeToolbarEligible()) {
      this.popupReady = false;
      this.searchPopupVisible = false;
      return;
    }
    if (this.popupReady) return;
    const ui = this.getUIContext();
    afterPaint(ui, () => {
      if (this.disposed || generation !== this.popupGeneration || !this.nativeToolbarEligible()) return;
      // Restoring the destination scroll position can move the anchor on the first paint.
      afterPaint(ui, () => {
        if (this.disposed || generation !== this.popupGeneration || !this.nativeToolbarEligible()) return;
        this.popupReady = true;
      });
    });
  }

  private toolbarInteractive(): boolean {
    return this.active && this.homeVisibility.visible && !this.routeTransitioning &&
      this.channel === 'apps' && !this.channelInMotion;
  }

  private nativeToolbarEligible(): boolean {
    return !this.disposed && this.toolbarInteractive() && this.toolbarWidth() > 0;
  }

  private suspendToolbarPopup(): boolean {
    return !this.toolbarInteractive() || !this.popupReady;
  }

  private searchPopupRequested(): boolean {
    return this.immersiveSupported && this.popupReady && this.nativeToolbarEligible();
  }

  @Builder
  private floatingSearch() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.toolbarRows !== 2 && this.categoriesOpen && !this.isLandscape()) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17)
            .fontColor([StoreMaterial.icon(this.darkMode,this.materialMode)])
        }.width(44).height(44).backgroundColor(Color.Transparent)
          .id('discover-search-button').accessibilityText(I18n.t('搜索应用')).onClick(this.onOpenSearch)
      } else { this.searchContent() }
    }.width('100%').height(44).clip(false)
  }

  @Builder
  private searchField() {
    Stack({ alignContent: Alignment.Start }) {
      Stack() { this.floatingSearch() }.width('100%').height(44).borderRadius(22).clip(true)
        .visibility(this.searchPopupVisible ? Visibility.Hidden : Visibility.Visible)
        .backgroundBlurStyle(StoreMaterial.blurStyle(this.materialMode), {
          colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
        }).backgroundColor(StoreMaterial.fallbackFill(this.darkMode))
      if (this.immersiveSupported) {
        Column() {}.width('100%').height(44).hitTestBehavior(HitTestMode.None)
        .bindPopup(this.searchPopupRequested(), {
          builder: this.floatingSearch, width: this.searchControlWidth(), radius: 22,
          placement: Placement.BottomLeft, targetSpace: 0, offset: { x: 0, y: -44 },
          enableArrow: false, autoCancel: false, focusable: false, mask: false, followTransformOfTarget: true,
          transition: TransitionEffect.IDENTITY,
          onStateChange: (event: PopupStateChangeParam) => {
            this.searchPopupVisible = event.isVisible && this.searchPopupRequested();
          },
          onWillDismiss: (action: DismissPopupAction) => {
            if (action.reason === DismissReason.PRESS_BACK && this.active &&
              this.homeVisibility.visible && !this.routeTransitioning) this.backAction();
          },
          systemMaterial: StoreMaterial.glass(this.materialMode, this.darkMode)
        })
      }
    }.width('100%').height(44)
  }

  @Builder
  private floatingToolbar() {
    Row({ space: 10 }) {
      // Embedded Popup material inherits this one fixed viewport mask. Never resize a pill to its visible slice.
      NavDestination() {
        Scroll(this.categoryScroller) {
          Row({ space: 10 }) {
            DiscoverGlassButton({ slice: this.sliceFor(''), darkMode: this.darkMode,
              active: this.active, suspendPopup: this.suspendToolbarPopup(),
              controlWidth: this.mainCategoryWidth(), label: I18n.t('全部'), morphing: true, morphProgress: this.toolbarProgress,
              symbol: $r('sys.symbol.square_grid_2x2'), selected: this.selectedCategory.length === 0,
              relayHorizontalDrag: this.categoriesOpen,
              dragStart:()=>{this.categoryDragOffset=this.categoryScroller.currentOffset().xOffset;},
              dragUpdate:(offset:number)=>{this.categoryScroller.scrollTo({xOffset:Math.max(0,this.categoryDragOffset-offset),yOffset:0,animation:false});},
              dragEnd:(velocity:number)=>{this.categoryScroller.fling(velocity);},
              controlId: 'discover-category-button', accessibilityLabel: this.categoriesOpen ? I18n.t('全部分类') : I18n.t('展开分类'),
              backAction: this.backAction,
              action: () => { if (this.categoriesOpen) this.onCategory(''); else this.onToggleCategories(); } })
            ForEach(this.categories, (category: string) => { this.categoryPill(category) }, (category: string) => category)
          }.height(DiscoverToolbarMotion.paintHeight)
            .padding({ top: DiscoverToolbarMotion.feedbackInset, bottom: DiscoverToolbarMotion.feedbackInset })
        }.width(this.categoryControlWidth()).height(DiscoverToolbarMotion.paintHeight)
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .onDidScroll(() => {
            this.categoryOffset = this.categoryScroller.currentOffset().xOffset;
            this.refreshCategorySlices();
          })
          .clip(false)
      }.hideTitleBar(true).backgroundColor(Color.Transparent)
        // Leave 14 vp above/below each pill for native lift, press and light feedback.
        // One fixed lateral mask clips overflow; neither the pill nor its material is resized.
        .width(this.categoryControlWidth()).height(DiscoverToolbarMotion.paintHeight)
        .clipShape(new PathShape().commands(DiscoverToolbarViewport.path(
          this.getUIContext().vp2px(this.categoryControlWidth()),
          this.getUIContext().vp2px(DiscoverToolbarMotion.controlHeight),
          this.getUIContext().vp2px(DiscoverToolbarMotion.feedbackInset))))
      DiscoverSortControl({ active: this.active, foreground: this.homeVisibility.visible,
        suspendPopup: this.suspendToolbarPopup(),
        darkMode: this.darkMode, sortKey: this.sortKey, sortDirection: this.sortDirection,
        loading: this.sortLoading, onSort: this.onSort, onReverse: this.onReverseSort,
        layoutMode: this.layoutMode, onLayoutChange: this.onLayoutChange,
        toolbarRows: this.toolbarRows, menuMaxHeight: this.sortMenuMaxHeight(),
        onToolbarRowsChange: this.onToolbarRowsChange, categories: this.categories,
        onSaveCategoryOrder: this.onSaveCategoryOrder, backAction: this.backAction })
    }.width(this.categoryControlWidth() + DiscoverToolbarMotion.secondRowOffset).height(DiscoverToolbarMotion.paintHeight)
      .position({ x: this.toolbarRows === 2 ? 0 : this.searchControlWidth() + 10,
        y: 8 - DiscoverToolbarMotion.feedbackInset +
          (this.toolbarRows === 2 ? DiscoverToolbarMotion.secondRowOffset : 0) })
  }

  private mainCategoryWidth(): number {
    return 44 + 20 * this.toolbarProgress;
  }

  private sliceFor(category: string): DiscoverCategorySlice {
    let slice = this.categorySlices.get(category);
    if (slice === undefined) { slice = new DiscoverCategorySlice(); this.categorySlices.set(category, slice); }
    return slice;
  }
  private onCategoriesChanged(): void {
    this.categorySlices.forEach((_slice: DiscoverCategorySlice, category: string) => {
      if (category !== '' && !this.categories.includes(category)) this.categorySlices.delete(category);
    });
    this.refreshCategorySlices();
  }
  private refreshCategorySlices(): void {
    let left = 0;
    for (const label of [''].concat(this.categories)) {
      const width = label === '' ? this.mainCategoryWidth() : Math.max(64, I18n.category(label).length * 14 + 32);
      this.sliceFor(label).clipTo(left, width, this.categoryOffset, this.categoryControlWidth(),
        Math.max(44, this.toolbarWidth() - 108));
      left += width + 10;
    }
  }

  @Builder
  private categoryPill(category: string) {
    DiscoverGlassButton({ slice: this.sliceFor(category), darkMode: this.darkMode,
      active: this.active, suspendPopup: this.suspendToolbarPopup(),
      controlWidth: Math.max(64, I18n.category(category).length * 14 + 32), label: I18n.category(category), controlOpacity: this.toolbarProgress,
      selected: this.selectedCategory === category,
      relayHorizontalDrag: true,
      dragStart:()=>{this.categoryDragOffset=this.categoryScroller.currentOffset().xOffset;},
      dragUpdate:(offset:number)=>{this.categoryScroller.scrollTo({xOffset:Math.max(0,this.categoryDragOffset-offset),yOffset:0,animation:false});},
      dragEnd:(velocity:number)=>{this.categoryScroller.fling(velocity);},
      controlId: 'discover-category-' + category, backAction: this.backAction,
      action: () => this.onCategory(category) })
  }

  @Builder
  private channelTab(label: string, key: string) {
    Button({ type: ButtonType.Normal }) {
      Text(I18n.t(label)).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.channelTextColor(key === 'apps' ? this.channelProgress : 1 - this.channelProgress))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.height(48).constraintSize({ minWidth: 44 }).padding(0).borderRadius(10).stateEffect(false)
      .backgroundColor(Color.Transparent)
      .id('discover-channel-' + key).accessibilityText(I18n.t(label))
      .accessibilitySelected(this.channel === key)
      .enabled(this.active && this.motion.scrollOffset < DiscoverToolbarMotion.channelHeight)
      .onClick(() => this.onChannel(key))
  }

  @Builder
  private channelBar() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 18 }) {
          Row() { this.channelTab('发现', 'discover') }
            .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
              const width = Number(size.width);
              if (Number.isFinite(width) && width > 0 && width !== this.firstChannelWidth) {
                this.firstChannelWidth = width;
              }
            })
          this.channelTab('全量应用', 'apps')
        }.height(48)
        Row().width(18).height(3).borderRadius(2)
          .backgroundColor(Palette.forMode(this.darkMode || this.starfield).accent)
          .position({ x: 0, y: 43 })
          .translate({ x: (this.firstChannelWidth + 18) * this.channelProgress })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }.height(48)
      if (this.installTargetCount > 1 || this.installTargetName.length > 0) {
        Text(I18n.t('安装到 ') + (this.installTargetCount > 1 ?
          this.installTargetCount + I18n.t(' 台设备') : this.installTargetName))
          .fontSize(11).fontColor(Palette.forMode(this.darkMode || this.starfield).textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .id('discover-heading-subtitle')
      } else { Blank() }
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17)
          .fontColor([StoreMaterial.icon(this.darkMode, this.materialMode)])
      }.width(44).height(44).backgroundColor(Color.Transparent)
        .id('discover-search-shortcut').opacity(1 - this.channelProgress)
        .stateEffect(false)
        .hitTestBehavior(this.channel === 'discover' && !this.channelInMotion ? HitTestMode.Default : HitTestMode.None)
        .accessibilityLevel(this.channel === 'discover' && !this.channelInMotion ? 'auto' : 'no-hide-descendants')
        .accessibilityText(I18n.t('搜索应用')).onClick(() => {
          if (this.active && this.channel === 'discover' && !this.channelInMotion) this.onOpenSearch();
        })
    }.width('calc(100% - ' + (this.inset * 2) + 'vp)')
      .constraintSize({ maxWidth: this.contentWidth() })
      .height(DiscoverToolbarMotion.channelHeight).alignItems(VerticalAlign.Center)
      .translate({ y: -this.motion.scrollOffset })
  }

  /** 标题颜色随跟手进度在次要文字与正文之间插值。 */
  private channelTextColor(emphasis: number): string {
    const mode = Palette.forMode(this.darkMode || this.starfield);
    return this.mixColor(mode.textSecondary, mode.text, Math.min(1, Math.max(0, emphasis)));
  }

  private mixColor(from: string, to: string, ratio: number): string {
    let mixed = '#';
    for (let index = 0; index < 3; index++) {
      const start = parseInt(from.substring(1 + index * 2, 3 + index * 2), 16);
      const end = parseInt(to.substring(1 + index * 2, 3 + index * 2), 16);
      mixed += Math.round(start + (end - start) * ratio).toString(16).padStart(2, '0');
    }
    return mixed;
  }

  build() {
    Column() {
      Column() {
        this.channelBar()
      }.width('100%')
        .height(DiscoverToolbarMotion.channelHeight - this.motion.scrollOffset)
        .clip(true)
        .accessibilityLevel(this.motion.scrollOffset === DiscoverToolbarMotion.channelHeight ? 'no-hide-descendants' : 'auto')
      if (this.toolbarWidth() > 0 && (this.channel === 'apps' || this.channelInMotion)) {
        Column({ space: 0 }) {
          Stack({ alignContent: Alignment.TopStart }) {
            Stack({ alignContent: Alignment.Start }) { this.searchField() }
              .width(this.searchControlWidth()).height(44).position({ x: 0, y: 8 })
            this.floatingToolbar()
          }.width('100%').height(DiscoverToolbarMotion.height(this.toolbarRows))
        }.width(this.toolbarWidth()).opacity(this.channelProgress)
          .hitTestBehavior(this.toolbarInteractive() ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
          .accessibilityLevel(this.toolbarInteractive() ? 'auto' : 'no-hide-descendants')
      }
    }.width('100%').padding({ top: this.statusInset })
      .hitTestBehavior(HitTestMode.Transparent)
  }
}

@Component
export struct DiscoverRefreshIndicator {
  @ObjectLink motion: DiscoverMotion;
  @Prop darkMode: boolean = false;
  @Prop refreshing: boolean = false;
  @Prop statusInset: number = 0;
  @Prop toolbarHeight: number = 70;

  build() {
    Row() {
      LoadingProgress().width(24).height(24).color(Palette.forMode(this.darkMode).accent)
        .accessibilityText(I18n.t('正在刷新应用'))
    }.width('100%').height(24).justifyContent(FlexAlign.Center)
      .position({ x: 0, y: this.statusInset + DiscoverToolbarMotion.channelHeight - this.motion.scrollOffset + this.toolbarHeight + this.motion.pullOffset / 2 - 12 })
      .opacity(this.refreshing ? 1 : Math.min(1, this.motion.pullOffset / 24))
      .visibility(this.refreshing || this.motion.pullOffset > 0 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(HitTestMode.None)
  }
}
