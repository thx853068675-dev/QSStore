import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AccountService } from '../data/AccountService';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { InstallTaskSnapshot, InstallTaskState } from '../jobs/InstallTaskState';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { JobStore } from '../jobs/JobStore';
import { LocalImport } from '../jobs/LocalImport';
import { StoreRenewal, RenewalTarget } from '../jobs/StoreRenewal';
import { LocalInstallTimeline, LocalTimelineView, LocalTimelineStep } from '../jobs/LocalInstallTimeline';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { displayVersion } from '../data/DisplayVersion';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';

/** Closing this view never cancels the process-owned renewal job. */
@Component
export struct RenewalDialog {
  @Prop target: InstallJob = new InstallJob();
  @Prop sourceAppId: number = 0;
  @Prop existingJobId: string = '';
  @Prop title: string = '';
  // PixelMap is a native handle. V1 @Prop copies objects and loses its image
  // backing; keep the parent's cached handle intact for the dialog lifetime.
  icon: string | image.PixelMap = '';
  @StorageProp('darkMode') darkMode: boolean = false;
  onClose: () => void = () => {};
  onPreparing: (bundle: string, busy: boolean) => void = () => {};
  onRetry: () => void = () => {};
  @State private tasks: InstallTaskSnapshot[] = [];
  @State private selectedId: string = '';
  @State private choices: InstallJob[] = [];
  @State private preview: InstallJob = new InstallJob();
  @State private busy: boolean = false;
  @State private message: string = '';
  @State private timeline: LocalTimelineView = new LocalTimelineView();
  private subscription: number = -1;
  private disposed: boolean = false;
  private committing: boolean = false;
  private startTimer: number = -1;
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void {
    this.selectedId = this.existingJobId;
    this.subscription = InstallTaskState.subscribe((rows: InstallTaskSnapshot[]) => {
      this.tasks = rows;
      this.timeline = LocalInstallTimeline.present(rows, this.selectedId, Date.now());
    });
    if (this.selectedId) return;
    this.startTimer = setTimeout(() => {
      if (!this.disposed) { if (this.sourceAppId > 0) this.prepareStore(); else this.pick(); }
    }, 80);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    clearTimeout(this.startTimer);
    InstallTaskState.unsubscribe(this.subscription);
    if (!this.committing) this.discard();
  }

  private discard(context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext): void {
    for (const item of this.choices) LocalImport.discardPreview(context, item);
    this.choices = [];
  }

  private task(): InstallTaskSnapshot | undefined {
    return this.tasks.find((row: InstallTaskSnapshot) => row.job.id === this.selectedId);
  }

  private async prepareStore(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.message = '';
    const context = getContext(this) as common.UIAbilityContext;
    const target = new RenewalTarget();
    target.appId = this.sourceAppId;
    target.bundleName = this.target.bundleName;
    target.versionCode = this.target.versionCode;
    this.onPreparing(target.bundleName, true);
    try {
      const job = await StoreRenewal.enqueue(context, target, await AccountService.current(context) !== undefined);
      if (!this.disposed) {
        this.selectedId = job.id;
        this.timeline = LocalInstallTimeline.present(this.tasks, job.id, Date.now());
      }
      // Preparation may finish after the dialog closes; execution still belongs to the queue.
      if (job.stage === InstallStage.QUEUED) await InstallCoordinator.recovered(context);
      else if (job.stage !== InstallStage.WAITING_ACCOUNT) await InstallCoordinator.run(context, job.id);
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
      else promptAction.showToast({ message: errorText(error) });
    } finally {
      this.onPreparing(target.bundleName, false);
      if (!this.disposed) this.busy = false;
    }
  }

  private async pick(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.message = '';
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const files = await LocalImport.pickPreviews(context);
      if (this.disposed) { for (const file of files) LocalImport.discardPreview(context, file); return; }
      this.discard();
      this.choices = files.filter((file: InstallJob) => file.bundleName === this.target.bundleName &&
        file.versionCode === this.target.versionCode);
      for (const file of files) if (!this.choices.includes(file)) LocalImport.discardPreview(context, file);
      this.preview = this.choices[0] ?? new InstallJob();
      if (!this.preview.id) throw new Error('请选择相同包名、相同版本的 HAP 或 APP');
    } catch (error) {
      if (!this.disposed && !String(error).includes('未选择安装文件')) this.message = errorText(error);
    } finally { if (!this.disposed) this.busy = false; }
  }

  private async submitFile(): Promise<void> {
    if (this.busy || !this.preview.id) return;
    this.busy = true;
    this.message = '';
    this.committing = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const store = await JobStore.open(context);
      const job = await LocalImport.commitPreview(context, store, this.preview, true);
      // A local renewal intent is separate from a previous successful install record.
      this.selectedId = job.id;
      this.discard(context);
      job.stage = InstallStage.QUEUED;
      await store.save(job);
      if (await AccountService.current(context) === undefined) {
        job.stage = InstallStage.WAITING_ACCOUNT;
        job.lastError = '请先登录开发者账号';
        await store.save(job);
      } else await InstallCoordinator.recovered(context);
    } catch (error) { if (!this.disposed) this.message = errorText(error); }
    finally {
      this.committing = false;
      if (this.disposed) this.discard(context);
      else this.busy = false;
    }
  }

  private resume(): void {
    InstallCoordinator.run(getContext(this) as common.UIAbilityContext, this.selectedId)
      .catch((error: Error) => { if (!this.disposed) this.message = errorText(error); });
  }

  private fileLabel(): string {
    if (!this.preview.id) return '选择同版本安装包';
    try { return this.preview.assetName + ' · ' + (fileIo.statSync(this.preview.cachePath).size / 1048576).toFixed(1) + ' MB'; }
    catch (_) { return this.preview.assetName; }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Row() {
            Text('应用续签').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
            StoreIconButton({ label: '关闭续签进度', action: this.onClose })
          }.width('100%')
          Row({ space: 12 }) {
            if (this.icon) { Image(this.icon).width(46).height(46).borderRadius(13) }
            Column({ space: 5 }) {
              Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
              Text(displayVersion(this.target.versionName || String(this.target.versionCode), this.title)).fontSize(12).fontColor(this.colors().textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          if (this.selectedId) {
            Row({ space: 10 }) {
              if (this.task()?.running) { LoadingProgress().width(20).height(20).color(this.colors().accent) }
              Text(this.task()?.job.stage === InstallStage.INSTALLED ? '续签完成' : this.timeline.status)
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors().accent)
            }.width('100%')
            ForEach(this.timeline.steps.slice(-4), (step: LocalTimelineStep) => {
              Row({ space: 10 }) {
                Text(step.indicator === 'done' ? '✓' : '·').fontColor(this.colors().accent)
                Text(step.label).fontSize(12).fontColor(this.colors().textSecondary).layoutWeight(1)
              }.width('100%')
            }, (step: LocalTimelineStep) => step.key)
            if (this.timeline.message) {
              Text(this.timeline.message).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
            }
            if (!this.task()?.running && this.task()?.job.stage !== InstallStage.INSTALLED) {
              Button(this.task()?.job.stage === InstallStage.TERMINAL_ERROR ? '重新续签' : '继续续签')
                .width('100%').height(42).fontColor(this.colors().onAccent).backgroundColor(this.colors().accent)
                .onClick(() => { if (this.task()?.job.stage === InstallStage.TERMINAL_ERROR) this.onRetry(); else this.resume(); })
            }
          } else if (this.sourceAppId > 0) {
            Row({ space: 10 }) {
              if (this.busy) { LoadingProgress().width(20).height(20).color(this.colors().accent) }
              Text(this.busy ? '正在查找同版本原包…' : '暂未提交续签任务').fontSize(13).fontColor(this.colors().textSecondary)
            }.width('100%')
            if (!this.busy) { Button('重试').onClick(() => this.prepareStore()) }
          } else {
            Text(this.fileLabel()).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
            if (this.choices.length > 1) {
              ForEach(this.choices, (file: InstallJob) => {
                Text((this.preview.id === file.id ? '✓ ' : '') + file.assetName)
                  .fontSize(12).fontColor(this.colors().accent).width('100%').padding(8)
                  .onClick(() => { this.preview = file; })
              }, (file: InstallJob) => file.id)
            }
            Row({ space: 10 }) {
              Button('选择安装包').layoutWeight(1).height(42).enabled(!this.busy).onClick(() => this.pick())
              Button('开始续签').layoutWeight(1).height(42).enabled(!this.busy && !!this.preview.id)
                .fontColor(this.colors().onAccent).backgroundColor(this.colors().accent).onClick(() => this.submitFile())
            }.width('100%')
          }
          if (this.message) { Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%') }
          Text('关闭后任务会继续，可点击卡片的“续签中”查看进度。')
            .fontSize(11).fontColor(this.colors().textTertiary).width('100%')
        }.padding(24).width('100%').backgroundColor(this.colors().surface).borderRadius(26)
      }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth, maxHeight: '80%' })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.colors().scrim)
  }
}
