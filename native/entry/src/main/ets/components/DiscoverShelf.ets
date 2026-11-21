import { LengthMetrics } from '@kit.ArkUI';
import { DiscoveryEntry } from '../data/DiscoveryCollections';
import { I18n } from '../data/I18n';
import { afterPaint } from '../theme/AfterPaint';
import { HomeVisibility } from '../theme/HomeVisibility';
import { Palette } from '../theme/Palette';
import { StoreImmersiveAction, StoreLayout } from '../theme/StoreDesign';
import { StoreMaterial } from '../theme/StoreMaterial';
import { DiscoverShelfPosition as Bounds } from './DiscoverShelfPosition';

/** One tiny embedded destination clips the native glass and its press feedback. */
@Component
struct DiscoverShelfArrow {
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @Prop darkMode: boolean = false;
  @Prop visible: boolean = false;
  @Prop arrowSide: number = 1;
  controlId: string = '';
  action: () => void = () => {};
  backAction: () => void = () => {};
  dragStart: () => void = () => {};
  dragUpdate: (offset: number) => void = () => {};
  dragEnd: (velocity: number) => void = () => {};

  @Builder
  private control(immersive: boolean) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph(this.arrowSide < 0 ? $r('sys.symbol.chevron_left') : $r('sys.symbol.chevron_right'))
        .fontSize(15).fontColor([StoreMaterial.icon(this.darkMode, this.materialMode)]).opacity(0.72)
    }.width(Bounds.arrowWidth).height(Bounds.arrowHeight).padding(0).borderRadius(Bounds.arrowWidth / 2)
      .backgroundColor(immersive ? Color.Transparent : '#99' + Palette.forMode(this.darkMode).surface.substring(1))
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : StoreMaterial.blurStyle(this.materialMode),
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .border({ width: immersive ? 0 : 0.5, color: Palette.forMode(this.darkMode).border, radius: Bounds.arrowWidth / 2 })
      .shadow(immersive ? undefined : { radius: 6, color: this.darkMode ? '#38000000' : '#14203948', offsetX: 0, offsetY: 2 })
      .responseRegion({ x: -9, y: -2, width: Bounds.touchWidth, height: 46 })
      .enabled(this.visible).id(this.controlId)
      .accessibilityText(I18n.t(this.arrowSide < 0 ? '向左浏览' : '向右浏览'))
      .onClick(() => { if (this.visible) this.action(); })
      // An immersive popup has its own hit surface. Relay horizontal drags to
      // the original shelf instead of swallowing them or switching home pages.
      .parallelGesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => this.dragStart())
        .onActionUpdate((event: GestureEvent) => this.dragUpdate(event.offsetX))
        .onActionEnd((event: GestureEvent) => this.dragEnd(event.velocityX)))
  }

  build() {
    NavDestination() {
      Stack() {
        StoreImmersiveAction({ visible: this.visible, colored: false, contentDrawsFallback: true,
          controlWidth: Bounds.arrowWidth, controlHeight: Bounds.arrowHeight, controlRadius: Bounds.arrowWidth / 2,
          embedded: true, followsTarget: true, anchorAtStart: true, popupShadow: false,
          backAction: this.backAction, content: (immersive: boolean): void => this.control(immersive) })
          .width(Bounds.arrowWidth).height(Bounds.arrowHeight)
      }.width(Bounds.touchWidth).height(Bounds.touchHeight).hitTestBehavior(HitTestMode.Transparent)
    }.hideTitleBar(true).backgroundColor(Color.Transparent)
      .width(Bounds.touchWidth).height(Bounds.touchHeight).clip(true)
      .hitTestBehavior(HitTestMode.Transparent)
      .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
      .accessibilityLevel(this.visible ? 'auto' : 'no-hide-descendants')
  }
}

/** The shelf owns its scroll state; an edge crossing never rebuilds Index. */
@Component
export struct DiscoverShelf {
  @ObjectLink @Watch('onActivityChanged') homeVisibility: HomeVisibility;
  @StorageProp('deviceOrbForeground') @Watch('onActivityChanged') private foreground: boolean = true;
  @StorageProp('routeTransitioning') @Watch('onActivityChanged') private routeTransitioning: boolean = false;
  @Prop @Watch('queueMetrics') entries: DiscoveryEntry[] = [];
  @Prop @Watch('onActivityChanged') active: boolean = true;
  @Prop darkMode: boolean = false;
  shelfKey: string = '';
  backAction: () => void = () => {};
  @BuilderParam card: (entry: DiscoveryEntry) => void;
  @State private canLeft: boolean = false;
  @State private canRight: boolean = false;
  @State private shelfHeight: number = 0;
  @State private inView: boolean = false;
  @State private viewportWidth: number = 0;
  private measuredWidth: number = 0;
  private contentWidth: number = 0;
  private measuredHeight: number = 0;
  private dragOffset: number = 0;
  private mounted: boolean = false;
  private metricsQueued: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void { this.mounted = true; this.queueMetrics(); }
  aboutToDisappear(): void { this.mounted = false; }

  private onActivityChanged(): void { this.queueMetrics(); }
  private currentOffset(): number {
    try { return this.scroller.currentOffset().xOffset; } catch (_) { return 0; }
  }
  private available(): boolean {
    return this.mounted && this.active && this.homeVisibility.visible && this.foreground &&
      !this.routeTransitioning && this.inView && this.shelfHeight >= Bounds.touchHeight &&
      this.viewportWidth >= Bounds.touchWidth * 2;
  }
  private queueMetrics(): void {
    if (!this.mounted || this.metricsQueued) return;
    this.metricsQueued = true;
    afterPaint(this.getUIContext(), () => {
      this.metricsQueued = false;
      if (!this.mounted) return;
      if (Number.isFinite(this.measuredWidth) && this.measuredWidth >= 0 && this.viewportWidth !== this.measuredWidth) {
        this.viewportWidth = this.measuredWidth;
      }
      if (Number.isFinite(this.measuredHeight) && this.measuredHeight > 0 && this.shelfHeight !== this.measuredHeight) {
        this.shelfHeight = this.measuredHeight;
      }
      const offset = this.currentOffset();
      const left = Bounds.left(offset, this.contentWidth, this.viewportWidth);
      const right = Bounds.right(offset, this.contentWidth, this.viewportWidth);
      if (left !== this.canLeft) this.canLeft = left;
      if (right !== this.canRight) this.canRight = right;
    });
  }
  private onScroll(): void {
    const offset = this.currentOffset();
    if (Bounds.left(offset, this.contentWidth, this.viewportWidth) !== this.canLeft ||
      Bounds.right(offset, this.contentWidth, this.viewportWidth) !== this.canRight) this.queueMetrics();
  }
  private move(direction: number): void {
    if (!this.available()) return;
    this.scroller.scrollTo({ xOffset: Bounds.next(this.currentOffset(), direction, this.contentWidth, this.viewportWidth),
      yOffset: 0, animation: { duration: 280, curve: Curve.EaseOut } });
  }
  private drag(offset: number): void {
    if (!this.available()) return;
    this.scroller.scrollTo({ xOffset: Bounds.offset(this.dragOffset - offset, this.contentWidth, this.viewportWidth),
      yOffset: 0, animation: false });
  }

  @Builder
  private arrow(direction: number) {
    DiscoverShelfArrow({ darkMode: this.darkMode,
      visible: this.available() && (direction < 0 ? this.canLeft : this.canRight), arrowSide: direction,
      controlId: 'discover-shelf-' + this.shelfKey + (direction < 0 ? '-previous' : '-next'),
      action: () => this.move(direction), backAction: this.backAction,
      dragStart: () => { this.dragOffset = this.currentOffset(); },
      dragUpdate: (offset: number) => this.drag(offset),
      dragEnd: (velocity: number) => { if (this.available()) this.scroller.fling(velocity); } })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll(this.scroller) {
        Row({ space: 10 }) {
          ForEach(this.entries, (entry: DiscoveryEntry) => { this.card(entry) },
            (entry: DiscoveryEntry) => this.shelfKey + '-' + entry.app.id)
        }.padding({ right: 2 }).onSizeChange((_old: SizeOptions, size: SizeOptions) => {
          this.contentWidth = Number(size.width); this.queueMetrics();
        })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .fadingEdge(this.canLeft || this.canRight, { fadingEdgeLength: LengthMetrics.vp(StoreLayout.horizontalFadeLength) })
        .edgeEffect(EdgeEffect.Spring).width('100%')
        .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
          this.measuredWidth = Number(size.width); this.measuredHeight = Number(size.height); this.queueMetrics();
        })
        .onDidScroll(() => this.onScroll())
      Row() { this.arrow(-1) }.width(Bounds.touchWidth).height(Bounds.touchHeight)
        .position({ left: Bounds.anchorInset(), top: Math.max(0, (this.shelfHeight - Bounds.touchHeight) / 2) })
        .hitTestBehavior(HitTestMode.Transparent)
      Row() { this.arrow(1) }.width(Bounds.touchWidth).height(Bounds.touchHeight)
        .position({ right: Bounds.anchorInset(), top: Math.max(0, (this.shelfHeight - Bounds.touchHeight) / 2) })
        .hitTestBehavior(HitTestMode.Transparent)
    }.width('100%').id('discover-shelf-' + this.shelfKey)
      .onVisibleAreaChange([0, 1], (visible: boolean, ratio: number) => {
        const inView = visible && ratio >= 0.99;
        if (this.inView !== inView) this.inView = inView;
      })
  }
}
