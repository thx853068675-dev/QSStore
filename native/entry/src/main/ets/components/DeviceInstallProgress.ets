import { InstallTaskSnapshot, InstallTaskState } from '../jobs/InstallTaskState';
import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { Palette } from '../theme/Palette';
import { I18n } from '../data/I18n';

/** Stable child IDs keep each device's live phase attached while siblings advance. */
@Component
struct DeviceProgressRow {
  @Prop darkSurface:boolean=false;
  @Prop jobId:string='';
  @Prop initial:InstallTaskSnapshot=new InstallTaskSnapshot();
  @State private row:InstallTaskSnapshot=new InstallTaskSnapshot();
  @StorageProp('darkMode') private dark:boolean=false;
  onAction:(job:InstallJob)=>void=()=>{};
  private subscription:number=-1;
  aboutToAppear():void{
    this.row=this.initial;
    this.subscription=InstallTaskState.subscribe((rows:InstallTaskSnapshot[])=>{
      const current=rows.find((row)=>row.job.id===this.jobId);
      if(current&&current!==this.row)this.row=current;
    });
  }
  aboutToDisappear():void{InstallTaskState.unsubscribe(this.subscription);this.subscription=-1;}
  private colors():Palette{return Palette.forMode(this.dark || this.darkSurface);}
  private name(job:InstallJob):string{try{return job.installTarget?DeviceInstallTarget.parse(job.installTarget).name:I18n.t('本机');}catch(_){return I18n.t('设备');}}
  private done(row:InstallTaskSnapshot):boolean{return row.job.stage===InstallStage.INSTALLED||row.job.stage===InstallStage.SKIPPED;}
  private label(row:InstallTaskSnapshot):string{return (row.job.stage===InstallStage.SKIPPED?InstallTaskState.label(row):InstallTaskState.compactLabel(row))+(row.running&&InstallTaskState.determinate(row)?' '+row.percent+'%':'');}
  build(){
        Column({space:7}){
          Row({space:8}){
            if(this.done(this.row)){SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(13).fontColor([this.colors().success])}
            else if(this.row.running&&!InstallTaskState.determinate(this.row)){LoadingProgress().width(13).height(13).color(this.colors().accent)}
            else{Circle().width(5).height(5).fill(this.row.job.lastError&&this.row.job.stage!==InstallStage.WAITING_CONFIRMATION?this.colors().danger:this.colors().textTertiary).margin({left:4,right:4})}
            Text(this.name(this.row.job)).fontSize(12).fontColor(this.colors().text).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
            Text(this.label(this.row)).fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.done(this.row)?this.colors().success:this.row.job.lastError&&this.row.job.stage!==InstallStage.WAITING_CONFIRMATION?this.colors().danger:this.colors().accent)
              .id('device-progress-'+this.row.job.id).onClick(()=>{if(!this.row.running&&!this.done(this.row))this.onAction(this.row.job);})
          }.width('100%')
          Progress({value:this.row.percent,total:100,type:ProgressType.Linear}).height(3).width('100%')
            .color(this.colors().accent).backgroundColor(this.colors().border)
            .style({strokeWidth:3,enableSmoothEffect:true})
            .opacity(this.row.running&&InstallTaskState.determinate(this.row)?1:0)
            .hitTestBehavior(HitTestMode.None)
        }.width('100%')
  }
}

@Component
export struct DeviceInstallProgress {
  @Prop darkSurface:boolean=false;
  @Prop rows:InstallTaskSnapshot[]=[];
  onAction:(job:InstallJob)=>void=()=>{};
  build(){
    Column({space:12}){
      ForEach(this.rows,(row:InstallTaskSnapshot)=>{
        DeviceProgressRow({jobId:row.job.id,initial:row,darkSurface:this.darkSurface,onAction:this.onAction})
      },(row:InstallTaskSnapshot)=>row.job.id)
    }.width('100%')
  }
}
