import { common } from '@kit.AbilityKit';
import { AccountService } from '../data/AccountService';
import { CertificateSlotRecovery, CertificateSlotRow } from '../jobs/CertificateSlotRecovery';
import { InstallCertificateSlots } from '../jobs/InstallCertificateSlots';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';

@Component
export struct InstallCertificatePrompt {
  @Prop @Watch('syncActive') active: boolean = true;
  @Link showing: boolean;
  @Prop @Watch('dismiss') dismissRequest: number = 0;
  @StorageProp('darkMode') darkMode: boolean = false;
  @State private rows: CertificateSlotRow[] = [];
  @State private loading: boolean = false;
  @State private working: boolean = false;
  @State private confirmId: string = '';
  @State private message: string = '';
  @State private accountLabel: string = '';
  private subscription: number = -1;
  private jobId: string = '';
  private userId: string = '';
  private teamId: string = '';
  private revision: number = 0;
  private disposed: boolean = false;
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void {
    this.subscription = InstallCertificateSlots.subscribe((id: string) => {
      this.revision++;
      this.jobId = id; this.showing = !!id; this.confirmId = ''; this.rows = [];
      this.message = ''; this.working = false;
      if (id) this.load(id, this.revision);
    });
    this.syncActive();
  }
  aboutToDisappear(): void {
    this.disposed = true; this.revision++;
    InstallCertificateSlots.unsubscribe(this.subscription); this.showing = false;
  }
  private syncActive(): void {
    if (this.subscription < 0) return;
    if (this.active) InstallCertificateSlots.activate(this.subscription);
    else InstallCertificateSlots.deactivate(this.subscription);
  }
  private current(id: string, revision: number): boolean {
    return !this.disposed && this.active && this.jobId === id && this.revision === revision &&
      InstallCertificateSlots.isOwner(this.subscription) && InstallCertificateSlots.isRequested(id);
  }
  private async load(id: string, revision: number): Promise<void> {
    this.loading = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const account = await AccountService.current(context);
      if (!account) throw new Error('请先登录华为开发者账号');
      const scope = InstallCertificateSlots.scope(id);
      if (scope && scope !== JSON.stringify([account.userId, account.teamId])) {
        throw new Error('开发者账号已改变，请关闭窗口后重新安装');
      }
      const rows = await CertificateSlotRecovery.list(context, account.userId, account.teamId);
      if (!this.current(id, revision)) return;
      this.userId = account.userId; this.teamId = account.teamId; this.accountLabel = account.label;
      this.rows = rows;
    } catch (error) { if (this.current(id, revision)) this.message = errorText(error); }
    finally { if (this.current(id, revision)) this.loading = false; }
  }
  private close(): void { if (!this.working) InstallCertificateSlots.clear(this.jobId); }
  private dismiss(): void { this.close(); }
  private async proceed(certId: string = ''): Promise<void> {
    if (this.loading || this.working || !this.userId || !this.current(this.jobId, this.revision)) return;
    const id = this.jobId, revision = this.revision;
    this.working = true; this.message = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (certId) await CertificateSlotRecovery.deleteAndResume(context, id, this.userId, this.teamId, certId);
      else await CertificateSlotRecovery.resume(context, id, this.userId, this.teamId);
    } catch (error) { if (this.current(id, revision)) this.message = errorText(error); }
    finally { if (this.current(id, revision)) { this.working = false; this.confirmId = ''; } }
  }
  private expiry(row: CertificateSlotRow): string {
    if (!row.expiresAt) return '到期时间未返回';
    const date = new Date(row.expiresAt * 1000);
    return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' +
      String(date.getDate()).padStart(2, '0') + (row.expiresAt * 1000 <= Date.now() ? ' · 已到期' : '');
  }
  build() {
    if (this.showing) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.close())
        Column({ space: 14 }) {
          Row({ space: 12 }) {
            Text('释放证书名额').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
            StoreIconButton({ label: '关闭证书窗口', active: !this.working, action: () => this.close() })
          }.width('100%')
          Text('安装包已保留。请选择一张不再使用的调试证书，删除后自动继续安装。')
            .fontSize(12).fontColor(this.colors().textSecondary).width('100%')
          if (this.accountLabel) { Text(this.accountLabel).fontSize(12).fontColor(this.colors().textTertiary).width('100%') }
          if (this.loading) { LoadingProgress().width(28).height(28).color(this.colors().accent) }
          else {
            List({ space: 10 }) {
              ForEach(this.rows, (row: CertificateSlotRow) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Column({ space: 5 }) {
                      Text(row.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().text).maxLines(2)
                      Text(this.expiry(row) + (row.inUse ? ' · 本机在用' : '')).fontSize(11).fontColor(this.colors().textTertiary)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                    Button('删除').height(36).fontSize(12).fontColor(this.colors().danger).backgroundColor(this.colors().dangerSoft)
                      .borderRadius(10).enabled(!this.working).onClick(() => { this.confirmId = row.id; this.message = ''; })
                  }.width('100%').padding(12).backgroundColor(this.colors().fill).borderRadius(15)
                }
              }, (row: CertificateSlotRow) => row.id)
            }.width('100%').height(Math.min(300, this.rows.length * 84)).scrollBar(BarState.Off)
          }
          if (this.confirmId) {
            Text('确定删除「' + (this.rows.find((row: CertificateSlotRow) => row.id === this.confirmId)?.name ?? '') +
              '」？删除不可撤销，关联的 Profile 会失效，可能影响其他工具和应用的签装。')
              .fontSize(12).fontColor(this.colors().danger).width('100%')
            Row({ space: 12 }) {
              Button('返回').layoutWeight(1).height(42).fontColor(this.colors().text).backgroundColor(this.colors().fill)
                .enabled(!this.working).onClick(() => this.confirmId = '')
              Button(this.working ? '删除中…' : '删除并继续').layoutWeight(1).height(42)
                .fontColor(this.colors().onAccent).backgroundColor(this.colors().danger).enabled(!this.working)
                .onClick(() => this.proceed(this.confirmId))
            }.width('100%')
          } else {
            Button('已在其他工具释放名额，继续安装').width('100%').height(42).fontSize(12)
              .fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft).enabled(!this.loading && !this.working && !!this.userId)
              .onClick(() => this.proceed())
          }
          if (this.message) { Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%') }
        }.padding(22).width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth, maxHeight: '85%' })
          .backgroundColor(this.colors().surface).borderRadius(26)
      }.width('100%').height('100%')
    } else { Column().width(0).height(0) }
  }
}
