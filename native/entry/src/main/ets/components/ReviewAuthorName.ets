import { I18n } from '../data/I18n';
import { Palette } from '../theme/Palette';

@Component
export struct ReviewAuthorName {
  @Prop name: string = '';
  @Prop role: string = '';
  @Prop darkMode: boolean = false;
  @Prop textSize: number = 13;

  build() {
    Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Center }) {
      Text(this.name).fontSize(this.textSize).fontWeight(FontWeight.Medium)
        .fontColor(Palette.forMode(this.darkMode).text).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      if (this.role) {
        Text(I18n.t(this.role)).fontSize(10).fontWeight(FontWeight.Medium)
          .fontColor(Palette.forMode(this.darkMode).accent).maxLines(1).flexShrink(0)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 }).margin({ left: 5 })
          .borderRadius(5).backgroundColor(Palette.forMode(this.darkMode).accentSoft)
      }
    }.layoutWeight(1)
  }
}
