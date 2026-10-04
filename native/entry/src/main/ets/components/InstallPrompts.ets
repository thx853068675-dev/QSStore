import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { InstallReconnect } from '../jobs/InstallReconnect';
import { InstallConfirmation } from '../jobs/InstallConfirmation';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { InstallJob,InstallStage } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { LocalBundles } from '../jobs/LocalBundles';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton,StoreLayout } from '../theme/StoreDesign';

/** Foreground pages own prompts; the process-owned queue owns execution. */
@Component
export struct InstallPrompts {
  @Prop @Watch('syncActive') active:boolean=true;
  @Prop @Watch('dismiss') dismissRequest:number=0;
  @Link showing:boolean;
  @StorageProp('darkMode') darkMode:boolean=false;
  @State private port:string='';
  @State private connecting:boolean=false;
  @State private message:string='';
  private reconnectId:number=-1; private confirmationId:number=-1;
  private jobId:string=''; private disposed:boolean=false;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void{
    this.reconnectId=InstallReconnect.subscribe((id:string)=>{this.jobId=id;this.showing=!!id;if(id){this.message='';this.restorePort();}});
    this.confirmationId=InstallConfirmation.subscribe((id:string)=>{if(id)this.confirm(id);});
    this.syncActive();
  }
  aboutToDisappear():void{this.disposed=true;InstallReconnect.unsubscribe(this.reconnectId);InstallConfirmation.unsubscribe(this.confirmationId);this.showing=false;}
  private syncActive():void{
    if(this.reconnectId<0||this.confirmationId<0)return;
    if(this.active){InstallReconnect.activate(this.reconnectId);InstallConfirmation.activate(this.confirmationId);}
    else{InstallReconnect.deactivate(this.reconnectId);InstallConfirmation.deactivate(this.confirmationId);this.showing=false;}
  }
  private async restorePort():Promise<void>{if(this.port)return;try{const port=await new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).savedPort();if(!this.disposed&&!this.port&&port>=1024&&port<=65535)this.port=String(port);}catch(_){}}
  private async confirm(id:string):Promise<void>{
    try{
      const context=getContext(this) as common.UIAbilityContext,store=await JobStore.open(context),job=await store.get(id);
      if(!job||job.stage!==InstallStage.WAITING_CONFIRMATION||!InstallConfirmation.isOwner(this.confirmationId)||!InstallConfirmation.isRequested(id))return;
      InstallConfirmation.clear(id);
      const renewal=job.renewalRequestedAt>0;
      AlertDialog.show({title:InstallConfirmation.dataLossTitle(renewal),message:InstallConfirmation.dataLossMessage(renewal,LocalBundles.isSelfBundle(job.bundleName)),primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:InstallConfirmation.dataLossAction(renewal),action:async()=>{
        try{const identity=await new HdcDeviceBridge(context).installedSigningIdentity(job.bundleName);if(!identity)throw new Error('无法核对当前安装身份，请连接无线调试后重试');await store.approveDataLoss(id,identity);await InstallCoordinator.run(context,id);}catch(error){promptAction.showToast({message:errorText(error)});}
      }}});
    }catch(_){}
  }
  private async connect():Promise<void>{
    if(this.connecting)return;this.connecting=true;this.message='正在连接，请在系统弹窗中信任本机';
    try{
      const context=getContext(this) as common.UIAbilityContext,bridge=new HdcDeviceBridge(context),id=this.jobId;
      if(!await bridge.connect(Number(this.port.trim()))){this.message=bridge.connectionFailureMessage();return;}
      InstallReconnect.clear(id);this.showing=false;this.message='';
      InstallCoordinator.conditionReady(context,InstallStage.WAITING_DEVICE).catch((error:Error)=>promptAction.showToast({message:errorText(error)}));
    }catch(error){this.message=errorText(error);}finally{this.connecting=false;}
  }
  private close():void{if(this.connecting)return;InstallReconnect.clear(this.jobId);this.showing=false;}
  private dismiss():void{this.close();}
  build(){
    if(this.showing){
      Stack({alignContent:Alignment.Center}){
        Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(()=>this.close())
        Column({space:16}){
          Row(){Text('连接无线调试').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1);StoreIconButton({label:'关闭连接窗口',active:!this.connecting,action:()=>this.close()});}.width('100%')
          Text('前往系统设置，开启无线调试').fontSize(12).fontColor(this.colors().accent).width('100%').height(36).decoration({type:TextDecorationType.Underline,color:this.colors().accent}).onClick(()=>new HdcDeviceBridge(getContext(this) as common.UIAbilityContext).openWirelessSettings())
          Text('安装进度已保留，连接后会继续安装。').fontSize(13).fontColor(this.colors().textSecondary).width('100%')
          TextInput({text:this.port,placeholder:'输入无线调试端口'}).type(InputType.Number).textAlign(TextAlign.Center).height(48).backgroundColor(this.colors().fill).fontColor(this.colors().text).onChange((value:string)=>this.port=value)
          Button(){Row({space:8}){if(this.connecting){LoadingProgress().width(18).height(18).color(this.colors().onAccent);}Text(this.connecting?'正在连接…':'连接并继续安装').fontSize(14).fontColor(this.colors().onAccent);}.justifyContent(FlexAlign.Center)}.width('100%').height(48).backgroundColor(this.colors().accent).enabled(!this.connecting).onClick(()=>this.connect())
          if(this.message){Text(this.message).fontSize(12).fontColor(this.colors().textSecondary).width('100%');}
        }.width('calc(100% - 40vp)').constraintSize({maxWidth:StoreLayout.sheetWidth}).padding(24).backgroundColor(this.colors().surface).borderRadius(26)
      }.width('100%').height('100%').position({x:0,y:0})
    }else{Column().width(0).height(0)}
  }
}
