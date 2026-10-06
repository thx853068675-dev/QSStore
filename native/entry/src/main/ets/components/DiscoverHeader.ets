import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';

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

@Component
export struct DiscoverHeader {
  @StorageProp('routeTransitioning') private routeTransitioning:boolean=false;
  @ObjectLink motion: DiscoverMotion;
  @Prop darkMode: boolean = false;
  @Prop statusInset: number = 0;
  @Prop inset: number = 20;
  @Prop titleHeight: number = 88;
  @Prop active: boolean = true;
  @State private searchWidth: number = 0;
  onTitleSize: (height: number) => void = () => {};
  @BuilderParam searchContent: () => void;

  @Builder
  private floatingSearch() {
    Stack() { this.searchContent() }.width('100%').height(46)
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
      Stack({ alignContent: Alignment.Top }) {
        if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
          // API 26 renders floating immersive material in Popup, not an ordinary Stack.
          Column() {}
            .width('calc(100% - ' + (this.inset * 2) + 'vp)')
            .constraintSize({ maxWidth: StoreLayout.contentWidth }).height(46).margin({ top: 8 })
            .onSizeChange((_old: SizeOptions, size: SizeOptions) => { this.searchWidth = Number(size.width); })
            .bindPopup(this.active && !this.routeTransitioning && this.searchWidth > 0, {
              builder: this.floatingSearch, width: this.searchWidth, radius: 23,
              placement: Placement.Bottom, targetSpace: 0, offset: { x: 0, y: -46 },
              enableArrow: false, autoCancel: false, focusable: false, mask: false,
              systemMaterial: new uiMaterial.ImmersiveMaterial({
                style: uiMaterial.ImmersiveStyle.THIN, colorInvert: true, applyShadow: true, interactive: true,
                lightEffect: { color: Palette.forMode(this.darkMode).surface }
              })
            })
        } else {
          Stack() { this.searchContent() }
            .width('calc(100% - ' + (this.inset * 2) + 'vp)')
            .constraintSize({ maxWidth: StoreLayout.contentWidth }).height(46).margin({ top: 8 })
            .borderRadius(23).clip(true)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, {
              colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
            })
        }
      }.width('100%').height(70)
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
