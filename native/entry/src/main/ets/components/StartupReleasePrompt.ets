import { common } from '@kit.AbilityKit';
import { StartupNotice, StartupReleaseNotice } from '../data/StartupReleaseNotice';
import { I18n } from '../data/I18n';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';

@CustomDialog
struct StartupNoticeDialog {
  controller?: CustomDialogController;
  notice: StartupNotice = new StartupNotice();
  onAcknowledge: () => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('windowHeight') private windowHeight: number = 0;
  @StorageProp('statusBarInset') private statusInset: number = 0;
  @StorageProp('navigationBottomInset') private bottomInset: number = 0;
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(I18n.t('使用说明')).fontSize(21).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1)
      }.width('100%')
      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 9 }) {
            Row({ space: 7 }) {
              Image($r('app.media.overseas_globe')).width(16).height(16).fillColor(this.colors().accent)
              Text(I18n.t('出海应用使用提示')).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(this.colors().text)
            }.width('100%')
            Text(I18n.t('标记为「出海」的代理等应用，请在出海环境下使用，并遵守所在地法律法规及相关服务规则。请勿用于违法违规活动。'))
              .fontSize(13).lineHeight(21).fontColor(this.colors().textSecondary).width('100%')
          }.width('100%').padding(15).backgroundColor(this.colors().fill).borderRadius(16)
          Column({ space: 9 }) {
            Text(I18n.t('免责声明')).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.colors().text).width('100%')
            Text(I18n.t('本项目仅供学习与交流使用。应用资源由社区用户自助提交，主要来自开源项目。如涉及侵权，请联系以下邮箱，核实后将及时下架处理。'))
              .fontSize(13).lineHeight(21).fontColor(this.colors().textSecondary).width('100%')
            Text('853068675@qq.com').fontSize(13).fontColor(this.colors().accent)
              .copyOption(CopyOptions.LocalDevice).width('100%')
          }.width('100%')
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: Math.max(80,
        StoreLayout.sheetMaxHeight(this.windowHeight, this.statusInset, this.bottomInset) - 146) })
        .scrollBar(BarState.Auto)
      Button(I18n.t('我已了解'), { type: ButtonType.Normal }).width('100%').height(46)
        .fontSize(15).fontWeight(FontWeight.Medium).borderRadius(StoreLayout.cardActionRadius)
        .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
        .id('startup-release-acknowledge').onClick(this.onAcknowledge)
    }.width('calc(100% - 40vp)').constraintSize({ maxWidth: 440 }).padding(22)
      .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius)
      .id('startup-release-notice')
  }
}

/** Wait for the first settled home screen, behind privacy and operational prompts. */
@Component
export struct StartupReleasePrompt {
  @Prop @Watch('syncActive') active: boolean = false;
  @Prop @Watch('acknowledge') dismissRequest: number = 0;
  @StorageProp('routeTransitioning') @Watch('syncActive') private transitioning: boolean = false;
  @StorageProp('deviceOrbOpened') @Watch('syncActive') private devicePanelOpen: boolean = false;
  onShowing: (showing: boolean) => void = () => {};
  private notice: StartupNotice | undefined;
  private dialog?: CustomDialogController;
  private disposed: boolean = false;
  private checked: boolean = false;
  private showing: boolean = false;
  private generation: number = 0;
  private static readonly IDLE_KEY: string = 'startup-release-notice';

  aboutToAppear(): void { this.disposed = false; this.syncActive(); }
  aboutToDisappear(): void { this.disposed = true; this.syncActive(); }
  private eligible(): boolean { return !this.disposed && this.active && !this.transitioning && !this.devicePanelOpen; }

  private close(): void {
    this.generation++;
    const dialog = this.dialog; this.dialog = undefined;
    if (this.showing) { this.showing = false; this.onShowing(false); }
    dialog?.close();
  }

  private syncActive(): void {
    ForegroundIdle.cancel(StartupReleasePrompt.IDLE_KEY);
    if (!this.eligible()) { this.close(); return; }
    if (this.checked || this.showing) return;
    const generation = ++this.generation;
    ForegroundIdle.defer(StartupReleasePrompt.IDLE_KEY, () => { this.openWhenReady(generation); });
  }

  private async openWhenReady(generation: number): Promise<void> {
    if (!this.eligible() || generation !== this.generation || this.showing || this.checked) return;
    const notice = await StartupReleaseNotice.pending(getContext(this) as common.UIAbilityContext);
    if (!this.eligible() || generation !== this.generation) return;
    if (notice === undefined) { this.checked = true; return; }
    this.notice = notice;
    this.showing = true; this.onShowing(true);
    try {
    this.dialog = new CustomDialogController({
      builder: StartupNoticeDialog({ notice: notice, onAcknowledge: () => this.acknowledge() }),
      alignment: DialogAlignment.Center, autoCancel: false, customStyle: true, isModal: true,
      onWillDismiss: () => this.acknowledge(),
      onDidDisappear: () => {
        if (generation !== this.generation) return;
        this.dialog = undefined;
        if (this.showing) { this.showing = false; this.onShowing(false); }
      }
    });
    this.dialog.open();
    }
    catch (_) { this.checked = true; this.close(); }
  }

  private acknowledge(): void {
    if (!this.showing || this.notice === undefined) return;
    const notice = this.notice;
    this.checked = true;
    this.close();
    StartupReleaseNotice.acknowledge(getContext(this) as common.UIAbilityContext, notice)
      .catch(() => {});
  }

  build() { Stack() {}.width(0).height(0).hitTestBehavior(HitTestMode.None) }
}
