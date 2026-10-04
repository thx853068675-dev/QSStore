import { fitVersionBadge } from '../data/VersionBadgeLayout';
import { BouncingAppName } from './BouncingAppName';

/** Size the inverse background to the visible version, including its ellipsis. */
@Component
export struct CatalogAppTitle {
  @Prop @Watch('updateBadge') title: string = '';
  @Prop @Watch('updateBadge') titleSize: number = 17;
  @Prop titleLines: number = 1;
  @Prop @Watch('updateBadge') version: string = '';
  @Prop color: string = '#17213A';
  @Prop versionColor: string = '#FFFFFF';
  @Prop versionBackground: string = '#17213A';
  @Prop active: boolean = true;
  @State private badgeText: string = '';
  @State private badgeWidth: number = 0;
  @State private titleWidth: number = 0;
  @State private textWidth: number = 0;
  private rowWidth: number = 0;
  private measuredTitle: string = '';
  private measuredTitleSize: number = -1;

  private updateBadge(): void {
    const context = this.getUIContext();
    const layout = fitVersionBadge(this.version, this.rowWidth * 0.4,
      (text: string): number => context.px2vp(context.getMeasureUtils().measureText({
        textContent: text, fontSize: this.titleSize * 11 / 17, fontWeight: FontWeight.Bold
      })));
    this.badgeText = layout.text;
    this.badgeWidth = layout.width;
    if (this.measuredTitle !== this.title || this.measuredTitleSize !== this.titleSize) {
      this.textWidth = context.px2vp(context.getMeasureUtils().measureText({
        textContent: this.title, fontSize: this.titleSize, fontWeight: FontWeight.Bold
      }));
      this.measuredTitle = this.title;
      this.measuredTitleSize = this.titleSize;
    }
    this.titleWidth = Math.min(this.textWidth,
      Math.max(0, this.rowWidth - (this.badgeWidth > 0 ? this.badgeWidth + 5 : 0)));
  }

  build() {
    Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Center }) {
      if (this.titleLines === 1) {
        BouncingAppName({ title: this.title, fontSize: this.titleSize, color: this.color,
          viewportWidth: this.titleWidth, textWidth: this.textWidth, active: this.active }).flexShrink(1)
      } else {
        Text(this.title).fontSize(this.titleSize).fontWeight(FontWeight.Bold).fontColor(this.color)
          .maxLines(this.titleLines).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      }
      if (this.badgeText.length > 0) {
        Text(this.badgeText).fontSize(this.titleSize * 11 / 17).fontWeight(FontWeight.Bold)
          .fontColor(this.versionColor).backgroundColor(this.versionBackground)
          .padding({ left: 4, right: 4 }).lineHeight(this.titleSize * 12 / 17)
          .height(this.titleSize * 12 / 17).borderRadius(2).clip(true)
          .maxLines(1).width(this.badgeWidth).flexShrink(0).margin({ left: 5 })
          .textAlign(TextAlign.Center)
          // 对齐名称的字面中心，补偿紧凑字体行盒的视觉偏差。
          .translate({ y: this.titleSize / 17 })
          .accessibilityText('版本 ' + this.version)
      }
    }.width('100%').onSizeChange((_old: SizeOptions, size: SizeOptions) => {
      const width = Number(size.width);
      if (Number.isFinite(width) && width > 0 && Math.abs(width - this.rowWidth) > 0.1) {
        this.rowWidth = width;
        this.updateBadge();
      }
    })
  }
}
