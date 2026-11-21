import { common } from '@kit.AbilityKit';
import { LengthMetrics, promptAction } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { AccountSession, DeveloperAccount } from '../data/DeveloperAccount';
import { AppBackground } from '../data/AppBackgroundPreferences';
import { I18n } from '../data/I18n';
import { ReviewReply, reviewMetadata } from '../data/StoreActions';
import { ReviewReplyPage, StoreClient } from '../data/StoreClient';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { ReviewAuthorName } from './ReviewAuthorName';
import { ReviewBodyText } from './ReviewBodyText';

const REPLY_INPUT_ID = 'review-reply-input';

/** All replies share one list, including replies addressed to another participant. */
@Component
export struct ReviewThread {
  @Prop appId: number = 0;
  @Prop reviewId: number = 0;
  @Prop replyCount: number = 0;
  @Prop initialPreview?: ReviewReply[];
  @Prop authorName: string = '';
  @Prop reviewTime: string = '';
  @Prop deviceModel: string = '';
  @Prop ownerScope: string = '';
  @Prop signedIn: boolean = false;
  @Prop @Watch('availabilityChanged') interactive: boolean = true;
  @Prop darkMode: boolean = false;
  @StorageProp('appBackground') private themeState: AppBackground = new AppBackground();
  @Link @Watch('selectionChanged') activeReviewId: number;
  @State private rows: ReviewReply[] = [];
  @State private preview: ReviewReply[] | undefined = undefined;
  @State private page: number = 0;
  @State private lastPage: number = 1;
  @State private total: number = -1;
  @State private targetsSupported: boolean = false;
  @State private loading: boolean = false;
  @State private mutating: boolean = false;
  @State private message: string = '';
  private generation: number = 0;
  private disposed: boolean = false;
  private viewerScope: string = '';
  private composer?: CustomDialogController;
  formatTime: (value: string) => string = (value: string) => value;

  aboutToDisappear(): void {
    this.disposed = true;
    this.generation++;
    this.composer?.close();
  }

  private availabilityChanged(): void {
    if (!this.interactive) this.composer?.close();
  }

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  private expanded(): boolean { return this.activeReviewId === this.reviewId; }
  private count(): number { return this.total >= 0 ? this.total : this.replyCount; }
  private visibleReplies(): ReviewReply[] {
    if (this.expanded() && this.page > 0) return this.rows;
    return this.preview ?? this.initialPreview ?? [];
  }
  private current(generation: number): boolean {
    return !this.disposed && this.expanded() && this.generation === generation;
  }

  private selectionChanged(): void {
    if (this.expanded()) return;
    this.generation++;
    this.rows = [];
    this.page = 0;
    this.lastPage = 1;
    this.loading = false;
    this.mutating = false;
    this.message = '';
  }

  private accountScope(account?: DeveloperAccount): string {
    return account ? JSON.stringify([account.userId, account.teamId]) : '';
  }

  private toggleReplies(): void {
    if (!this.interactive || this.mutating) return;
    if (this.expanded()) {
      this.activeReviewId = 0;
    } else {
      this.activeReviewId = this.reviewId;
      this.load(1);
    }
  }

  private openComposer(replyToId: number, recipient: string): void {
    if (!this.interactive || this.loading || this.mutating || this.composer) return;
    if (!this.signedIn || !this.ownerScope) {
      promptAction.showToast({ message: I18n.t('请在「我的」登录开发者账号后回复') });
      return;
    }
    const scope = this.ownerScope;
    this.composer = new CustomDialogController({
      builder: ReviewReplyComposer({
        recipient: recipient,
        darkMode: this.darkMode,
        sendReply: (body: string): Promise<void> => this.send(body, replyToId, scope)
      }),
      alignment: DialogAlignment.Bottom,
      autoCancel: true,
      customStyle: true,
      isModal: true,
      focusable: true,
      maskColor: this.colors().scrim,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      keyboardAvoidDistance: LengthMetrics.vp(0),
      onDidAppear: () => this.focusComposer(),
      onDidDisappear: () => { this.composer = undefined; }
    });
    this.composer.open();
  }

  private focusComposer(): void {
    if (this.disposed || !this.interactive || !this.composer) return;
    try {
      // The dialog is in the focus tree after its entrance has finished.
      this.getUIContext().getFocusController().requestFocus(REPLY_INPUT_ID);
      inputMethod.getController().showTextInput().catch(() => {});
    } catch (_) { /* Interactive focus remains available if the IME is unavailable. */ }
  }

  private publish(result: ReviewReplyPage, account?: DeveloperAccount): void {
    if (result.preview !== undefined) this.preview = result.preview;
    if (this.expanded()) {
      this.rows = result.items;
      this.page = result.page;
      this.lastPage = result.totalPages;
    }
    this.total = result.total;
    this.targetsSupported = result.targetsSupported;
    this.viewerScope = this.accountScope(account);
  }

  private async load(page: number): Promise<void> {
    if (!this.interactive || this.loading || this.mutating || page < 1) return;
    const generation = this.generation;
    this.loading = true;
    this.message = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountSession.load(context);
      if (!this.current(generation)) return;
      const result = await new StoreClient(context).listReviewReplies(this.appId, this.reviewId, page, account);
      if (!this.current(generation)) return;
      this.publish(result, account);
    } catch (error) {
      if (this.current(generation)) this.message = errorText(error);
    } finally {
      if (this.current(generation)) this.loading = false;
    }
  }

  private async send(body: string, replyToId: number, scope: string): Promise<void> {
    if (!this.interactive || this.loading || this.mutating || this.disposed) return;
    const generation = this.generation;
    this.mutating = true;
    this.message = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountSession.load(context);
      if (this.disposed || this.generation !== generation || !this.interactive) return;
      if (!account || this.accountScope(account) !== scope) {
        throw new Error(I18n.t('账号已变更，请刷新评论后重试'));
      }
      const result = await new StoreClient(context).postReviewReply(this.appId, this.reviewId, body, account, replyToId,
        this.expanded());
      if (this.disposed || this.generation !== generation) return;
      if (result.preview === undefined) this.activeReviewId = this.reviewId;
      this.publish(result, account);
      if (!this.expanded() && this.count() > this.visibleReplies().length) {
        promptAction.showToast({ message: I18n.t('回复已发送') });
      }
    } finally {
      if (!this.disposed && this.generation === generation) this.mutating = false;
    }
  }

  @Builder
  private replyButton(replyId: number, recipient: string) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.ellipsis_message')).fontSize(16).fontColor([this.colors().textSecondary])
    }.width(40).height(36).padding(0).backgroundColor(Color.Transparent)
      .id('review-reply-' + this.reviewId + '-' + replyId)
      .accessibilityText(recipient ? I18n.t('回复 {name}').replace('{name}', recipient) : I18n.t('回复'))
      .enabled(this.interactive && !this.loading && !this.mutating)
      .onClick(() => this.openComposer(replyId, recipient))
  }

  private async remove(reply: ReviewReply): Promise<void> {
    if (!this.interactive || this.loading || this.mutating || !reply.canDelete) return;
    const generation = this.generation;
    const scope = this.viewerScope || this.ownerScope;
    this.mutating = true;
    this.message = '';
    try {
      let confirmed = false;
      try {
        const result = await promptAction.showDialog({ title: I18n.t('删除这条回复？'),
          message: I18n.t('删除后无法恢复。'), buttons: [
            { text: I18n.t('取消'), color: this.colors().text }, { text: I18n.t('删除'), color: this.colors().danger }] });
        confirmed = result.index === 1;
      } catch (_) { /* Dismissal keeps the reply. */ }
      if (!confirmed || this.disposed || this.generation !== generation || !this.interactive) return;
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountSession.load(context);
      if (this.disposed || this.generation !== generation || !this.interactive) return;
      if (!account || !scope || this.accountScope(account) !== scope) {
        throw new Error(I18n.t('账号已变更，请刷新评论后重试'));
      }
      const result = await new StoreClient(context).deleteReviewReply(this.appId, this.reviewId, reply.id, this.page, account);
      if (!this.disposed && this.generation === generation) {
        this.publish(result, account);
        if (result.preview !== undefined && result.total <= result.preview.length && this.expanded()) {
          this.activeReviewId = 0;
        }
      }
    } catch (error) {
      if (!this.disposed && this.generation === generation) promptAction.showToast({ message: errorText(error) });
    } finally {
      if (!this.disposed && this.generation === generation) this.mutating = false;
    }
  }

  @Builder
  private replyRow(reply: ReviewReply) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        if (reply.avatarUrl) {
          Image(reply.avatarUrl).width(22).height(22).borderRadius(11).objectFit(ImageFit.Cover)
        } else {
          Text(reply.displayName.substring(0, 1) || I18n.t('华')).width(22).height(22).borderRadius(11)
            .fontSize(10).fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft)
            .textAlign(TextAlign.Center)
        }
        ReviewAuthorName({ name: reply.displayName, role: reply.isDeveloper ? '作者' : '',
          darkMode: this.darkMode, textSize: 12 })
      }.width('100%')
      ReviewBodyText({ body: reply.body, bodySize: 12, darkMode: this.darkMode,
        elementId: 'review-reply-body-' + reply.id, linksEnabled: this.interactive,
        prefix: reply.replyToId > 0 ?
          I18n.t('回复 {name}：').replace('{name}', () => reply.replyToName || I18n.t('已删除的回复')) : '' })
      Row() {
        Text(reviewMetadata(this.formatTime(reply.updatedAt), reply.deviceModel))
          .fontSize(10).fontColor(this.colors().textTertiary).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.targetsSupported || this.initialPreview !== undefined) {
          this.replyButton(reply.id, reply.displayName)
        }
        if (reply.canDelete && this.signedIn) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.trash')).fontSize(13).fontColor([this.colors().textSecondary])
          }.width(36).height(36).padding(0).backgroundColor(Color.Transparent)
            .enabled(this.interactive && !this.loading && !this.mutating)
            .id('review-reply-delete-' + reply.id).accessibilityText(I18n.t('删除我的回复'))
            .onClick(() => this.remove(reply))
        }
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        Text(reviewMetadata(this.reviewTime, this.deviceModel)).fontSize(10).fontColor(this.colors().textTertiary)
          .textAlign(TextAlign.Start).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.replyButton(0, this.authorName)
      }.width('100%')
      if (this.count() > 0 || this.expanded()) {
        Column({ space: 4 }) {
          if (this.message) {
            Text(this.message).width('100%').fontSize(11).fontColor(this.colors().danger)
            if (!this.loading && !this.mutating) {
              Text(I18n.t('重试')).fontSize(12).fontColor(this.colors().accent).padding(8)
                .onClick(() => this.load(Math.max(1, this.page)))
            }
          }
          ForEach(this.visibleReplies(), (reply: ReviewReply, index: number) => {
            Column({ space: 4 }) {
              if (index > 0) Divider().color(this.colors().border).strokeWidth(0.5)
              this.replyRow(reply)
            }.width('100%')
          },
            (reply: ReviewReply) => String(reply.id) + ':' + reply.displayName + ':' + reply.avatarUrl + ':' +
              reply.canDelete + ':' + reply.isDeveloper + ':' + reply.replyToName + ':' + reply.deviceModel)
          if (this.loading) {
            LoadingProgress().width(18).height(18).color(this.colors().accent)
          } else if (this.page > 0 && this.total === 0) {
            Text(I18n.t('还没有回复')).fontSize(12).fontColor(this.colors().textTertiary)
          }
          if (this.expanded() && this.lastPage > 1) {
            Row() {
              Button(I18n.t('上一页')).height(34).fontSize(11).backgroundColor(Color.Transparent)
                .fontColor(this.colors().accent).enabled(this.interactive && !this.loading && !this.mutating && this.page > 1)
                .onClick(() => this.load(this.page - 1))
              Text(this.page + ' / ' + this.lastPage).layoutWeight(1).textAlign(TextAlign.Center)
                .fontSize(11).fontColor(this.colors().textTertiary)
              Button(I18n.t('下一页')).height(34).fontSize(11).backgroundColor(Color.Transparent)
                .fontColor(this.colors().accent).enabled(this.interactive && !this.loading && !this.mutating && this.page < this.lastPage)
                .onClick(() => this.load(this.page + 1))
            }.width('100%')
          }
          if (this.expanded() || this.count() > this.visibleReplies().length) {
            Button(this.expanded() ? I18n.t('收起回复') :
              I18n.t('展开其余 {count} 条回复').replace('{count}', String(this.count() - this.visibleReplies().length)),
              { type: ButtonType.Normal })
              .height(32).padding({ left: 4, right: 4 }).fontSize(12)
              .fontColor(this.colors().accent).backgroundColor(Color.Transparent)
              .id('review-replies-' + this.reviewId).enabled(this.interactive && !this.mutating)
              .onClick(() => this.toggleReplies())
          }
        }.width('calc(100% - 20vp)').margin({ left: 20 })
          .padding({ left: 9, right: 9, top: 6, bottom: 2 }).borderRadius(12)
          .backgroundColor(Palette.containerPaint(this.colors().fill, this.themeState.containerOpacity))
          .alignItems(HorizontalAlign.Start)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@CustomDialog
struct ReviewReplyComposer {
  controller?: CustomDialogController;
  recipient: string = '';
  darkMode: boolean = false;
  sendReply: (body: string) => Promise<void> = async () => {};
  @State private draft: string = '';
  @State private busy: boolean = false;
  @State private error: string = '';
  private disposed: boolean = false;

  aboutToDisappear(): void { this.disposed = true; }

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  private async submit(): Promise<void> {
    const body = this.draft.trim();
    if (this.busy || !body) return;
    this.busy = true;
    this.error = '';
    try {
      await this.sendReply(body);
      if (!this.disposed) this.controller?.close();
    } catch (error) {
      if (!this.disposed) this.error = errorText(error);
    } finally {
      if (!this.disposed) this.busy = false;
    }
  }

  build() {
    Column({ space: 4 }) {
      if (this.error) {
        Text(this.error).width('100%').fontSize(12).fontColor(this.colors().danger)
      }
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: this.recipient ?
          I18n.t('回复 {name}').replace('{name}', this.recipient) : I18n.t('写下你的回复') })
          .id(REPLY_INPUT_ID).height(44).layoutWeight(1).maxLength(2000).fontSize(14)
          .backgroundColor(this.colors().fill).borderRadius(22)
          .fontColor(this.colors().text).placeholderColor(this.colors().textSecondary)
          .caretColor(this.colors().accent)
          .defaultFocus(true).enableKeyboardOnFocus(true)
          .enterKeyType(EnterKeyType.Send)
          .onChange((value: string) => { this.draft = value; })
          .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => {
            event?.keepEditableState();
            this.submit();
          })
        Button({ type: ButtonType.Circle }) {
          if (this.busy) {
            LoadingProgress().width(18).height(18).color(this.colors().onAccent)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(19).fontColor([this.colors().onAccent])
          }
        }.width(40).height(40).padding(0).backgroundColor(this.colors().accent)
          .opacity(this.busy || this.draft.trim() ? 1 : 0.42)
          .enabled(!this.busy && !!this.draft.trim()).accessibilityText(I18n.t('发送回复'))
          .id('review-reply-send').onClick(() => this.submit())
      }.width('100%').alignItems(VerticalAlign.Center)
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.colors().surface)
  }
}
