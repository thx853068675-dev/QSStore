import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { InstallReconnect } from '../jobs/InstallReconnect';
import { InstallConfirmation } from '../jobs/InstallConfirmation';
import { InstallConflictFlow } from '../jobs/InstallConflictFlow';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { InstallJob,InstallStage } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { LocalBundles } from '../jobs/LocalBundles';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { FixedDebugPort } from '../jobs/FixedDebugPort';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { MultiDeviceTargets } from '../jobs/MultiDeviceTargets';
import { MultiDeviceDialog } from './MultiDeviceDialog';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton,StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

/** Foreground pages own prompts; the process-owned queue owns execution. */
@Component
export struct InstallPrompts {
  @Prop @Watch('syncActive') active:boolean=true;
  @Prop @Watch('dismiss') dismissRequest:number=0;
  @Link showing:boolean;
  @StorageProp('darkMode') darkMode:boolean=false;
  @State private port:string='';
  private portReadGeneration:number=0;
  private portInputRevision:number=0;
  @State private connecting:boolean=false;
  @State private message:string='';
  @State private remote:boolean=false;
  @State private expectedUdid:string='';
  private reconnectId:number=-1; private confirmationId:number=-1;
  private jobId:string=''; private disposed:boolean=false;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void{
    this.reconnectId=InstallReconnect.subscribe((id:string)=>{this.prepareReconnect(id);});
    this.confirmationId=InstallConfirmation.subscribe((id:string)=>{if(id)this.confirm(id);});
    this.syncActive();
  }
  aboutToDisappear():void{this.disposed=true;InstallReconnect.unsubscribe(this.reconnectId);InstallConfirmation.unsubscribe(this.confirmationId);this.showing=false;}
  private syncActive():void{
    if(this.reconnectId<0||this.confirmationId<0)return;
    if(this.active){InstallReconnect.activate(this.reconnectId);InstallConfirmation.activate(this.confirmationId);}
    else{InstallReconnect.deactivate(this.reconnectId);InstallConfirmation.deactivate(this.confirmationId);this.showing=false;}
  }
  private async restorePort():Promise<void>{
    const generation=++this.portReadGeneration,revision=this.portInputRevision;
    try{
      const port=await new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).savedPort();
      if(!this.disposed&&this.active&&this.showing&&!this.connecting&&
        generation===this.portReadGeneration&&revision===this.portInputRevision){
        this.port=Number.isInteger(port)&&port>=1024&&port<=65535?String(port):'';
      }
    }catch(_){}
  }
  private async prepareReconnect(id:string):Promise<void>{
    this.jobId=id;this.showing=false;this.remote=false;
    if(!id)return;
    try{
      const context=getContext(this) as common.UIAbilityContext;
      const job=await (await JobStore.open(context)).get(id);
      if(this.disposed||!this.active||this.jobId!==id||!InstallReconnect.isOwner(this.reconnectId)||!InstallReconnect.isRequested(id))return;
      if(!job||job.stage!==InstallStage.WAITING_DEVICE)return;
      this.remote=!!job.installTarget;this.expectedUdid=job.installTarget?DeviceInstallTarget.parse(job.installTarget).udid:'';this.message='';this.showing=true;
      if(!this.remote)this.restorePort();
    }catch(_){}
  }
  private async resumeRemote(target:DeviceInstallTarget=MultiDeviceTargets.selected):Promise<void>{
    const id=this.jobId,context=getContext(this) as common.UIAbilityContext;
    try{
      const store=await JobStore.open(context),job=await store.get(id);
      if(!job?.installTarget||this.disposed||!this.active||this.jobId!==id)return;
      const expected=DeviceInstallTarget.parse(job.installTarget);
      if(expected.udid!==target.udid){promptAction.showToast({message:I18n.t('该任务需要连接 ')+expected.name});return;}
      job.installTarget=DeviceInstallTarget.snapshot(target);
      await store.save(job);InstallReconnect.clear(id);this.showing=false;
      InstallCoordinator.run(context,id).catch((error:Error)=>promptAction.showToast({message:errorText(error)}));
    }catch(error){promptAction.showToast({message:errorText(error)});}
  }
  private async confirm(id:string):Promise<void>{
    await InstallConflictFlow.present(getContext(this) as common.UIAbilityContext,this.confirmationId,id);
  }

  private async connect():Promise<void>{
    if(this.connecting)return;this.connecting=true;this.message=I18n.t('正在连接，请在系统弹窗中信任本机');
    try{
      const context=getContext(this) as common.UIAbilityContext,bridge=new HdcDeviceBridge(context),id=this.jobId;
      if(!await bridge.connect(Number(this.port.trim()))){this.message=bridge.connectionFailureMessage();return;}
      InstallReconnect.clear(id);this.showing=false;this.message='';
      FixedDebugPort.wake();
      InstallCoordinator.conditionReady(context,InstallStage.WAITING_DEVICE).catch((error:Error)=>promptAction.showToast({message:errorText(error)}));
    }catch(error){this.message=errorText(error);}finally{this.connecting=false;}
  }
  private close():void{if(this.connecting)return;InstallReconnect.clear(this.jobId);this.showing=false;}
  private dismiss():void{this.close();}
  build(){
    if(this.showing&&this.remote){
      MultiDeviceDialog({expectedUdid:this.expectedUdid,onClose:()=>this.close(),onConnected:(target:DeviceInstallTarget)=>this.resumeRemote(target)})
    }else if(this.showing){
      Stack({alignContent:Alignment.Center}){
        Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(()=>this.close())
        Column({space:16}){
          Row(){Text(I18n.t('连接无线调试')).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1);StoreIconButton({label:I18n.t('关闭连接窗口'),active:!this.connecting,action:()=>this.close()});}.width('100%')
          Text(I18n.t('前往系统设置，开启无线调试')).fontSize(12).fontColor(this.colors().accent).width('100%').height(36).decoration({type:TextDecorationType.Underline,color:this.colors().accent}).onClick(()=>new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).openWirelessSettings())
          Text(I18n.t('安装进度已保留，连接后会继续安装。')).fontSize(13).fontColor(this.colors().textSecondary).width('100%')
          TextInput({text:this.port,placeholder:I18n.t('输入无线调试端口')}).type(InputType.Number).textAlign(TextAlign.Center).height(48).backgroundColor(this.colors().fill).fontColor(this.colors().text).onChange((value:string)=>{if(value!==this.port)this.portInputRevision++;this.port=value;})
          Button(){Row({space:8}){if(this.connecting){LoadingProgress().width(18).height(18).color(this.colors().onAccent);}Text(this.connecting?I18n.t('正在连接…'):I18n.t('连接并继续安装')).fontSize(14).fontColor(this.colors().onAccent);}.justifyContent(FlexAlign.Center)}.width('100%').height(48).backgroundColor(this.colors().accent).enabled(!this.connecting).onClick(()=>this.connect())
          if(this.message){Text(this.message).fontSize(12).fontColor(this.colors().textSecondary).width('100%');}
        }.width('calc(100% - 40vp)').constraintSize({maxWidth:StoreLayout.sheetWidth}).padding(22).backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius)
      }.width('100%').height('100%').position({x:0,y:0})
    }else{Column().width(0).height(0)}
  }
}
