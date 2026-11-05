import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { RepositoryReadme, StoreClient } from '../data/StoreClient';
import { ReadmeDocument } from '../data/ReadmeDocument';
import { errorText } from '../jobs/ErrorText';
import { I18n } from '../data/I18n';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';

@Component
export struct RepositoryReadmeCard {
  @Prop appId: number = 0;
  @Prop @Watch('updateDocument') darkSurface: boolean = false;
  @StorageProp('darkMode') @Watch('updateDocument') private darkMode: boolean = false;
  @State private expanded: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private document: RepositoryReadme = new RepositoryReadme();
  private controller: webview.WebviewController = new webview.WebviewController();
  private attached: boolean = false;
  private disposed: boolean = false;
  private fetched: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode || this.darkSurface); }
  aboutToDisappear(): void { this.disposed = true; this.attached = false; }

  private updateDocument(): void {
    if (!this.attached || this.disposed || !this.expanded || !this.document.found) return;
    this.controller.loadData(ReadmeDocument.build(this.document.html, this.darkMode || this.darkSurface),
      'text/html', 'UTF-8', 'https://qingqi.invalid/readme');
  }

  private async load(force: boolean = false): Promise<void> {
    if (this.busy || this.disposed || (this.fetched && !force)) return;
    this.busy = true; this.error = '';
    try {
      const value = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .repositoryReadme(this.appId, force);
      if (this.disposed) return;
      this.document = value; this.fetched = true;
    } catch (error) {
      if (!this.disposed) this.error = errorText(error);
    } finally { if (!this.disposed) this.busy = false; }
  }

  private toggle(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => {
      this.expanded = !this.expanded;
    });
    if (this.expanded) this.load();
  }

  private async openLink(url: string): Promise<void> {
    if (!/^https?:\/\//i.test(url)) return;
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: url });
    } catch (_) { promptAction.showToast({ message: I18n.t('无法打开链接') }); }
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text('README').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([this.colors().textSecondary])
          .rotate({ angle: this.expanded ? 90 : 0 }).id('repository-readme-chevron')
      }.width('100%').height(48).padding({ left: 14, right: 14 })
        .id('repository-readme-toggle').accessibilityText('README，' + I18n.t(this.expanded ? '收起' : '展开'))
        .onClick(() => this.toggle())
      if (this.expanded) {
        Column() {
          if (this.busy) {
            Row() { LoadingProgress().width(18).height(18).color(this.colors().textSecondary) }
              .width('100%').height(44).justifyContent(FlexAlign.Center)
          } else if (this.error.length > 0) {
            Text(I18n.t('暂时无法读取，点击重试')).fontSize(13).fontColor(this.colors().accent)
              .width('100%').padding({ top: 10, bottom: 16 }).onClick(() => this.load(true))
              .accessibilityText(this.error + I18n.t('，点击重试')).id('repository-readme-retry')
          } else if (!this.document.found) {
            Text(I18n.t('仓库暂无 README')).fontSize(13).fontColor(this.colors().textSecondary)
              .width('100%').padding({ top: 8, bottom: 16 })
          } else {
            Web({ src: '', controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
              .width('100%').layoutMode(WebLayoutMode.FIT_CONTENT).backgroundColor(this.colors().surface)
              .javaScriptAccess(false).fileAccess(false).domStorageAccess(false)
              .overScrollMode(OverScrollMode.NEVER)
              .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.PARENT_FIRST })
              .onControllerAttached(() => { this.attached = true; this.updateDocument(); })
              .onDisAppear(() => { this.attached = false; })
              .onLoadIntercept((event) => {
                if (!event.data.isRequestGesture()) return false;
                const url = event.data.getRequestUrl();
                this.openLink(url);
                return true;
              }).id('repository-readme-document')
          }
        }.width('100%').padding({ left: 14, right: 14, bottom: 14 })
      }
    }.width('100%').backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius).clip(true)
  }
}
