import { DiscoverCategorySlice } from './DiscoverCategorySlice';
import { DiscoverSortControl } from './DiscoverSortControl';
import { afterPaint } from '../theme/AfterPaint';
import { HomeVisibility } from '../theme/HomeVisibility';
import { AnimatorOptions, AnimatorResult, PathShape, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Palette } from '../theme/Palette';
import { StoreLayout, StoreImmersiveAction } from '../theme/StoreDesign';

/** Search resizing and category reveal share one timing curve. */
export class DiscoverToolbarMotion {
  static readonly controlHeight: number = 44;
  static readonly feedbackInset: number = 14;
  static readonly paintHeight: number = DiscoverToolbarMotion.controlHeight + 2 * DiscoverToolbarMotion.feedbackInset;
  static options(begin: number, end: number): AnimatorOptions {
    return { duration: 560, easing: 'cubic-bezier(0.32, 0.08, 0.2, 1)', begin: begin, end: end,
      delay: 0, fill: 'forwards', direction: 'normal', iterations: 1 };
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

/** 只通知顶部组件；滚动不能触发整页卡片及同步安装状态查询。 */
@Observed
export class DiscoverMotion {
  @Track scrollOffset: number = 0;
  @Track pullOffset: number = 0;
  @Track showTop: boolean = false;
  private startOffset: number = 0;

  reachStart(offset: number): void {
    if (Number.isFinite(offset)) this.startOffset = offset;
    this.scrollOffset = 0;
    this.showTop = false;
  }

  scroll(offset: number, titleHeight: number): number {
    const distance = this.pullOffset > 0 ? 0 : Math.max(0, offset - this.startOffset);
    const next = Math.min(distance, Math.max(0, titleHeight));
    if (next !== this.scrollOffset) this.scrollOffset = next;
    const showTop = distance > 240;
    if (showTop !== this.showTop) this.showTop = showTop;
    return distance;
  }

  pull(offset: number): void {
    const next = Math.max(0, offset);
    if (next !== this.pullOffset) this.pullOffset = next;
    if (next > 0 && this.scrollOffset !== 0) this.scrollOffset = 0;
  }
}

/** Native light material is mounted inside the fixed rounded NavDestination viewport. */
@Component
struct DiscoverGlassButton {
  @StorageProp('routeTransitioning') private routeTransitioning: boolean = false;
  @ObjectLink slice: DiscoverCategorySlice;
  @Prop darkMode: boolean = false;
  @Prop active: boolean = true;
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
  relayHorizontalDrag: boolean = false;
  dragStart: () => void = () => {};
  dragUpdate: (offset: number) => void = () => {};
  dragEnd: (velocity: number) => void = () => {};

  private selectedFill(): string {
    if (!this.selected) return '#00000000';
    const alpha = Math.round(235 * (this.morphing ? this.morphProgress : 1));
    return '#' + alpha.toString(16).padStart(2, '0') + Palette.forMode(this.darkMode).selectionRose.substring(1);
  }

  private contentColor(): string {
    return this.selected && (!this.morphing || this.morphProgress > 0.5) ? '#FFFFFF' :
      Palette.forMode(this.darkMode).text;
  }

  @Builder
  private buttonContents() {
    if (this.morphing) {
      Stack() {
        SymbolGlyph(this.symbol).fontSize(17).fontColor([this.contentColor()])
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
          SymbolGlyph(this.symbol).fontSize(17).fontColor([this.contentColor()])
        }
        Text(this.label).fontSize(14).fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.contentColor()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.justifyContent(FlexAlign.Center)
    }
  }

  @Styles
  private controlLayout() {
    .width(this.controlWidth).height(this.controlHeight).borderRadius(this.controlHeight / 2)
      .padding({ left: 12, right: 12 }).opacity(this.controlOpacity)
      .accessibilitySelected(this.selected && (!this.morphing || this.morphProgress > 0.5))
      .id(this.controlId).accessibilityText(this.accessibilityLabel || this.label)
      .enabled(this.active && !this.routeTransitioning).onClick(() => this.action())
  }

  @Builder
  private actionContents(immersive: boolean) {
    Button({ type: ButtonType.Normal }) { this.buttonContents() }
      .controlLayout().stateEffect(true)
      .backgroundColor(immersive ? Color.Transparent : this.selected ? this.selectedFill() : Color.Transparent)
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : BlurStyle.COMPONENT_THIN,
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .parallelGesture(PanGesture({direction:this.relayHorizontalDrag&&immersive?PanDirection.Horizontal:PanDirection.None})
        .onActionStart(()=>this.dragStart()).onActionUpdate((event:GestureEvent)=>this.dragUpdate(event.offsetX))
        .onActionEnd((event:GestureEvent)=>this.dragEnd(event.velocityX)))
  }

  build() {
    StoreImmersiveAction({ visible: this.active && this.slice.materialVisible, controlHeight: this.controlHeight,
      embedded: true, viewportOffset: this.slice.viewportOffset, popupShadow: false,
      controlRadius: this.controlHeight / 2, followsTarget: true, anchorAtStart: true,
      colored: this.selected, tint: this.selected ? Palette.forMode(this.darkMode).selectionRose :
        Palette.forMode(this.darkMode).surface, tintStrength: this.morphing ? this.morphProgress : 1,
      content: (immersive: boolean) => { this.actionContents(immersive); } })
      .width(this.controlWidth).height(this.controlHeight)
  }

}

@Component
export struct DiscoverHeader {
  @StorageProp('routeTransitioning') @Watch('refreshPopup') private routeTransitioning:boolean=false;
  @ObjectLink motion: DiscoverMotion;
  @ObjectLink @Watch('refreshPopup') homeVisibility: HomeVisibility;
  @Prop darkMode: boolean = false;
  @Prop statusInset: number = 0;
  @Prop inset: number = 20;
  @Prop titleHeight: number = 88;
  @Prop @Watch('refreshPopup') active: boolean = true;
  @Prop @Watch('onCategoriesChanged') categories: string[] = [];
  @Prop selectedCategory: string = '';
  @Prop sortKey: string = 'discover';
  @Prop sortDirection: string = 'desc';
  @Prop sortLoading: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverseSort: () => void = () => {};
  @Prop @Watch('onToolbarModeChanged') categoriesExpanded: boolean = false;
  @State private categoriesOpen: boolean = false;
  @State private toolbarProgress: number = 0;
  @BuilderParam searchContent: () => void;
  onToggleCategories: () => void = () => {};
  onOpenSearch: () => void = () => {};
  onMotionStateChanged: (moving: boolean) => void = () => {};
  onCategory: (category: string) => void = () => {};
  private categoryScroller: Scroller = new Scroller();
  private categoryOffset: number = 0;
  private categoryDragOffset: number = 0;
  private categorySlices: Map<string, DiscoverCategorySlice> = new Map();
  @State private popupReady: boolean = false;
  private popupGeneration: number = 0;
  private toolbarMotionGeneration: number = 0;
  private toolbarAnimator: AnimatorResult | undefined = undefined;
  private disposed: boolean = false;
  @State @Watch('refreshCategorySlices') private searchWidth: number = 0;
  private immersiveSupported: boolean = deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported();
  onTitleSize: (height: number) => void = () => {};


  aboutToAppear(): void {
    this.disposed = false;
    this.categoriesOpen = this.categoriesExpanded;
    this.toolbarProgress = this.categoriesOpen ? 1 : 0;
    if (!this.categoriesOpen) this.categoryOffset = 0;
    this.refreshCategorySlices();
    this.refreshPopup();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.popupGeneration++;
    this.toolbarMotionGeneration++;
    this.toolbarAnimator?.cancel();
    this.toolbarAnimator = undefined;
    this.onMotionStateChanged(false);
  }

  private onToolbarModeChanged(): void {
    if (this.categoriesOpen === this.categoriesExpanded) return;
    const generation = ++this.toolbarMotionGeneration;
    this.toolbarAnimator?.cancel();
    this.categoriesOpen = this.categoriesExpanded;
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
    const fullWidth = Math.max(44, this.searchWidth - 112);
    return fullWidth + (44 - fullWidth) * this.toolbarProgress;
  }

  private categoryControlWidth(): number {
    return 44 + (Math.max(44, this.searchWidth - 112) - 44) * this.toolbarProgress;
  }

  private refreshPopup(): void {
    // API 24/25 render inline controls; they have no native popup to remount on return.
    if (!this.immersiveSupported) { this.popupReady = true; return; }
    const generation = ++this.popupGeneration;
    if (!this.active || !this.homeVisibility.visible || this.routeTransitioning) { this.popupReady = false; return; }
    if (this.popupReady) return;
    afterPaint(this.getUIContext(), () => {
      if (this.disposed || generation !== this.popupGeneration || !this.active || !this.homeVisibility.visible || this.routeTransitioning) return;
      this.popupReady = true;
    });
  }

  @Builder
  private floatingSearch() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.categoriesOpen) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17)
            .fontColor([Palette.forMode(this.darkMode).text])
        }.width(44).height(44).backgroundColor(Color.Transparent)
          .id('discover-search-button').accessibilityText('搜索应用').onClick(this.onOpenSearch)
      } else { this.searchContent() }
    }.width('100%').height(44).clip(false)
  }

  @Builder
  private searchField() {
    if (this.immersiveSupported) {
      Column() {}.width('100%').height(44)
        .bindPopup(this.active && this.popupReady && !this.routeTransitioning && this.searchWidth > 0, {
          builder: this.floatingSearch, width: this.searchControlWidth(), radius: 22,
          placement: Placement.BottomLeft, targetSpace: 0, offset: { x: 0, y: -44 },
          enableArrow: false, autoCancel: false, focusable: false, mask: false, followTransformOfTarget: true,
          transition: TransitionEffect.IDENTITY, onWillDismiss: false,
          systemMaterial: new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN, colorInvert: true, applyShadow: true, interactive: true,
            lightEffect: { color: Palette.forMode(this.darkMode).surface }
          })
        })
    } else {
      Stack() { this.floatingSearch() }.width('100%').height(44).borderRadius(22).clip(true)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, {
          colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
        })
    }
  }

  @Builder
  private floatingToolbar() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Start }) { this.searchField() }
        .width(this.searchControlWidth()).height(44)
      // Embedded Popup material inherits this one fixed viewport mask. Never resize a pill to its visible slice.
      NavDestination() {
        Scroll(this.categoryScroller) {
          Row({ space: 10 }) {
            DiscoverGlassButton({ slice: this.sliceFor(''), darkMode: this.darkMode,
              active: this.active && this.popupReady && this.searchWidth > 0,
              controlWidth: this.mainCategoryWidth(), label: '全部', morphing: true, morphProgress: this.toolbarProgress,
              symbol: $r('sys.symbol.square_grid_2x2'), selected: this.selectedCategory.length === 0,
              relayHorizontalDrag: this.categoriesOpen,
              dragStart:()=>{this.categoryDragOffset=this.categoryScroller.currentOffset().xOffset;},
              dragUpdate:(offset:number)=>{this.categoryScroller.scrollTo({xOffset:Math.max(0,this.categoryDragOffset-offset),yOffset:0,animation:false});},
              dragEnd:(velocity:number)=>{this.categoryScroller.fling(velocity);},
              controlId: 'discover-category-button', accessibilityLabel: this.categoriesOpen ? '全部分类' : '展开分类',
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
      DiscoverSortControl({ active: this.active && this.popupReady, foreground: this.homeVisibility.visible,
        darkMode: this.darkMode, sortKey: this.sortKey, sortDirection: this.sortDirection,
        loading: this.sortLoading, onSort: this.onSort, onReverse: this.onReverseSort })
    }.width('100%').height(DiscoverToolbarMotion.paintHeight)
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
      const width = label === '' ? this.mainCategoryWidth() : Math.max(64, label.length * 14 + 32);
      this.sliceFor(label).clipTo(left, width, this.categoryOffset, this.categoryControlWidth(),
        Math.max(44, this.searchWidth - 112));
      left += width + 10;
    }
  }

  @Builder
  private categoryPill(category: string) {
    DiscoverGlassButton({ slice: this.sliceFor(category), darkMode: this.darkMode,
      active: this.active && this.popupReady && this.searchWidth > 0,
      controlWidth: Math.max(64, category.length * 14 + 32), label: category, controlOpacity: this.toolbarProgress,
      selected: this.selectedCategory === category,
      relayHorizontalDrag: true,
      dragStart:()=>{this.categoryDragOffset=this.categoryScroller.currentOffset().xOffset;},
      dragUpdate:(offset:number)=>{this.categoryScroller.scrollTo({xOffset:Math.max(0,this.categoryDragOffset-offset),yOffset:0,animation:false});},
      dragEnd:(velocity:number)=>{this.categoryScroller.fling(velocity);},
      controlId: 'discover-category-' + category, action: () => this.onCategory(category) })
  }

  build() {
    Column() {
      Column() {
        Column({ space: 5 }) {
          Text('HARMONYOS').fontSize(11).fontWeight(FontWeight.Bold)
            .fontColor(Palette.forMode(this.darkMode).accent).letterSpacing(2)
          Row({ space: 9 }) {
            Text('发现').fontSize(30).fontWeight(FontWeight.Bold)
              .fontColor(Palette.forMode(this.darkMode).text)
            Text('值得安装的应用').fontSize(12)
              .fontColor(Palette.forMode(this.darkMode).textSecondary).padding({ bottom: 5 })
          }.alignItems(VerticalAlign.Bottom)
        }.alignItems(HorizontalAlign.Start).width('100%')
          // 外层只裁切视口；标题保留完整高度，避免收起时的尺寸回调缩小自然高度。
          .constraintSize({ maxWidth: StoreLayout.contentWidth, minHeight: this.titleHeight })
          .padding({ top: 20, bottom: 14 })
          .translate({ y: -this.motion.scrollOffset })
          .onSizeChange((_old: SizeOptions, size: SizeOptions) => this.onTitleSize(Number(size.height)))
      }.width('100%').height(Math.max(0, this.titleHeight - this.motion.scrollOffset))
        .padding({ left: this.inset, right: this.inset }).clip(true)
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row() { this.floatingToolbar() }.width('100%').height(DiscoverToolbarMotion.paintHeight)
            .position({ x: 0, y: 8 - DiscoverToolbarMotion.feedbackInset })
        }.width('100%').height(70)
          .onSizeChange((_old: SizeOptions, size: SizeOptions) => { this.searchWidth = Number(size.width); })
      }.width('calc(100% - ' + (this.inset * 2) + 'vp)')
        .constraintSize({ maxWidth: StoreLayout.contentWidth })
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
  @Prop titleHeight: number = 88;

  build() {
    Row() {
      LoadingProgress().width(24).height(24).color(Palette.forMode(this.darkMode).accent)
        .accessibilityText('正在刷新应用')
    }.width('100%').height(24).justifyContent(FlexAlign.Center)
      .position({ x: 0, y: this.statusInset + this.titleHeight + 70 + this.motion.pullOffset / 2 - 12 })
      .opacity(this.refreshing ? 1 : Math.min(1, this.motion.pullOffset / 24))
      .visibility(this.refreshing || this.motion.pullOffset > 0 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(HitTestMode.None)
  }
}
