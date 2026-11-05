import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { DeveloperAccount, AccountSession } from '../data/DeveloperAccount';
import { StoreClient } from '../data/StoreClient';
import { UpdatePushSync } from '../data/UpdatePushSync';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

class WebPushKeys {
  p256dh: string = '';
  auth: string = '';
}

class WebPushSubscription {
  endpoint: string = '';
  keys: WebPushKeys = new WebPushKeys();
}

@Component
export struct UpdatePushDialog {
  onClose: () => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('windowHeight') private windowHeight: number = 0;
  @State private loading: boolean = true;
  @State private busy: boolean = false;
  @State private configured: boolean = false;
  @State private notificationEnabled: boolean = false;
  @State private nickname: string = '';
  @State private selectedChannel: string = 'meow';
  @State private activeChannel: string = '';
  @State private endpointHost: string = '';
  @State private editingMeow: boolean = false;
  @State private editingWeb: boolean = false;
  @State private vapidKey: string = '';
  @State private webEndpoint: string = '';
  @State private webP256dh: string = '';
  @State private webAuth: string = '';
  @State private code: string = '';
  @State private codeSent: boolean = false;
  @State private watchedCount: number = 0;
  @State private status: string = '';
  private account: DeveloperAccount | undefined = undefined;
  private clientId: string = '';
  private disposed: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void { this.disposed = false; this.load(); }
  aboutToDisappear(): void { this.disposed = true; }

  private async load(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      this.account = await AccountSession.load(context);
      if (!this.account) { this.status = I18n.t('先登录华为开发者账号，再设置更新提醒'); return; }
      this.clientId = await UpdatePushSync.clientId(context);
      const data = await new StoreClient(context).updatePushState(this.account, this.clientId);
      if (this.disposed) return;
      this.applyState(data);
      try {
        const vapid = await new StoreClient(context).webPushPublicKey();
        if (!this.disposed) this.vapidKey = String(vapid['public_key'] ?? '');
      } catch (_) { if (!this.disposed) this.vapidKey = ''; }
      await UpdatePushSync.setConfigured(context, this.account, this.configured);
      if (this.configured) {
        try { await UpdatePushSync.sync(context); await this.refreshState(); }
        catch (_) { this.status = I18n.t('已保留本机配置；网络恢复后会同步已安装应用'); }
      }
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.loading = false; }
  }

  private applyState(data: Record<string, Object>): void {
    this.configured = data['configured'] === true;
    this.activeChannel = String(data['channel'] ?? '');
    this.endpointHost = String(data['endpoint_host'] ?? '');
    if (this.activeChannel.length > 0) this.selectedChannel = this.activeChannel;
    this.notificationEnabled = data['enabled'] === true;
    this.nickname = String(data['nickname'] ?? this.nickname);
    this.watchedCount = Number(data['watched_count'] ?? 0);
  }

  private async refreshState(): Promise<void> {
    if (!this.account) return;
    const data = await new StoreClient(getContext(this) as common.UIAbilityContext)
      .updatePushState(this.account, this.clientId);
    if (!this.disposed) this.applyState(data);
  }

  private async sendCode(): Promise<void> {
    if (this.busy || !this.account) return;
    const name = this.nickname.trim();
    if (name.length === 0) { this.status = I18n.t('输入你的 MeoW 昵称'); return; }
    this.busy = true; this.status = '';
    try {
      await new StoreClient(getContext(this) as common.UIAbilityContext)
        .updatePushChallenge(this.account, this.clientId, name);
      if (!this.disposed) { this.nickname = name; this.codeSent = true; this.status = I18n.t('验证码已发送到 MeoW，10 分钟内有效'); }
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async confirm(): Promise<void> {
    if (this.busy || !this.account) return;
    if (!/^\d{6}$/.test(this.code.trim())) { this.status = I18n.t('输入 6 位验证码'); return; }
    this.busy = true; this.status = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const data = await new StoreClient(context).updatePushConfirm(this.account, this.clientId, this.code.trim());
      if (this.disposed) return;
      this.applyState(data); this.code = ''; this.codeSent = false;
      this.editingMeow = false;
      await UpdatePushSync.setConfigured(context, this.account, true);
      await UpdatePushSync.sync(context, true);
      await this.refreshState();
      if (!this.disposed) this.status = I18n.t('更新提醒已开启，已同步本机安装清单');
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async copyVapidKey(): Promise<void> {
    if (!this.vapidKey) { this.status = I18n.t('暂时无法获取服务器公钥'); return; }
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.vapidKey));
      if (!this.disposed) this.status = I18n.t('发送公钥已复制');
    } catch (_) { if (!this.disposed) this.status = I18n.t('复制失败，请重试'); }
  }

  private async sendWebCode(): Promise<void> {
    if (this.busy || !this.account) return;
    const endpoint = this.webEndpoint.trim();
    const p256dh = this.webP256dh.trim();
    const auth = this.webAuth.trim();
    if (!endpoint || !p256dh || !auth) { this.status = I18n.t('请填完整订阅信息'); return; }
    const values = new WebPushSubscription();
    values.endpoint = endpoint; values.keys.p256dh = p256dh; values.keys.auth = auth;
    const subscription = JSON.stringify(values);
    this.busy = true; this.status = '';
    try {
      await new StoreClient(getContext(this) as common.UIAbilityContext)
        .webPushChallenge(this.account, this.clientId, subscription);
      if (!this.disposed) { this.codeSent = true; this.status = I18n.t('验证码已发往接收端，10 分钟内有效'); }
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async confirmWeb(): Promise<void> {
    if (this.busy || !this.account) return;
    if (!/^\d{6}$/.test(this.code.trim())) { this.status = I18n.t('输入 6 位验证码'); return; }
    this.busy = true; this.status = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const data = await new StoreClient(context).webPushConfirm(this.account, this.clientId, this.code.trim());
      if (this.disposed) return;
      this.applyState(data); this.code = ''; this.codeSent = false;
      this.webEndpoint = ''; this.webP256dh = ''; this.webAuth = ''; this.editingWeb = false;
      await UpdatePushSync.setConfigured(context, this.account, true);
      await UpdatePushSync.sync(context, true);
      await this.refreshState();
      if (!this.disposed) this.status = I18n.t('Web Push 已开启，已同步本机安装清单');
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async setPreference(enabled: boolean): Promise<void> {
    if (this.busy || !this.account) return;
    this.busy = true; this.status = '';
    try {
      const data = await new StoreClient(getContext(this) as common.UIAbilityContext)
        .updatePushPreferences(this.account, this.clientId, enabled);
      if (!this.disposed) { this.applyState(data); this.status = enabled ? I18n.t('设置已保存') : I18n.t('更新提醒已暂停'); }
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async test(): Promise<void> {
    if (this.busy || !this.account) return;
    this.busy = true; this.status = '';
    try {
      await UpdatePushSync.sync(getContext(this) as common.UIAbilityContext);
      await new StoreClient(getContext(this) as common.UIAbilityContext).updatePushTest(this.account, this.clientId);
      if (!this.disposed) this.status = this.activeChannel === 'webpush' ?
        I18n.t('测试通知已发送，请查看接收端') : I18n.t('测试通知已发送，请查看 MeoW');
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  private async remove(): Promise<void> {
    if (this.busy || !this.account) return;
    const result = await promptAction.showDialog({ title: I18n.t('取消更新提醒？'),
      message: this.activeChannel==='meow'?I18n.t('将解除当前账号的 MeoW 绑定，所有设备停止 MeoW 更新提醒。'):I18n.t('将删除此设备的推送配置和商店服务器上的已安装应用清单。'),
      buttons: [{ text: I18n.t('返回'), color: this.colors().textSecondary },
        { text: I18n.t('取消提醒'), color: this.colors().danger }] });
    if (result.index !== 1 || this.disposed) return;
    this.busy = true; this.status = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await new StoreClient(context).updatePushRemove(this.account, this.clientId);
      await UpdatePushSync.setConfigured(context, this.account, false);
      if (!this.disposed) {
        this.configured = false; this.activeChannel = ''; this.endpointHost = '';
        this.editingMeow = false; this.editingWeb = false; this.notificationEnabled = false;
        this.nickname = ''; this.watchedCount = 0;
        this.status = I18n.t('更新提醒已取消');
      }
    } catch (error) { if (!this.disposed) this.status = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }

  @Builder private channelCard() {
    Column({ space: 20 }) {
      Row({ space: 4 }) {
        Button('MeoW').layoutWeight(1).height(44).borderRadius(12)
          .backgroundColor(this.selectedChannel === 'meow' ? this.colors().accent : this.colors().fill)
          .fontColor(this.selectedChannel === 'meow' ? this.colors().onAccent : this.colors().textSecondary)
          .fontWeight(FontWeight.Medium)
          .onClick(() => { this.selectedChannel = 'meow'; this.codeSent = false; this.code = ''; this.status = ''; })
        Button('Web Push').layoutWeight(1).height(44).borderRadius(12)
          .backgroundColor(this.selectedChannel === 'webpush' ? this.colors().accent : this.colors().fill)
          .fontColor(this.selectedChannel === 'webpush' ? this.colors().onAccent : this.colors().textSecondary)
          .fontWeight(FontWeight.Medium)
          .onClick(() => { this.selectedChannel = 'webpush'; this.codeSent = false; this.code = ''; this.status = ''; })
      }.width('100%').padding(4).backgroundColor(this.colors().fill).borderRadius(16)

      if (this.configured && this.activeChannel === this.selectedChannel &&
          !this.editingMeow && !this.editingWeb) {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Column({ space: 5 }) {
              Text(I18n.t('更新提醒'))
                .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
              Text(this.activeChannel === 'meow' ? this.nickname : this.endpointHost)
                .fontSize(13).fontColor(this.colors().textSecondary)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.notificationEnabled })
              .selectedColor(this.colors().accent).enabled(!this.busy)
              .accessibilityText(I18n.t('更新提醒'))
              .onChange((value: boolean) => this.setPreference(value))
          }.width('100%')
          Divider().strokeWidth(0.5).color(this.colors().border)
          Text(this.notificationEnabled ?
            (I18n.t('已订阅 ') + this.watchedCount + I18n.t(' 个应用')) :
            (I18n.t('已暂停，订阅 ') + this.watchedCount + I18n.t(' 个应用')))
            .fontSize(13).fontColor(this.colors().textSecondary).width('100%')
          Button(I18n.t('发送测试通知')).width('100%').height(44).borderRadius(12)
            .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
            .enabled(!this.busy).onClick(() => this.test())
          Row({ space: 10 }) {
            Button(this.activeChannel === 'meow' ? I18n.t('更换昵称') : I18n.t('更换订阅'))
              .layoutWeight(1).height(42).borderRadius(12)
              .backgroundColor(this.colors().fill).fontColor(this.colors().text)
              .enabled(!this.busy).onClick(() => {
                this.editingMeow = this.activeChannel === 'meow';
                this.editingWeb = this.activeChannel === 'webpush';
                this.codeSent = false; this.code = ''; this.status = '';
              })
            Button(I18n.t('取消注册')).layoutWeight(1).height(42).borderRadius(12)
              .backgroundColor(this.colors().fill).fontColor(this.colors().danger)
              .enabled(!this.busy).onClick(() => this.remove())
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else if (this.selectedChannel === 'meow') {
        Column({ space: 12 }) {
          if (this.configured && this.activeChannel !== 'meow') {
            Text(I18n.t('验证后切换到 MeoW')).fontSize(13).fontColor(this.colors().textSecondary).width('100%')
          }
          TextInput({ text: this.nickname, placeholder: I18n.t('MeoW 昵称') })
            .width('100%').height(48).backgroundColor(this.colors().fill)
            .borderRadius(12).padding({ left: 14, right: 14 }).fontColor(this.colors().text)
            .onChange((value: string) => { this.nickname = value; })
          Button(this.codeSent ? I18n.t('重新发送验证码') : I18n.t('发送验证码'))
            .width('100%').height(44).borderRadius(12)
            .backgroundColor(this.codeSent ? this.colors().accentSoft : this.colors().accent)
            .fontColor(this.codeSent ? this.colors().accent : this.colors().onAccent)
            .enabled(!this.busy).onClick(() => this.sendCode())
          if (this.codeSent) {
            TextInput({ text: this.code, placeholder: I18n.t('6 位验证码') })
              .width('100%').height(48).backgroundColor(this.colors().fill)
              .borderRadius(12).padding({ left: 14, right: 14 }).fontColor(this.colors().text)
              .maxLength(6).type(InputType.Number)
              .onChange((value: string) => { this.code = value; })
            Button(I18n.t('验证并开启')).width('100%').height(44).borderRadius(12)
              .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
              .enabled(!this.busy).onClick(() => this.confirm())
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else {
        Column({ space: 12 }) {
          if (this.configured && this.activeChannel !== 'webpush') {
            Text(I18n.t('验证后切换到 Web Push')).fontSize(13)
              .fontColor(this.colors().textSecondary).width('100%')
          }
          Row({ space: 8 }) {
            Text(I18n.t('订阅信息')).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.colors().text).layoutWeight(1)
            Button(I18n.t('复制 VAPID 公钥')).height(36).borderRadius(10)
              .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
              .enabled(this.vapidKey.length > 0).onClick(() => this.copyVapidKey())
          }.width('100%')
          TextInput({ text: this.webEndpoint, placeholder: 'Endpoint · https://…' })
            .width('100%').height(48).fontSize(13).fontColor(this.colors().text)
            .backgroundColor(this.colors().fill).borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => { this.webEndpoint = value; })
          TextInput({ text: this.webP256dh, placeholder: I18n.t('p256dh · 公钥') })
            .width('100%').height(48).fontSize(13).fontColor(this.colors().text)
            .backgroundColor(this.colors().fill).borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => { this.webP256dh = value; })
          TextInput({ text: this.webAuth, placeholder: I18n.t('auth · 密钥') })
            .width('100%').height(48).fontSize(13).fontColor(this.colors().text)
            .backgroundColor(this.colors().fill).borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => { this.webAuth = value; })
          Button(this.codeSent ? I18n.t('重新发送验证通知') : I18n.t('发送验证通知'))
            .width('100%').height(44).borderRadius(12)
            .backgroundColor(this.codeSent ? this.colors().accentSoft : this.colors().accent)
            .fontColor(this.codeSent ? this.colors().accent : this.colors().onAccent)
            .enabled(!this.busy && this.vapidKey.length > 0).onClick(() => this.sendWebCode())
          if (this.codeSent) {
            TextInput({ text: this.code, placeholder: I18n.t('接收端显示的 6 位验证码') })
              .width('100%').height(48).backgroundColor(this.colors().fill)
              .borderRadius(12).padding({ left: 14, right: 14 }).fontColor(this.colors().text)
              .maxLength(6).type(InputType.Number)
              .onChange((value: string) => { this.code = value; })
            Button(I18n.t('验证并开启')).width('100%').height(44).borderRadius(12)
              .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
              .enabled(!this.busy).onClick(() => this.confirmWeb())
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      if ((this.selectedChannel === 'meow' && this.editingMeow) ||
          (this.selectedChannel === 'webpush' && this.editingWeb)) {
        Button(I18n.t('返回当前设置')).width('100%').height(40).borderRadius(12)
          .backgroundColor(this.colors().fill).fontColor(this.colors().textSecondary)
          .onClick(() => {
            this.editingMeow = false; this.editingWeb = false;
            this.codeSent = false; this.code = ''; this.status = '';
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  private panelHeight(): number {
    if (this.loading || !this.account) return this.status ? 142 : 112;
    const active = this.configured && this.activeChannel === this.selectedChannel &&
      !this.editingMeow && !this.editingWeb;
    let height = active ? 360 : this.selectedChannel === 'webpush' ? 476 : 282;
    if (!active && this.codeSent) height += 116;
    if (!active && this.configured && this.activeChannel !== this.selectedChannel) height += 34;
    if (this.editingMeow || this.editingWeb) height += 52;
    if (this.status) height += 34;
    return height;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim)
        .onClick(() => this.onClose())
      Column({ space: 0 }) {
        Row({ space: 12 }) {
          Text(I18n.t('更新提醒')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).layoutWeight(1)
          StoreIconButton({ label: I18n.t('关闭推送设置'), action: () => this.onClose() })
        }.width('100%').padding({ left: 22, right: 16, top: 16, bottom: 8 })
        Scroll() {
          Column({ space: 16 }) {
            if (this.loading) {
              LoadingProgress().width(28).height(28).color(this.colors().accent)
            } else if (this.account) {
              this.channelCard()
            }
            if (this.status.length > 0) {
              Text(this.status).fontSize(13).fontColor(this.colors().textSecondary).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: 20, right: 20, bottom: 20 })
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth })
        .height(Math.min(this.panelHeight(), StoreLayout.sheetMaxHeight(this.windowHeight)))
        .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius).clip(true)
    }.width('100%').height('100%').position({ x: 0, y: 0 })
  }
}
