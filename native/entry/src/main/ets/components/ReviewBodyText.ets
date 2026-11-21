import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { I18n } from '../data/I18n';
import { ReviewTextRun, reviewTextRuns } from '../data/ReviewLinks';
import { Palette } from '../theme/Palette';

@Component
export struct ReviewBodyText {
  @Prop @Watch('parseBody') body: string = '';
  @Prop prefix: string = '';
  @Prop bodySize: number = 13;
  @Prop darkMode: boolean = false;
  @Prop linksEnabled: boolean = true;
  @Prop elementId: string = '';
  @State private runs: ReviewTextRun[] = [];

  aboutToAppear(): void { this.parseBody(); }

  private parseBody(): void {
    this.runs = reviewTextRuns(this.body);
  }

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  private async openLink(uri: string): Promise<void> {
    if (!this.linksEnabled) return;
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: uri
      });
    } catch (_) {
      promptAction.showToast({ message: I18n.t('无法打开链接') });
    }
  }

  build() {
    Text() {
      if (this.prefix) {
        Span(this.prefix).fontColor(this.colors().textSecondary)
      }
      ForEach(this.runs, (run: ReviewTextRun) => {
        if (run.uri) {
          Span(run.text).fontColor(this.colors().accent)
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.openLink(run.uri))
        } else {
          Span(run.text)
        }
      }, (run: ReviewTextRun) => String(run.offset) + ':' + run.text)
    }.width('100%').id(this.elementId)
      .fontSize(this.bodySize).lineHeight(19).fontColor(this.colors().textBody)
      .copyOption(CopyOptions.LocalDevice).textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
  }
}
