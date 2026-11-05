import { DeviceInstallGroup } from '../jobs/DeviceInstallGroup';
import { DeviceInstallProgress } from './DeviceInstallProgress';
import { image } from '@kit.ImageKit';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { InstallTaskSnapshot, InstallTaskState } from '../jobs/InstallTaskState';
import { QueueTaskPresentation, QueueTaskView } from '../jobs/QueueTaskPresentation';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';
import { HomeAppTitle } from './HomeControls';
import { I18n } from '../data/I18n';

/** The LazyForEach key is the job ID; changing a phase updates this mounted view. */
@Component
export struct QueueTaskCard {
  @Prop jobId: string = '';
  @Prop fallback: InstallJob = new InstallJob();
  @Prop active: boolean = true;
  @Prop title: string = '';
  @Prop version: string = '';
  @Prop hasIcon: boolean = false;
  @Prop iconRevision: string = '';
  // Native PixelMap handles must not be copied by V1 @Prop.
  icon: image.PixelMap | undefined = undefined;
  resolveTitle: (job: InstallJob) => string = () => '';
  resolveVersion: (job: InstallJob) => string = () => '';
  resolveIcon: (job: InstallJob) => image.PixelMap | undefined = () => undefined;
  @StorageProp('darkMode') darkMode: boolean = false;
  onGroupAction:(job:InstallJob)=>void=()=>{};
  @State private members:InstallTaskSnapshot[]=[];
  @State private view: QueueTaskView = new QueueTaskView();
  private subscription: number = -1;
  private colors(): Palette { return Palette.forMode(this.darkMode); }
  private targetLabel():string{try{return this.view.job.installTarget?I18n.t('安装到 ')+DeviceInstallTarget.parse(this.view.job.installTarget).name+' · '+DeviceInstallTarget.parse(this.view.job.installTarget).port:'';}catch(_){return I18n.t('目标设备记录无效');}}
  private currentTitle(): string { return this.resolveTitle(this.view.job) || this.title; }
  private currentVersion(): string { return this.resolveVersion(this.view.job) || this.version; }
  private currentIcon(): image.PixelMap | undefined { return this.resolveIcon(this.view.job) ?? this.icon; }

  aboutToAppear(): void {
    console.info('QueueTaskCard mounted: ' + this.jobId);
    this.subscription = InstallTaskState.subscribe((rows: InstallTaskSnapshot[]) => {
      // Removal is reflected by the owner's membership update. Keep the last
      // frame until then instead of flashing back to the original queued seed.
      let group=DeviceInstallGroup.management(rows,this.fallback);
      if(!group.length)group=DeviceInstallGroup.local(rows,this.view.job.id?this.view.job:this.fallback);
      if(!group.length)return;
      const changed=group.length!==this.members.length||group.some((row,index)=>row!==this.members[index]);
      if(changed)this.members=group;
      const primary=group.find((row)=>row.job.stage!==InstallStage.INSTALLED&&row.job.stage!==InstallStage.SKIPPED)??group[0];
      const next = QueueTaskPresentation.present(rows, primary.job.id, this.fallback);
      if (!QueueTaskPresentation.unchanged(this.view, next)) this.view = next;
    });
  }

  aboutToDisappear(): void {
    console.info('QueueTaskCard unmounted: ' + this.jobId);
    InstallTaskState.unsubscribe(this.subscription);
    this.subscription = -1;
  }

  build() {
    Column({space:14}){
    Row({ space: 12 }) {
      if (this.hasIcon || this.currentIcon() !== undefined) {
        Image(this.currentIcon()).width(44).height(44).borderRadius(12)
          .id('queue-icon-' + this.jobId + ':' + this.iconRevision)
      } else {
        Text(this.currentTitle().substring(0, 1)).fontSize(18).fontColor(this.colors().accent)
          .width(44).height(44).textAlign(TextAlign.Center)
          .backgroundColor(this.colors().accentSoft).borderRadius(12)
      }
      Column({ space: 5 }) {
        HomeAppTitle({ title: this.currentTitle(), version: this.currentVersion(),
          color: this.colors().text, versionColor: this.colors().surface,
          versionBackground: this.colors().text, active: this.active })
        // Reserve the same summary area across stages instead of inserting/removing rows.
        Text(this.members.length>1?this.members.length+I18n.t(' 台设备'):this.targetLabel()?(this.targetLabel()+'\n'+this.view.detail):this.view.detail).fontSize(this.view.warning ? 10 : (this.view.error ? 11 : 12))
          .fontColor(this.view.error || this.view.warning ? this.colors().textTertiary : this.colors().textSecondary)
          .maxLines(2).width('100%').height(30).textAlign(TextAlign.Start)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if(this.members.length<=1){Stack({ alignContent: Alignment.Center }) {
        // One Progress node survives download -> signing -> transfer -> system install.
        Progress({ value: this.view.determinate ? this.view.percent : 0, total: 100, type: ProgressType.Ring })
          .width(48).height(48).color(this.colors().accent).backgroundColor(this.colors().border)
          .style({ strokeWidth: 2.5, enableSmoothEffect: true,
            status: this.view.running && !this.view.determinate ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING })
        // Ring style always renders its own 0.000000 percentage text in this
        // SDK; cover the center with the card surface, then draw our label.
        Circle().width(44).height(44).fill(this.colors().surface)
        Text(this.view.label).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(this.colors().accent).maxLines(1)
      }.width(48).height(48)}
      else{Text(this.members.filter((row)=>row.job.stage===InstallStage.INSTALLED||row.job.stage===InstallStage.SKIPPED).length+'/'+this.members.length).fontSize(13).fontColor(this.colors().accent)}
    }.width('100%')
    if(this.members.length>1){DeviceInstallProgress({rows:this.members,onAction:this.onGroupAction})}
    }.width('100%').padding(16).backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
      .id('queue-card-' + this.jobId).accessibilityDescription(I18n.t('左滑查看任务操作'))
  }
}
