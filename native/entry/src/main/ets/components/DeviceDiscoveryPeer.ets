import { NearbyDevice } from '../jobs/DeviceDiscovery';
import { DeviceGlassCircle } from './DeviceGlassCircle';
import { Palette } from '../theme/Palette';
import { DevicePanelInk } from './DevicePanelInk';
import { I18n } from '../data/I18n';

/** Stable observed peer: heartbeats update status without remounting its product image. */
@Component
export struct DeviceDiscoveryPeer {
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @StorageProp('darkMode') private darkMode:boolean=false;
  @ObjectLink device:NearbyDevice;
  @Prop list:boolean=false;
  @Prop compact:boolean=false;
  @Prop diameter:number=64;
  @Prop active:boolean=true;
  @Prop selected:boolean=false;
  @Prop busy:boolean=false;
  @Prop nameHeight:number=32;
  action:()=>void=()=>{};
  onForget:()=>void=()=>{};
  onClose:()=>void=()=>{};
  private colors():Palette{return Palette.forMode(this.darkMode);}
  private status():string{return this.busy?I18n.t('连接中'):!this.device.debugDetected?I18n.t('输入端口'):this.device.checking?I18n.t('确认中'):!this.device.online?I18n.t('离线'):this.selected?I18n.t('已选'):this.device.udid?I18n.t('选择'):I18n.t('连接');}
  private caption():string{return !this.device.debugDetected?this.device.host:this.device.checking?I18n.t('确认中'):this.device.online?String(this.device.port):I18n.t('离线 · ')+this.device.port;}
  private symbol():Resource{return this.device.kind==='unknown'?$r('sys.symbol.rectangle_on_rectangle'):this.device.kind==='tablet'?$r('sys.symbol.pad'):this.device.kind==='pc'?$r('sys.symbol.computer'):$r('sys.symbol.phone_1');}
  @Builder private node(diameter:number){
    Stack({alignContent:Alignment.TopEnd}){
      DeviceGlassCircle({inline:true,visible:this.active,controlId:'multi-device-node-'+this.device.id+(this.list?'-list':''),
        diameter:diameter,deviceKind:this.device.kind==='unknown'?'':this.device.kind,model:this.device.model,
        marketName:this.device.marketName||this.device.name,symbol:this.symbol(),selected:this.selected,loading:this.busy,
        backAction:this.onClose,label:this.device.name+I18n.t('，')+this.status()+I18n.t('，')+this.caption(),action:this.action})
      if(this.device.udid){Circle().width(5).height(5).fill(this.device.checking?this.colors().textTertiary:this.device.online?this.colors().success:this.colors().danger)
        .stroke(this.colors().surface).strokeWidth(2).margin({right:2,top:3}).hitTestBehavior(HitTestMode.None)}
    }.width(diameter).height(diameter).opacity(this.device.debugDetected&&!this.device.online&&!this.device.checking?.45:1)
  }
  @Builder private spatial(){
    Column({space:4}){
      this.node(this.compact?48:this.diameter)
      Text(this.device.name).fontSize(this.compact?11:12).lineHeight(16).fontWeight(FontWeight.Medium).foregroundColor(DevicePanelInk.contrast(this.darkMode,false,this.materialMode))
        .width('100%').height(this.compact?32:this.nameHeight).maxLines(this.compact?2:100).textOverflow({overflow:TextOverflow.Ellipsis})
        .margin({top:4}).textAlign(TextAlign.Center)
      Text(this.caption())
        .fontSize(this.compact?10:11).lineHeight(14).height(14).maxLines(1).foregroundColor(DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
    }.width('100%')
  }
  @Builder private row(){
    Row({space:11}){
      this.node(38)
      Column({space:4}){
        Text(this.device.name).fontSize(13).fontWeight(FontWeight.Medium).foregroundColor(this.selected?this.colors().text:DevicePanelInk.contrast(this.darkMode,false,this.materialMode)).maxLines(1)
        Text(this.device.debugDetected?(this.device.kind==='tablet'?I18n.t('平板'):this.device.kind==='pc'?I18n.t('电脑'):this.device.kind==='unknown'?I18n.t('设备'):I18n.t('手机'))+' · '+this.device.port:this.device.host)
          .fontSize(11).foregroundColor(this.selected?this.colors().textSecondary:DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.status()).fontSize(11).foregroundColor(this.selected?this.colors().accent:DevicePanelInk.contrast(this.darkMode,true,this.materialMode))
      if(this.selected){SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([this.colors().accent])}
      else{SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).attributeModifier(DevicePanelInk.symbol(this.darkMode,this.materialMode))}
    }.width('100%').height(64).padding({left:10,right:10}).borderRadius(16)
      .backgroundColor(this.selected?(this.darkMode?'#26344A':Color.White):Color.Transparent)
      .border({width:this.selected?.7:0,color:this.colors().borderStrong,radius:16}).onClick(this.action)
  }
  build(){
    Column(){if(this.list){this.row()}else{this.spatial()}}.width('100%')
      .priorityGesture(LongPressGesture({duration:550,repeat:false}).onAction(this.onForget))
  }
}
