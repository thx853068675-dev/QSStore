import { repositoryCount } from '../data/RepositoryCount';

@Component
export struct RepositoryStats {
  @Prop stars: number = 0;
  @Prop downloads: number = -1;
  @Prop color: string = '#737E91';
  @Prop tagBackground: string = '#00000000';
  @Prop compact: boolean = false;

  build() {
    Row({ space: 5 }) {
      Text('★ ' + repositoryCount(this.stars)).fontSize(11).fontWeight(FontWeight.Medium)
        .fontColor(this.color).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
        .padding({ left: this.compact ? 4 : 6, right: this.compact ? 4 : 6, top: 3, bottom: 3 })
        .backgroundColor(this.tagBackground).borderRadius(6)
      if (this.downloads >= 0) {
        Text('↓ ' + repositoryCount(this.downloads)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(this.color).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          .padding({ left: this.compact ? 4 : 6, right: this.compact ? 4 : 6, top: 3, bottom: 3 })
          .backgroundColor(this.tagBackground).borderRadius(6)
      }
    }.alignItems(VerticalAlign.Center).justifyContent(this.compact ? FlexAlign.End : FlexAlign.Start)
      .accessibilityText('GitHub 星星数 ' + this.stars +
        (this.downloads >= 0 ? '，Release 附件累计下载量 ' + this.downloads : ''))
  }
}
