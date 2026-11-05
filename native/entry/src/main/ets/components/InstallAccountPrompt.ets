import { common } from '@kit.AbilityKit';
import { AccountSession } from '../data/DeveloperAccount';
import { DevEcoLogin } from '../data/DevEcoLogin';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { InstallAccountRecovery } from '../jobs/InstallAccountRecovery';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { InstallStage } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

@Component
export struct InstallAccountPrompt {
  @Prop @Watch('syncActive') active: boolean = true;
  @Link showing: boolean;
  @Prop @Watch('dismiss') dismissRequest: number = 0;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @State private busy: boolean = false;
  @State private message: string = '';
  private subscription: number = -1;
  private jobId: string = '';
  private displayedJob: string = '';
  private disposed: boolean = false;
  private colors(): Palette { return Palette.forMode(this.darkMode); }
  aboutToAppear(): void {
    this.disposed = false;
    this.subscription = InstallAccountRecovery.subscribe((id: string) => {
      if (id && id !== this.displayedJob) { this.displayedJob = id; this.message = ''; }
      this.jobId = id; this.showing = !!id;
    });
    this.syncActive();
  }
  aboutToDisappear(): void {
    this.disposed = true; InstallAccountRecovery.unsubscribe(this.subscription); this.showing = false;
  }
  private syncActive(): void {
    if (this.subscription < 0) return;
    if (this.active) InstallAccountRecovery.activate(this.subscription);
    else { InstallAccountRecovery.deactivate(this.subscription); this.showing = false; }
  }
  private close(): void { if (!this.busy) InstallAccountRecovery.clear(this.jobId); }
  private dismiss(): void { this.close(); }
  private async login(): Promise<void> {
    if (this.busy || !this.jobId) return;
    const id = this.jobId, scope = InstallAccountRecovery.scope(id);
    this.busy = true; this.message = I18n.t('请在浏览器中完成华为开发者账号登录');
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await DevEcoLogin.login(context);
      PrivacyConsent.assertBusinessAllowed();
      if (scope && scope !== JSON.stringify([account.userId, account.teamId])) {
        throw new Error(I18n.t('请登录原华为开发者账号，再继续此安装任务'));
      }
      if (scope) {
        const current = await AccountSession.load(context);
        if (!current || JSON.stringify([current.userId, current.teamId]) !== scope) {
          throw new Error(I18n.t('当前账号已改变，请从安装队列重新发起'));
        }
      }
      const store = await JobStore.open(context);
      const job = await store.get(id);
      if (!job || job.stage !== InstallStage.WAITING_ACCOUNT) throw new Error(I18n.t('原安装任务已取消或状态已改变'));
      PrivacyConsent.assertBusinessAllowed();
      await AccountSession.save(context, account);
      AppStorage.setOrCreate('accountReauthRequired', false);
      job.stage = InstallStage.QUEUED; job.lastError = '';
      await store.save(job);
      InstallAccountRecovery.clear(id);
      InstallCoordinator.run(context, id).catch(() => {});
    } catch (error) { if (!this.disposed && InstallAccountRecovery.isRequested(id)) this.message = errorText(error); }
    finally { if (!this.disposed) this.busy = false; }
  }
  build() {
    if (this.showing) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.close())
        Column({ space: 16 }) {
          Row() {
            Text(I18n.t('重新登录开发者账号')).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
            StoreIconButton({ label: I18n.t('关闭'), active: !this.busy, action: () => this.close() })
          }.width('100%')
          Text(I18n.t('华为登录状态需要重新核验。安装进度已保留，登录原账号后继续安装。'))
            .fontSize(13).fontColor(this.colors().textSecondary).width('100%')
          if (this.message) { Text(this.message).fontSize(12).fontColor(this.colors().textSecondary).width('100%') }
          Button(this.busy ? I18n.t('等待浏览器授权…') : I18n.t('登录并继续'))
            .width('100%').height(46).fontColor(this.colors().onAccent).backgroundColor(this.colors().accent)
            .enabled(!this.busy).onClick(() => this.login())
        }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth }).padding(22)
          .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius)
      }.width('100%').height('100%').position({ x: 0, y: 0 })
    } else { Column().width(0).height(0) }
  }
}
