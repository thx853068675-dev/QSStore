import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { MultiDeviceTargets } from '../jobs/MultiDeviceTargets';
import { errorText } from '../jobs/ErrorText';
import { DeviceStackPortrait } from './DeviceStackPortrait';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

@Component
export struct MultiDeviceCard {
  @StorageProp('darkMode') private darkMode:boolean=false;
  @StorageProp('installTargetCount') private targetCount:number=1;
  @StorageProp('installTargetName') private targetName:string='';
  @StorageProp('deviceMultiEnabled') private modeEnabled:boolean=false;
  @State private saving:boolean=false;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  private summary():string{
    if(!this.modeEnabled)return I18n.t('未开启');
    return I18n.t('已开启 · ')+(this.targetCount>1?this.targetCount+I18n.t(' 台设备'):this.targetName||I18n.t('本机'));
  }
  private async toggle():Promise<void>{
    if(this.saving)return;
    this.saving=true;
    try{
      await MultiDeviceTargets.load(getContext(this) as common.UIAbilityContext);
      if(MultiDeviceTargets.modeEnabled)await MultiDeviceTargets.disable();
      else await MultiDeviceTargets.enable();
    }catch(error){promptAction.showToast({message:errorText(error)});}
    finally{this.saving=false;}
  }
  build(){
    Row({space:14}){
      Row({space:14}){
        Stack({alignContent:Alignment.Center}){
          DeviceStackPortrait({glyphSize:42})
        }.width(44).height(44)
        Column({space:6}){
          Text(I18n.t('多设备胶囊')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          Text(this.summary()).fontSize(12).fontColor(this.modeEnabled?this.colors().accent:this.colors().textSecondary)
            .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.layoutWeight(1).constraintSize({minHeight:44})
        .id('mine-multi-device').accessibilityText(I18n.t('多设备胶囊，')+this.summary())
      Button({type:ButtonType.Capsule}){
        Row({space:6}){
          if(this.saving){LoadingProgress().width(14).height(14).color(this.colors().accent)}
          else{SymbolGlyph(this.modeEnabled?$r('sys.symbol.xmark'):$r('sys.symbol.link')).fontSize(14)
            .fontColor([this.modeEnabled?this.colors().textSecondary:this.colors().onAccent])}
          Text(this.modeEnabled?I18n.t('停用'):I18n.t('启用')).fontSize(12).fontColor(this.modeEnabled?this.colors().textSecondary:this.colors().onAccent)
        }
      }.height(38).padding({left:14,right:14})
        .backgroundColor(this.modeEnabled?this.colors().fill:this.colors().accent)
        .responseRegion({x:0,y:-3,width:'100%',height:44}).enabled(!this.saving)
        .id('mine-multi-device-toggle').accessibilityText(this.modeEnabled?I18n.t('停用多设备并切回本机'):I18n.t('启用多设备'))
        .onClick(()=>this.toggle())
    }.padding(16).width('100%').borderRadius(StoreLayout.cardRadius)
      .linearGradient({angle:115,colors:this.modeEnabled?
        [[this.colors().surface,0],[this.darkMode?'#172C4A':'#EDF3FF',.55],[this.darkMode?'#1C3860':'#DBE8FF',1]]:
        [[this.colors().surface,0],[this.colors().fill,1]]})
      .border({width:.5,color:this.modeEnabled?this.colors().borderStrong:this.colors().border,radius:StoreLayout.cardRadius})
  }
}
