import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { CatalogApp } from '../data/CatalogApp';
import { AppDisplayName } from '../data/AppDisplayName';
import { Palette } from '../theme/Palette';
import { StoreIconButton,StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';
@Component
export struct FollowingInfoDialog{
  app:CatalogApp=new CatalogApp();onClose:()=>void=()=>{};
  @StorageProp('darkMode') private darkMode:boolean=false;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  private async copy(value:string):Promise<void>{
    try{await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,value));
      promptAction.showToast({message:value});}catch(_){promptAction.showToast({message:I18n.t('复制失败')});}
  }
  @Builder private field(key:string,value:string){
    if(value){Row({space:16}){
      Text(I18n.t(key)).fontSize(13).fontColor(this.colors().textSecondary).width(80)
      Text(value).fontSize(13).fontColor(this.colors().text).textAlign(TextAlign.End).layoutWeight(1)
        .onClick(()=>this.copy(value))
    }.width('100%').padding({top:12,bottom:12})}
  }
  build(){
    Stack({alignContent:Alignment.Center}){
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(this.onClose)
      Column({space:8}){
        Row(){Text(I18n.t('应用信息')).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
          StoreIconButton({symbol:$r('sys.symbol.xmark'),label:I18n.t('关闭'),action:this.onClose})
        }.width('100%')
        Scroll(){Column(){
          this.field('应用名称',AppDisplayName.forCatalog(this.app))
          this.field('包名',this.app.latestAsset?.bundleName??'')
          this.field('内部编号',this.app.latestAsset?.versionCode?String(this.app.latestAsset.versionCode):'')
          this.field('分类',I18n.category(this.app.category))
          this.field('上架者',this.app.publisherName)
          this.field('来源仓库',this.app.repo)
          this.field('更新时间',this.app.latestPublishedAt)
        }.width('100%')}.width('100%').constraintSize({maxHeight:400}).scrollBar(BarState.Off)
      }.padding(20).width('calc(100% - 40vp)').constraintSize({maxWidth:StoreLayout.sheetWidth})
        .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius).onClick(()=>{})
    }.width('100%').height('100%')
  }
}
