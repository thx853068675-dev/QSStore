import { UIContext } from '@kit.ArkUI';
import { DiscoveryBlock } from '../data/DiscoveryCollections';
import { afterPaint } from '../theme/AfterPaint';
import { Palette } from '../theme/Palette';

const BANNER_DWELL_MS: number = 6000;
const PAGER_WIDTH: number = 22;

@Component
export struct DiscoverBanner {
  @Prop @Watch('restartCountdown') active: boolean = false;
  @Prop @Watch('syncSlides') blocks: DiscoveryBlock[] = [];
  @Prop cardHeight: number = 162;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('deviceOrbForeground') @Watch('restartCountdown') private foreground: boolean = true;
  @BuilderParam card: (block: DiscoveryBlock) => void;
  label: (key: string) => string = (key: string): string => key;

  @State private selected: number = 0;
  @State private remaining: number = 1;
  private controller: SwiperController = new SwiperController();
  private inView: boolean = false;
  private touching: boolean = false;
  private switching: boolean = false;
  private mounted: boolean = false;
  private slideIndex: number = 0;
  private slideKeys: string = '';
  private revision: number = 0;

  aboutToAppear(): void {
    this.mounted = true;
    this.syncSlides();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.revision++;
  }

  private syncSlides(): void {
    const keys = this.blocks.map((block: DiscoveryBlock) => block.key).join('|');
    if (keys === this.slideKeys) return;
    this.slideKeys = keys;
    this.slideIndex = Math.min(this.slideIndex, Math.max(0, this.blocks.length - 1));
    this.restartCountdown();
  }

  private canCount(): boolean {
    return this.mounted && this.active && this.foreground && this.inView &&
      !this.touching && !this.switching && this.blocks.length > 1;
  }

  private restartCountdown(): void {
    const revision = ++this.revision;
    if (!this.mounted) return;
    const ui = this.getUIContext();
    // Visibility and size callbacks can run during native layout. Do not start
    // an animation transaction until that layout has finished.
    afterPaint(ui, () => {
      if (revision !== this.revision || !this.mounted) return;
      this.selected = this.slideIndex;
      if (!this.switching && this.remaining !== 1) {
        ui.animateTo({ duration: 0 }, () => { this.remaining = 1; });
        if (this.canCount()) afterPaint(ui, () => this.startCountdown(ui, revision));
      } else {
        this.startCountdown(ui, revision);
      }
    });
  }

  private startCountdown(ui: UIContext, revision: number): void {
    if (revision !== this.revision || !this.canCount()) return;
    ui.animateTo({ duration: BANNER_DWELL_MS, curve: Curve.Linear, onFinish: () => {
      if (revision !== this.revision || !this.canCount()) return;
      afterPaint(ui, () => {
        if (revision === this.revision && this.canCount()) this.controller.showNext();
      });
    } }, () => { this.remaining = 0; });
  }

  private updateSize(old: SizeOptions, size: SizeOptions): void {
    if (!this.mounted || (size.width === old.width && size.height === old.height)) return;
    // A resize can interrupt a native swipe before onAnimationEnd is delivered.
    this.touching = false;
    this.switching = false;
    this.restartCountdown();
  }

  private updateVisibility(visible: boolean, ratio: number): void {
    const inView = visible && ratio >= 0.65;
    if (this.inView === inView) return;
    this.inView = inView;
    if (!inView) this.touching = false;
    this.restartCountdown();
  }

  private updateTouch(event: TouchEvent): void {
    const touching = event.type === TouchType.Down;
    if (!touching && event.type !== TouchType.Up && event.type !== TouchType.Cancel) return;
    if (this.touching === touching) return;
    this.touching = touching;
    this.restartCountdown();
  }

  @Builder
  private marker(block: DiscoveryBlock, index: number) {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.Start }) {
        if (index === this.selected) {
          Row().width(PAGER_WIDTH).height(4).backgroundColor(Palette.forMode(this.darkMode).accent)
            .scale({ x: this.remaining, y: 1, centerX: '0%', centerY: '50%' })
        }
      }.width(index === this.selected ? PAGER_WIDTH : 5).height(4).borderRadius(2).clip(true)
        .backgroundColor(Palette.forMode(this.darkMode).border)
    }.width(index === this.selected ? 28 : 13).height(22).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText(this.label(block.key)).accessibilitySelected(index === this.selected)
      .onClick(() => {
        if (this.mounted && index !== this.selected && !this.switching) this.controller.changeIndex(index, true);
      })
  }

  build() {
    Column() {
      Swiper(this.controller) {
        ForEach(this.blocks, (block: DiscoveryBlock) => {
          Column() { this.card(block); }.width('100%').height('100%')
        }, (block: DiscoveryBlock) => block.key)
      }.width('100%').height(this.cardHeight).clip(true).cachedCount(1)
        .loop(this.blocks.length > 1).disableSwipe(this.blocks.length <= 1)
        .duration(320).indicator(false).id('discover-week-banner-carousel')
        .onTouch((event: TouchEvent) => this.updateTouch(event))
        .onSizeChange((old: SizeOptions, size: SizeOptions) => this.updateSize(old, size))
        .onAnimationStart(() => {
          if (!this.mounted) return;
          this.switching = true;
          this.restartCountdown();
        })
        .onAnimationEnd((index: number) => {
          if (!this.mounted) return;
          this.switching = false;
          this.slideIndex = Math.max(0, Math.min(index, this.blocks.length - 1));
          this.restartCountdown();
        })
        .onVisibleAreaChange([0.65], (visible: boolean, ratio: number) => this.updateVisibility(visible, ratio))
      if (this.blocks.length > 1) {
        Row() {
          ForEach(this.blocks, (block: DiscoveryBlock, index: number) => {
            this.marker(block, index)
          }, (block: DiscoveryBlock) => block.key)
        }.height(22).justifyContent(FlexAlign.Center)
      }
    }.width('100%')
  }
}
