import { I18n } from '../data/I18n';

/** Solid corner with one symmetric arc; the host card supplies its outer radius. */
@Component
export struct OverseasCorner {
  @StorageProp('darkMode') private darkMode: boolean = false;
  @Prop starfield: boolean = false;
  @Prop compact: boolean = false;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($r('app.media.overseas_globe')).width(this.compact ? 7 : 9).height(this.compact ? 7 : 9)
        .fillColor(this.darkMode && !this.starfield ? '#12394F' : '#FFFFFF')
        .position({ x: this.compact ? 5 : 6, y: this.compact ? 5 : 6 })
    }.width(this.compact ? 17 : 21).height(this.compact ? 17 : 21)
      // SVG Path commands use physical coordinates; component dimensions use
      // vp. A native corner radius keeps fill, clipping and icon in one space.
      .backgroundColor(this.darkMode && !this.starfield ? '#ACD5EC' : '#205980')
      .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: this.compact ? 17 : 21 })
      .clip(true)
      .hitTestBehavior(HitTestMode.None).accessibilityText(I18n.t('出海应用'))
  }
}
