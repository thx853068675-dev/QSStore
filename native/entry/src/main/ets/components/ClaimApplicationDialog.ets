import { common } from '@kit.AbilityKit';
import { AccountSession } from '../data/DeveloperAccount';
import { GitHubAssociationReturn } from '../data/GitHubAssociationReturn';
import { GitHubAssociationStatus } from '../data/DeveloperRegistry';
import { I18n } from '../data/I18n';
import { StoreClient } from '../data/StoreClient';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreLayout, StoreIconButton } from '../theme/StoreDesign';

@CustomDialog
export struct ClaimApplicationDialog {
  controller?: CustomDialogController;
  appId: number = 0;
  appName: string = '';
  darkMode: boolean = false;
  onClaimed: () => void = () => {};
  @StorageProp('githubAssociationRevision') @Watch('associationChanged') private associationRevision: number = 0;
  @StorageProp('githubAssociationPhase') private associationPhase: string = '';
  @StorageProp('githubAssociationFailure') private associationFailure: string = '';
  @State private github: GitHubAssociationStatus = new GitHubAssociationStatus();
  @State private claim: string = '';
  @State private busy: boolean = true;
  @State private signedIn: boolean = false;
  @State private message: string = '';
  private disposed: boolean = false;
  private running: boolean = false;
  private refreshAfterAssociation: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.disposed = true; }

  private associationChanged(): void {
    if (this.running) this.refreshAfterAssociation = true;
    else this.load();
  }

  private async load(action: string = ''): Promise<void> {
    if (this.running || this.disposed) return;
    this.running = true;
    this.busy = true;
    this.message = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountSession.load(context);
      if (this.disposed) return;
      this.signedIn = account !== undefined;
      if (!account || this.appId <= 0) return;
      const client = new StoreClient(context);
      if (action === 'link') {
        await GitHubAssociationReturn.start(context, client, account);
        return;
      }
      const github = await client.githubAssociationStatus(account);
      const claim = await client.repositoryClaim(this.appId, account, action);
      if (!this.disposed) {
        this.github = github;
        this.claim = claim.status;
        if (claim.status === 'mine') {
          this.onClaimed();
          this.controller?.close();
        }
      }
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
    } finally {
      if (!this.disposed) this.busy = false;
      this.running = false;
      if (this.refreshAfterAssociation) {
        this.refreshAfterAssociation = false;
        this.load();
      }
    }
  }

  @Builder
  private caption(value: string) {
    Text(I18n.t(value)).fontSize(13).lineHeight(20).fontColor(this.colors().textSecondary).width('100%')
  }

  @Builder
  private primary(label: string, id: string, action: () => void) {
    Button(I18n.t(label), { type: ButtonType.Capsule }).width('100%').height(44).fontSize(14)
      .fontColor(this.colors().onAccent).backgroundColor(this.colors().accent)
      .id(id).enabled(!this.busy && this.associationPhase !== 'confirming').onClick(action)
  }

  @Builder
  private claimCard() {
    Column({ space: 12 }) {
      if (this.claim === 'mine') {
        Text(I18n.t('已认领')).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().success)
        this.caption('认领的应用可在「我上架的应用」里管理。')
      } else if (this.claim === 'claimed') {
        this.caption('该仓库已有认领开发者')
      } else if (this.claim === 'unsupported') {
        this.caption('当前仅支持认领公开 GitHub 仓库')
      } else if (this.github.login) {
        this.primary('直接认领', 'developer-direct-claim', () => this.load('github'))
      } else if (this.github.enabled) {
        this.primary('关联 GitHub', 'developer-claim-link', () => this.load('link'))
        if (this.associationPhase === 'confirming') {
          this.caption('正在确认 GitHub 关联…')
        } else if (this.associationPhase === 'browser') {
          this.caption('在 GitHub 完成授权后，点浏览器提示中的「打开」返回。')
        } else if (this.associationPhase === 'failed') {
          this.caption(this.associationFailure)
        }
      } else {
        this.caption('GitHub 网页授权尚未配置')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text(this.appName || I18n.t('认领应用')).fontSize(19).fontWeight(FontWeight.Bold)
          .fontColor(this.colors().text).layoutWeight(1).maxLines(2)
        StoreIconButton({ label: I18n.t('关闭'), action: (): void => { this.controller?.close(); } })
      }.width('100%')
      if (this.busy && !this.claim) {
        LoadingProgress().width(26).height(26).color(this.colors().accent).alignSelf(ItemAlign.Center)
      } else if (!this.signedIn) {
        this.caption('请先在「我的」登录华为开发者账号。')
      } else if (this.claim) {
        this.claimCard()
      }
      if (this.message) {
        Text(this.message).fontSize(13).lineHeight(20).fontColor(this.colors().danger).width('100%')
        if (!this.claim) this.primary('重试', 'developer-retry', () => this.load())
      }
    }.width('calc(100% - 44vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
      .padding(20).borderRadius(StoreLayout.dialogRadius).backgroundColor(this.colors().surface)
  }
}
