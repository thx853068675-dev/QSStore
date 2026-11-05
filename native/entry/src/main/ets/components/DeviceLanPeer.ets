import { NearbyDevice } from '../jobs/DeviceDiscovery';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { DeviceLanDraft } from '../data/DeviceLanDraft';
import { DevicePanelInk } from './DevicePanelInk';
import { I18n } from '../data/I18n';

/** Read-only address; the discovery session retains drafts across lazy row mounts. */
@Reusable
@Component
export struct DeviceLanPeer {
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @StorageProp('darkMode') private dark:boolean=false;
  @ObjectLink device:NearbyDevice;
  @ObjectLink draft:DeviceLanDraft;
  @Prop blocked:boolean=false;
  @Prop active:boolean=true;
  @Prop addressWidth:number=96;
  onConnect:(port:string)=>Promise<void>=async()=>{};
  onPortChanged:(port:string)=>void=()=>{};
  private inputController:TextInputController=new TextInputController();
  aboutToRecycle():void{this.inputController.stopEditing();}
  aboutToReuse(params:Record<string,Object|undefined|null>):void{
    // ObjectLink is rebound by ArkUI; plain callbacks must follow the new IP.
    this.blocked=params.blocked as boolean;
    this.active=params.active===undefined?true:params.active as boolean;
    this.addressWidth=params.addressWidth as number;
    this.onConnect=params.onConnect as (port:string)=>Promise<void>;
    this.onPortChanged=params.onPortChanged as (port:string)=>void;
  }
  private colors():Palette{return Palette.forMode(this.dark);}
  private connected():boolean{return !!this.device.udid&&this.device.online&&!this.device.checking&&String(this.device.port)===this.draft.port;}
  private async submit():Promise<void>{
    if(this.blocked||this.draft.busy||!this.active||this.connected())return;
    // An awaited authorization can finish after this view is reused for another IP.
    const draft=this.draft,connect=this.onConnect;
    draft.busy=true;draft.setNotice('');
    try{await connect(draft.port);}
    catch(error){if(!String(error).includes('已取消'))draft.setNotice(errorText(error));}
    finally{draft.busy=false;}
  }
  build(){
    Column({space:0}){
      Row({space:8}){
        Row({space:4}){
        Text(this.device.host).fontSize(14).minFontSize(11).maxFontSize(14).maxLines(1)
          .fontWeight(FontWeight.Medium).foregroundColor(DevicePanelInk.contrast(this.dark,false,this.materialMode)).width(this.addressWidth).flexShrink(1)
          .id('multi-device-ip-'+this.device.host)
        Text(':').fontSize(14).foregroundColor(DevicePanelInk.contrast(this.dark,true,this.materialMode)).width(6).textAlign(TextAlign.Center)
        TextInput({text:this.draft.port,placeholder:I18n.t('端口'),controller:this.inputController}).type(InputType.Number).maxLength(5).fontSize(14).fontWeight(FontWeight.Medium)
          .placeholderFont({size:14}).textAlign(TextAlign.Center)
          .fontColor(this.colors().text).placeholderColor(this.colors().textSecondary)
          .backgroundColor(this.dark?'#263044':'#EDF0F7').border({width:.5,color:this.colors().border,radius:10})
          .width(76).height(36).padding({left:6,right:6}).borderRadius(10).enabled(this.active&&!this.draft.busy)
          .id('multi-device-ip-port-'+this.device.host).accessibilityText(this.device.host+I18n.t(' 的无线调试端口'))
          .onChange((value:string)=>{if(this.draft.port===value)return;this.draft.port=value;this.draft.edited=true;this.draft.setNotice('');this.onPortChanged(value);})
          .enterKeyType(EnterKeyType.Go).onSubmit(()=>this.submit())
          .onTouch((event:TouchEvent)=>event.stopPropagation())
        }.layoutWeight(1).justifyContent(FlexAlign.Start)
        Button(){
            if(this.draft.busy){LoadingProgress().width(16).height(16).color(this.colors().accent)}
            else{Text(this.connected()?I18n.t('已连'):I18n.t('连接')).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.connected()?this.colors().success:this.colors().accent)}
          }.width(56).height(36).padding(0).borderRadius(10).backgroundColor(this.dark?'#263044':'#EDF0F7')
            .enabled(this.active&&!this.blocked&&!this.draft.busy&&!this.connected())
            .accessibilityText(this.device.host+(this.draft.busy?I18n.t('，等待连接授权'):this.connected()?I18n.t('，已连接'):I18n.t('，连接')))
            .id('multi-device-ip-connect-'+this.device.host).onClick(()=>this.submit())
      }.width('100%').height(55.5)
      if(this.draft.notice){Text(this.draft.notice).fontSize(11).lineHeight(16).fontColor(this.colors().danger)
        .width('100%').height(48).maxLines(3).margin({bottom:8}).id('multi-device-ip-error-'+this.device.host)}
      Divider().color(this.colors().border).strokeWidth(.5)
    }.width('100%').height(this.draft.notice?112:56)
  }
}
