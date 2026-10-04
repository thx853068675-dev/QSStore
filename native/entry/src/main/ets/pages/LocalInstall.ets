import { router,promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { LocalImport } from '../jobs/LocalImport';
import { PackageArchive } from '../jobs/PackageArchive';
import { JobStore } from '../jobs/JobStore';
import { JobScheduler } from '../jobs/JobScheduler';
import { InstallJob,InstallStage } from '../jobs/InstallJob';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { InstallTaskState,InstallTaskSnapshot } from '../jobs/InstallTaskState';
import { LocalInstallTimeline,LocalTimelineView,LocalTimelineStep } from '../jobs/LocalInstallTimeline';
import { LocalBundles } from '../jobs/LocalBundles';
import { AccountService } from '../data/AccountService';
import { InstalledIconCache } from '../data/InstalledIconCache';
import { InstallPrompts } from '../components/InstallPrompts';
import { InstallCertificatePrompt } from '../components/InstallCertificatePrompt';
import { Palette } from '../theme/Palette';
import { StoreImmersiveIconButton,StoreLayout,StorePageHeader } from '../theme/StoreDesign';
import { errorText } from '../jobs/ErrorText';
import { StoreRenewal, RenewalTarget } from '../jobs/StoreRenewal';

interface LocalInstallParams { preview?:InstallJob; direct?:boolean; renewal?:boolean; renewBundleName?:string; renewVersionCode?:number; renewAppId?:number; renewTitle?:string; }

@Entry
@Component
struct LocalInstall {
  @StorageProp('darkMode') darkMode:boolean=false;
  @StorageProp('statusBarInset') statusBarInset:number=0;
  @State private choices:InstallJob[]=[];
  @State private selected:InstallJob=new InstallJob();
  @State private preview:boolean=false;
  @State private busy:boolean=false;
  @State private title:string='';
  @State private fileSize:string='';
  @State private pixels:image.PixelMap|null=null;
  @State private message:string='';
  @State private tasks:InstallTaskSnapshot[]=[];
  @State private timeline:LocalTimelineView=new LocalTimelineView();
  @State private pageActive:boolean=true;
  @State private headerVisible:boolean=true;
  @State private showReconnect:boolean=false;
  @State private showCertificatePrompt:boolean=false;
  @State private certificatePromptDismiss:number=0;
  @State private promptDismiss:number=0;
  @State private renewal:boolean=false;
  @State private canRenew:boolean=false;
  @State private storeRenewal:boolean=false;
  private renewBundleName:string=''; private renewVersionCode:number=0;
  private remoteJobId:string='';
  private subscription:number=-1; private pickerTimer:number=-1;
  private disposed:boolean=false; private reading:number=0;
  private returning:boolean=false; private backTimer:number=-1;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void{
    this.observeTasks();
    const params=router.getParams() as LocalInstallParams;
    this.renewal=params?.renewal===true;
    this.renewBundleName=params?.renewBundleName??'';
    this.renewVersionCode=params?.renewVersionCode??0;
    this.storeRenewal=this.renewal&&(params?.renewAppId??0)>0;
    this.title=params?.renewTitle??'';
    // Take ownership now, including a back action before the timer fires.
    if(params?.preview){this.choices=[params.preview];this.preview=true;}
    this.pickerTimer=setTimeout(()=>{
      if(this.disposed)return;
      if(this.storeRenewal)this.renewFromStore(params.renewAppId??0);
      else if(params?.preview){this.choose(params.preview);if(params.direct)this.install();}
      else this.pick();
    },80);
  }
  onPageShow():void{this.pageActive=true;if(!this.disposed&&!this.returning)this.headerVisible=true;}
  onPageHide():void{this.pageActive=false;this.headerVisible=false;}
  aboutToDisappear():void{this.disposed=true;this.headerVisible=false;this.pageActive=false;clearTimeout(this.pickerTimer);clearTimeout(this.backTimer);InstallTaskState.unsubscribe(this.subscription);this.discard();this.pixels?.release();this.pixels=null;}
  onBackPress():boolean{if(this.showCertificatePrompt){this.certificatePromptDismiss++;return true;}if(this.showReconnect){this.promptDismiss++;return true;}if(this.busy&&!this.storeRenewal){promptAction.showToast({message:'正在读取文件，请稍候'});return true;}this.back();return true;}
  private back():void{
    if(this.disposed||this.returning)return;
    this.returning=true;this.headerVisible=false;
    this.backTimer=setTimeout(()=>{if(!this.disposed)router.back();},32);
  }
  private async renewFromStore(appId:number):Promise<void>{
    this.busy=true;this.message='';
    const context=getContext(this) as common.UIAbilityContext;
    try{
      const target=new RenewalTarget();target.appId=appId;target.bundleName=this.renewBundleName;target.versionCode=this.renewVersionCode;
      const account=await AccountService.current(context);
      const job=await StoreRenewal.enqueue(context,target,account!==undefined);
      this.remoteJobId=job.id;
      if(!this.disposed){this.selected=job;this.preview=false;this.refreshTimeline();}
      if(job.stage===InstallStage.QUEUED)InstallCoordinator.recovered(context).catch((error:Error)=>{if(!this.disposed)this.message=errorText(error);});
      else if(job.stage!==InstallStage.WAITING_ACCOUNT)InstallCoordinator.run(context,job.id).catch((error:Error)=>{if(!this.disposed)this.message=errorText(error);});
    }catch(error){if(!this.disposed)this.message=errorText(error);}
    finally{if(!this.disposed)this.busy=false;}
  }
  private observeTasks():void{
    this.subscription=InstallTaskState.subscribe((tasks:InstallTaskSnapshot[])=>{
      this.tasks=tasks;this.refreshTimeline();
    });
  }
  private refreshTimeline():void{
    this.timeline=this.preview?new LocalTimelineView():LocalInstallTimeline.present(this.tasks,this.selected.id,Date.now());
  }
  private discard():void{const context=getContext(this) as common.UIAbilityContext;for(const job of this.choices)try{LocalImport.discardPreview(context,job);}catch(_){}this.choices=[];}
  private async pick():Promise<void>{
    if(this.busy||this.disposed)return;
    if(this.renewal&&this.remoteJobId&&JobScheduler.isRunning(this.remoteJobId)){promptAction.showToast({message:'续签正在执行，请完成后再选包，或在管理中取消'});return;}
    this.storeRenewal=false;this.busy=true;this.message='';
    try{const choices=await LocalImport.pickPreviews(getContext(this) as common.UIAbilityContext);if(this.disposed){for(const job of choices)LocalImport.discardPreview(getContext(this) as common.UIAbilityContext,job);return;}this.discard();this.choices=choices;this.preview=true;this.timeline=new LocalTimelineView();await this.choose(choices[0]);}
    catch(error){if(!String(error).includes('未选择安装文件'))this.message=errorText(error);}finally{this.busy=false;}
  }
  private async choose(job:InstallJob):Promise<void>{
    const token=++this.reading;this.selected=job;this.title=job.assetName;this.fileSize='';this.pixels?.release();this.pixels=null;
    this.canRenew=LocalBundles.liveInstalledVersion(job.bundleName)===job.versionCode;
    try{this.fileSize=(fileIo.statSync(job.cachePath).size/1048576).toFixed(1)+' MB';const identity=await PackageArchive.inspect(job.cachePath);if(token!==this.reading||this.disposed)return;this.title=identity.displayName||job.assetName;const bytes=await PackageArchive.icon(job.cachePath);if(!bytes)return;await InstalledIconCache.save(getContext(this) as common.UIAbilityContext,job.bundleName,job.versionCode,bytes);const source=image.createImageSource(bytes);try{const pixels=await source.createPixelMap({desiredSize:{width:144,height:144}});if(token===this.reading&&!this.disposed)this.pixels=pixels;else pixels.release();}finally{source.release();}}catch(_){}
  }
  private async install(renewal:boolean=this.renewal):Promise<void>{
    if(this.busy||!this.preview)return;
    if(JobScheduler.isRunning(this.selected.id)){
      this.selected=this.task()?.job||this.selected;this.discard();this.preview=false;this.refreshTimeline();return;
    }
    this.busy=true;this.message='';
    try{
      if(renewal&&this.renewBundleName&&(this.selected.bundleName!==this.renewBundleName||this.selected.versionCode!==this.renewVersionCode))throw new Error('请选择待续签应用相同包名、相同版本的安装包');
      const context=getContext(this) as common.UIAbilityContext,store=await JobStore.open(context);
      if(renewal&&this.remoteJobId){
        const previous=await store.get(this.remoteJobId);
        if(previous?.stage===InstallStage.INSTALLED){this.discard();this.preview=false;this.selected=previous;this.refreshTimeline();return;}
        if(previous){
          if(JobScheduler.isRunning(previous.id))throw new Error('商店续签仍在执行，请完成或取消后再选择原包');
          await JobScheduler.cancel(context,store,previous);
        }
        this.remoteJobId='';
      }
      const job=await LocalImport.commitPreview(context,store,this.selected,renewal);
      this.renewal=renewal;
      this.discard();this.preview=false;this.selected=job;job.stage=InstallStage.QUEUED;await store.save(job);
      if(!await AccountService.current(context)&&!LocalBundles.isSelfBundle(job.bundleName)){
        job.stage=InstallStage.WAITING_ACCOUNT;job.lastError='请先登录开发者账号';await store.save(job);
      }else{
        InstallCoordinator.recovered(context).catch((error:Error)=>{if(!this.disposed)this.message=errorText(error);});
      }
      this.refreshTimeline();
    }
    catch(error){this.message=errorText(error);}finally{this.busy=false;}
  }
  private resume(id:string):void{InstallCoordinator.run(getContext(this) as common.UIAbilityContext,id).catch((error:Error)=>{if(!this.disposed&&!String(error).includes('安装任务已取消'))this.message=errorText(error);});}
  private retry():void{
    if(this.task()?.job.stage===InstallStage.TERMINAL_ERROR)this.pick();
    else this.resume(this.selected.id);
  }
  private task():InstallTaskSnapshot|undefined{return this.tasks.find((row:InstallTaskSnapshot)=>row.job.id===this.selected.id);}
  private renewalExpiry():string{
    const job=this.task()?.job;if(!job||job.stage!==InstallStage.INSTALLED||!(job.renewalExpiresAt>0))return '';
    const date=new Date(job.renewalExpiresAt*1000),pad=(value:number):string=>String(value).padStart(2,'0');
    return date.getFullYear()+'-'+pad(date.getMonth()+1)+'-'+pad(date.getDate())+' '+pad(date.getHours())+':'+pad(date.getMinutes());
  }
  @Builder private headerTools(){
    StoreImmersiveIconButton({symbol:$r('sys.symbol.plus'),label:'选择其他文件',
      controlId:'local-install-add',loading:this.busy,visible:this.headerVisible&&!this.showReconnect && !this.showCertificatePrompt,
      action:()=>this.pick(),backAction:()=>{this.onBackPress();}})
  }
  @Builder private timelineCard(){
    Column({space:14}){
      Row(){Text(this.renewal?'续签流程':'安装流程').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1);Text(this.renewal&&this.task()?.job.stage===InstallStage.INSTALLED?'续签完成':this.timeline.status).fontSize(12).fontColor(this.timeline.tone==='success'?this.colors().success:this.colors().accent).maxLines(2);}.width('100%')
      if(this.renewalExpiry()){Text('新授权有效至 '+this.renewalExpiry()).fontSize(12).fontColor(this.colors().success).width('100%');}
      ForEach(this.timeline.steps,(step:LocalTimelineStep)=>{Row({space:12}){if(step.indicator==='running'){LoadingProgress().width(18).height(18).color(this.colors().accent);}else{Text(step.indicator==='done'?'✓':'!').fontSize(12).fontColor(step.indicator==='done'?this.colors().success:this.colors().danger).width(18).textAlign(TextAlign.Center);}Column({space:3}){Text(step.label).fontSize(13).fontColor(this.colors().text);if(step.timing){Text(step.timing).fontSize(10).fontColor(this.colors().textTertiary);}}.layoutWeight(1).alignItems(HorizontalAlign.Start);}.width('100%');},(step:LocalTimelineStep)=>step.key)
      if(this.timeline.message){Text(this.timeline.message).fontSize(12).fontColor(this.colors().danger).width('100%');}
      if(this.selected.stage===InstallStage.WAITING_ACCOUNT||this.task()?.job.stage===InstallStage.WAITING_ACCOUNT){Text(this.renewal?'请前往「我的」登录开发者账号后继续续签。':'请前往「我的」登录开发者账号后继续安装。').fontSize(12).fontColor(this.colors().textSecondary).width('100%');}
      if(!this.task()?.running&&this.task()?.job.stage!==InstallStage.INSTALLED&&this.task()?.job.stage!==InstallStage.QUEUED){Button(this.task()?.job.stage===InstallStage.TERMINAL_ERROR?'重新选包':this.renewal?'继续续签':'继续安装').width('100%').height(44).fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft).onClick(()=>this.retry());}
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(this.colors().surface).borderRadius(22)
  }
  build(){
    Stack({alignContent:Alignment.Top}){
        Scroll(){Column({space:18}){
          Column({space:14}){
            if(this.pixels){Image(this.pixels).width(72).height(72).borderRadius(20);}else{SymbolGlyph($r('sys.symbol.square_and_arrow_down')).fontSize(34).fontColor([this.colors().accent]);}
            Text(this.title||'选择安装文件').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.colors().text).maxLines(2).textAlign(TextAlign.Center)
            if(this.selected.id){Text((this.selected.versionName||String(this.selected.versionCode))+(this.fileSize?' · '+this.fileSize:'')).fontSize(12).fontColor(this.colors().textSecondary);Text(this.selected.bundleName).fontSize(11).fontColor(this.colors().textTertiary).wordBreak(WordBreak.BREAK_ALL).textAlign(TextAlign.Center);}
            else{Text(this.storeRenewal&&this.busy?'正在查找同版本原包…':this.renewal?'选择已安装应用的同版本 HAP / APP / ZIP':'HAP / APP / ZIP · 预览后再安装').fontSize(12).fontColor(this.colors().textSecondary);}
            if(this.renewal&&this.preview){Text('刷新授权后覆盖签装，保留应用数据。').fontSize(12).fontColor(this.colors().textSecondary).textAlign(TextAlign.Center);}
            if(this.preview&&this.choices.length>1){Select(this.choices.map((job:InstallJob)=>({value:job.assetName} as SelectOption))).selected(this.choices.findIndex((job:InstallJob)=>job.id===this.selected.id)).value(this.selected.assetName).width('100%').height(44).fontColor(this.colors().text).optionFontColor(this.colors().text).optionBgColor(this.colors().surface).selectedOptionBgColor(this.colors().accentSoft).selectedOptionFontColor(this.colors().accent).menuBackgroundColor(this.colors().surface).backgroundColor(this.colors().fill).onSelect((index:number)=>this.choose(this.choices[index]));}
            if(this.preview||(!this.selected.id&&!this.busy)){Row({space:12}){
              Button(this.preview?(this.renewal?'续签':'安装'):'选择安装文件').layoutWeight(1).height(48).fontSize(15).backgroundColor(this.colors().accent).fontColor(this.colors().onAccent).enabled(!this.busy).id('local-install-primary').onClick(()=>{if(this.preview)this.install();else this.pick();});
              if(this.preview&&this.canRenew&&!this.renewal){Button('续签').layoutWeight(1).height(48).fontSize(15).backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent).enabled(!this.busy).id('local-renew-primary').onClick(()=>this.install(true));}
            }.width('100%');}
          }.width('100%').padding(24).backgroundColor(this.colors().surface).borderRadius(22)
          if(this.message){Text(this.message).width('100%').fontSize(12).fontColor(this.colors().danger);}
          if(this.timeline.visible){this.timelineCard();}
        }.width('100%').constraintSize({maxWidth:StoreLayout.contentWidth}).padding({left:24,right:24,top:this.statusBarInset+78,bottom:36})}.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
      StorePageHeader({title:this.renewal?(this.storeRenewal?'商店续签':'手动续签'):'从本地签装',
        statusInset:this.statusBarInset,visible:this.headerVisible&&!this.showReconnect && !this.showCertificatePrompt,
        active:!this.busy||this.storeRenewal,action:()=>{this.onBackPress();},
        backAction:()=>{this.onBackPress();},tools:()=>{this.headerTools();}}).position({x:0,y:0})
      InstallPrompts({active:this.pageActive,showing:this.showReconnect,dismissRequest:this.promptDismiss})
      InstallCertificatePrompt({active:this.pageActive,showing:this.showCertificatePrompt,dismissRequest:this.certificatePromptDismiss})
    }.width('100%').height('100%').backgroundColor(this.colors().bg).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
  }
}
