import { displayVersion } from '../data/DisplayVersion';
import { router,promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker,fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { LocalImport } from '../jobs/LocalImport';
import { PackageEditor,EditablePackage } from '../jobs/PackageEditor';
import { InstalledInspection,InspectionSection,InspectionField } from '../data/InstalledInspection';
import { Palette } from '../theme/Palette';
import { StoreIconButton,StoreImmersiveIconButton,StoreLayout,StorePageHeader } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';

@Observed
class PackageEditDraft {
  row:EditablePackage; name:string; bundle:string; iconPath:string='';
  pixels:image.PixelMap|null=null; status:string;
  constructor(row:EditablePackage){this.row=row;this.name=row.newName;this.bundle=row.identity.bundleName;this.status=row.status;}
}
@Component
struct PackageEditCard {
  @ObjectLink draft:PackageEditDraft;
  @Prop busy:boolean=false;
  @StorageProp('darkMode') darkMode:boolean=false;
  inspect:()=>void=()=>{}; chooseIcon:()=>void=()=>{}; generate:()=>void=()=>{}; signInstall:()=>void=()=>{};
  private colors():Palette{return Palette.forMode(this.darkMode);}
  @Builder private fieldLabel(label:string){Text(label).fontSize(13).fontColor(this.colors().textSecondary).width(68);}
  build(){
    Column({space:16}){
      Row({space:12}){
        Stack({alignContent:Alignment.BottomEnd}){
          if(this.draft.pixels){Image(this.draft.pixels).width(48).height(48).borderRadius(13);}
          else{Text('包').width(48).height(48).textAlign(TextAlign.Center).fontColor(this.colors().accent).backgroundColor(this.colors().accentSoft).borderRadius(13);}
          Stack({alignContent:Alignment.Center}){
            SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(10).fontColor([this.colors().accent])
          }.width(18).height(18).backgroundColor('#B8'+this.colors().surface.substring(1)).borderRadius(9)
            .border({width:0.5,color:this.colors().border}).offset({x:-3,y:-3})
        }.width(48).height(48).enabled(!this.busy&&!this.draft.row.status.startsWith('读取失败')).id('editor-icon-'+this.draft.row.path).accessibilityText('更换应用图标').onClick(()=>this.chooseIcon())
        Column({space:5}){Text(this.draft.name.trim()||this.draft.row.identity.displayName||this.draft.row.filename).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.colors().text).maxLines(2);Text(displayVersion(this.draft.row.identity.versionName||'未知版本',this.draft.row.identity.displayName)+' · '+(this.draft.row.bytes/1048576).toFixed(1)+' MB').fontSize(11).fontColor(this.colors().textTertiary);}.layoutWeight(1).alignItems(HorizontalAlign.Start)
        StoreIconButton({symbol:$r('sys.symbol.info_circle'),label:'查看包信息',action:()=>this.inspect()});
      }.width('100%')
      if(this.draft.row.identity.bundleName&&!this.draft.row.status.startsWith('读取失败')){
        Column({space:1}){
          Row({space:8}){this.fieldLabel('应用名称');TextInput({text:this.draft.name,placeholder:'填写应用名称'}).layoutWeight(1).height(StoreLayout.fieldHeight).fontSize(14).fontColor(this.colors().text).backgroundColor(Color.Transparent).maxLength(64).enabled(!this.busy).id('editor-name-'+this.draft.row.path).onChange((value:string)=>{if(value!==this.draft.name){this.draft.name=value;this.draft.status='待生成';}});}.padding({left:14,right:10}).width('100%')
          Divider().color(this.colors().border).margin({left:14,right:14})
          Row({space:8}){this.fieldLabel('包名');TextInput({text:this.draft.bundle,placeholder:'com.example.app'}).layoutWeight(1).height(StoreLayout.fieldHeight).fontSize(13).fontColor(this.colors().text).backgroundColor(Color.Transparent).maxLength(128).enabled(!this.busy).id('editor-bundle-'+this.draft.row.path).onChange((value:string)=>{if(value!==this.draft.bundle){this.draft.bundle=value;this.draft.status='待生成';}});}.padding({left:14,right:10}).width('100%')
        }.width('100%').backgroundColor(this.colors().fill).borderRadius(14)
        if(this.draft.bundle.trim()!==this.draft.row.identity.bundleName){
          Text('将作为新应用安装，原应用的账号与授权绑定可能失效。')
            .fontSize(12).lineHeight(18).fontColor(this.colors().textSecondary).width('100%')
        }
        Row({space:10}){
          Button('生成并导出', {type:ButtonType.Normal}).borderRadius(StoreLayout.cardActionRadius).layoutWeight(1).height(StoreLayout.fieldHeight).fontSize(14).fontWeight(FontWeight.Medium).backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent).enabled(!this.busy).id('editor-save-'+this.draft.row.path).onClick(()=>this.generate())
          Button('直接签装', {type:ButtonType.Normal}).borderRadius(StoreLayout.cardActionRadius).layoutWeight(1).height(StoreLayout.fieldHeight).fontSize(14).fontWeight(FontWeight.Medium).backgroundColor(this.colors().accent).fontColor(this.colors().onAccent).enabled(!this.busy).id('editor-install-'+this.draft.row.path).onClick(()=>this.signInstall())
        }.width('100%')
      }
      if(this.draft.status&&this.draft.status!=='已读取'){Text(this.draft.status).fontSize(12).fontColor(this.draft.status.includes('失败')?this.colors().danger:this.colors().textSecondary).width('100%');}
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
      .backgroundColor(this.colors().surface).borderRadius(StoreLayout.cardRadius)
  }
}
@CustomDialog
struct PackageInformationDialog {
  controller?:CustomDialogController;
  title:string=''; sections:InspectionSection[]=[]; copyValue:(value:string)=>void=()=>{};
  @State private expanded:string[]=[];
  @StorageProp('darkMode') darkMode:boolean=false;
  private colors():Palette{return Palette.forMode(this.darkMode);}
  build(){
    Column({space:16}){
      Row({space:12}){Column({space:5}){Text('包信息').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text);Text(this.title).fontSize(11).fontColor(this.colors().textTertiary).maxLines(2);}.layoutWeight(1).alignItems(HorizontalAlign.Start);StoreIconButton({label:'关闭包信息',action:():void=>{this.controller?.close();}});}.width('100%')
      Scroll(){Column({space:16}){
        ForEach(this.sections,(section:InspectionSection)=>{
          Column({space:12}){
            Row(){Text(section.name).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
              if(section.fields.length>20){Text(this.expanded.includes(section.name)?'收起':'展开 '+section.fields.length+' 项').fontSize(11).fontColor(this.colors().accent).padding({top:8,bottom:8}).onClick(()=>{this.expanded=this.expanded.includes(section.name)?this.expanded.filter((name:string)=>name!==section.name):this.expanded.concat(section.name);});}
            }.width('100%')
            ForEach(this.expanded.includes(section.name)?section.fields:section.fields.slice(0,20),(field:InspectionField)=>{Row({space:12}){Text(field.key).width('40%').fontSize(12).wordBreak(WordBreak.BREAK_ALL).fontColor(this.colors().textSecondary);Text(field.value).layoutWeight(1).fontSize(13).wordBreak(WordBreak.BREAK_ALL).textAlign(TextAlign.End).fontColor(this.colors().text).onClick(()=>this.copyValue(field.value));}.width('100%').alignItems(VerticalAlign.Top);},(field:InspectionField)=>field.key)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(14).backgroundColor(this.colors().fill).borderRadius(14)
        },(section:InspectionSection)=>section.name)
      }.width('100%').alignItems(HorizontalAlign.Start)}.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
    }.width('calc(100% - 40vp)').constraintSize({maxWidth:StoreLayout.sheetWidth}).height('72%').padding(22)
      .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius)
  }
}
@Entry
@Component
struct PackageTools {
  pageTransition() {
    PageTransitionEnter(StorePageMotion.options(RouteType.Push)).slide(SlideEffect.Right).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionEnter(StorePageMotion.stationary(RouteType.Pop)).translate({ x: 0 }).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionExit(StorePageMotion.stationary(RouteType.Push)).translate({ x: 0 }).opacity(1).scale({ x: 1, y: 1 })
    PageTransitionExit(StorePageMotion.options(RouteType.Pop)).slide(SlideEffect.Right).opacity(1).scale({ x: 1, y: 1 })
  }
  @StorageProp('darkMode') darkMode:boolean=false;
  @StorageProp('statusBarInset') statusBarInset:number=0;
  @State private drafts:PackageEditDraft[]=[];
  @State private busy:boolean=false;
  @State private message:string='';
  @State private headerVisible:boolean=true;
  private disposed:boolean=false; private pickerTimer:number=-1;
  private returning:boolean=false; private backTimer:number=-1;
  private informationDialog?:CustomDialogController;
  private scroller:Scroller=new Scroller();
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void{PackageEditor.cleanup(getContext(this) as common.UIAbilityContext);this.pickerTimer=setTimeout(()=>{if(!this.disposed)this.pick();},StorePageMotion.duration+32);}
  onPageShow():void{if(!this.disposed&&!this.returning)this.headerVisible=true;}
  onPageHide():void{this.headerVisible=false;}
  aboutToDisappear():void{this.disposed=true;this.headerVisible=false;clearTimeout(this.pickerTimer);clearTimeout(this.backTimer);this.informationDialog?.close();if(!this.busy)this.dispose();}
  onBackPress():boolean{if(this.busy){promptAction.showToast({message:'正在处理，请稍候'});return true;}this.back();return true;}
  private back():void{
    if(this.disposed||this.returning)return;
    this.returning=true;this.headerVisible=false;
    StorePageMotion.prepare();
    this.backTimer=setTimeout(()=>{if(!this.disposed)router.back();},32);
  }
  private dispose():void{PackageEditor.dispose(this.drafts.map((draft:PackageEditDraft)=>draft.row));for(const draft of this.drafts){draft.pixels?.release();draft.pixels=null;if(draft.iconPath)try{fileIo.unlinkSync(draft.iconPath);}catch(_){}}this.drafts=[];}
  private finish():void{this.busy=false;if(this.disposed)this.dispose();}
  private remove(draft:PackageEditDraft):void{
    if(this.busy)return;
    PackageEditor.dispose([draft.row]);draft.pixels?.release();draft.pixels=null;
    if(draft.iconPath)try{fileIo.unlinkSync(draft.iconPath);}catch(_){}
    this.drafts=this.drafts.filter((item:PackageEditDraft)=>item!==draft);
  }
  @Builder private deleteAction(draft:PackageEditDraft){
    Column({space:8}){
      SymbolGlyph($r('sys.symbol.trash')).fontSize(20).fontColor([this.colors().onAccent])
      Text('删除').fontSize(13).fontColor(this.colors().onAccent)
    }.width(64).height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.colors().danger).borderRadius(22)
      .enabled(!this.busy).accessibilityText('删除导入的安装包').id('editor-delete-'+draft.row.path).onClick(()=>this.remove(draft))
  }
  private async pick():Promise<void>{
    if(this.busy||this.disposed)return;this.busy=true;this.message='';this.headerVisible=false;
    try{
      await StorePageMotion.dismissFrame();const rows=await PackageEditor.select(getContext(this) as common.UIAbilityContext);if(!rows.length)return;
      if(this.disposed){PackageEditor.dispose(rows);return;}
      this.dispose();const drafts:PackageEditDraft[]=[];
      for(const row of rows){const draft=new PackageEditDraft(row);drafts.push(draft);if(row.icon){try{const source=image.createImageSource(row.icon);try{draft.pixels=await source.createPixelMap({desiredSize:{width:96,height:96}});}finally{source.release();}}catch(_){}}}
      this.drafts=drafts;this.scroller.scrollTo({xOffset:0,yOffset:0});
    }catch(error){this.message=String(error);}finally{if(!this.disposed&&!this.returning)this.headerVisible=true;this.finish();}
  }
  private async pickIcon(draft:PackageEditDraft):Promise<void>{
    if(this.busy)return;this.busy=true;this.message='';this.headerVisible=false;
    try{
      await StorePageMotion.dismissFrame();const context=getContext(this) as common.UIAbilityContext;
      const selected=await new picker.DocumentViewPicker(context).select({fileSuffixFilters:['图片|.png,.jpg,.jpeg,.webp'],maxSelectNumber:1});if(!selected.length)return;
      const path=await PackageEditor.normalizeIcon(selected[0],context),source=image.createImageSource(path);
      try{const pixels=await source.createPixelMap({desiredSize:{width:96,height:96}});draft.pixels?.release();if(draft.iconPath)try{fileIo.unlinkSync(draft.iconPath);}catch(_){}draft.pixels=pixels;draft.iconPath=path;draft.status='待生成';}finally{source.release();}
    }catch(error){draft.status='图标读取失败：'+String(error);}finally{if(!this.disposed&&!this.returning)this.headerVisible=true;this.finish();}
  }
  private async generate(draft:PackageEditDraft):Promise<void>{
    if(this.busy)return;this.busy=true;this.message='';draft.status='正在生成…';
    try{await PackageEditor.edit(draft.row,draft.name,draft.iconPath,draft.bundle);draft.status='已生成，等待导出';if(this.disposed)return;this.headerVisible=false;await StorePageMotion.dismissFrame();const saved=await PackageEditor.saveMany(getContext(this) as common.UIAbilityContext,[draft.row]);draft.status=saved?'已导出':(draft.row.status.startsWith('导出失败')?draft.row.status:'已生成，已取消导出');}
    catch(error){draft.status='处理失败：'+String(error);}finally{if(!this.disposed&&!this.returning)this.headerVisible=true;this.finish();}
  }
  private async signInstall(draft:PackageEditDraft):Promise<void>{
    if(this.busy)return;this.busy=true;this.message='';draft.status='正在生成…';
    const context=getContext(this) as common.UIAbilityContext;
    try{
      const path=await PackageEditor.edit(draft.row,draft.name,draft.iconPath,draft.bundle);
      if(this.disposed)return;
      const preview=await LocalImport.editedPreview(context,path,draft.row.filename);
      if(this.disposed){LocalImport.discardPreview(context,preview);return;}
      try{await StorePageMotion.pushUrl({url:'pages/LocalInstall',params:{preview:preview,direct:true}});draft.status='已提交签装';}
      catch(error){LocalImport.discardPreview(context,preview);throw error as Error;}
    }catch(error){draft.status='处理失败：'+String(error);}finally{this.finish();}
  }
  private inspect(draft:PackageEditDraft):void{
    const info:Record<string,Object>={'包信息':draft.row.identity,'模块':draft.row.modules,'权限':draft.row.permissions,'文件名称':draft.row.filename,'文件大小':draft.row.bytes};
    this.informationDialog?.close();this.informationDialog=new CustomDialogController({builder:PackageInformationDialog({title:draft.row.filename,sections:InstalledInspection.sections(info),copyValue:(value:string)=>this.copy(value)}),alignment:DialogAlignment.Center,autoCancel:true,customStyle:true});this.informationDialog.open();
  }
  private async copy(text:string):Promise<void>{try{await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,text));const preview=text.replace(/\s+/g,' ');promptAction.showToast({message:'已复制：'+preview.substring(0,100)+(preview.length>100?'…':''),duration:2500});}catch(_){promptAction.showToast({message:'暂时无法复制，请重试'});}}
  @Builder private headerTools(){
    StoreImmersiveIconButton({symbol:$r('sys.symbol.plus'),label:'选择安装包',
      controlId:'package-tools-add',loading:this.busy,visible:this.headerVisible,
      action:()=>this.pick(),backAction:()=>{this.onBackPress();}})
  }
  build(){
    Stack({alignContent:Alignment.Top}){
      List({space:18,scroller:this.scroller}){
        if(!this.drafts.length){ListItem(){Column({space:14}){SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(36).fontColor([this.colors().accent]);Text('选择需要编辑的安装包').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text);Text('HAP / APP · 可多选，每个包独立编辑').fontSize(12).fontColor(this.colors().textSecondary);Button('选择安装包').width('100%').height(46).backgroundColor(this.colors().accent).fontColor(this.colors().onAccent).enabled(!this.busy).id('editor-select-packages').onClick(()=>this.pick());}.width('100%').padding(24).backgroundColor(this.colors().surface).borderRadius(22);}}
        if(this.message){ListItem(){Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%');}}
        ForEach(this.drafts,(draft:PackageEditDraft)=>{
          ListItem(){PackageEditCard({draft:draft,busy:this.busy,inspect:()=>this.inspect(draft),chooseIcon:()=>this.pickIcon(draft),generate:()=>this.generate(draft),signInstall:()=>this.signInstall(draft)});}
            .swipeAction({end:{builder:()=>{this.deleteAction(draft)},actionAreaDistance:64},edgeEffect:SwipeEdgeEffect.Spring})
        },(draft:PackageEditDraft)=>draft.row.path)
      }.width('100%').height('100%').constraintSize({maxWidth:StoreLayout.contentWidth})
        .padding({left:24,right:24}).contentStartOffset(this.statusBarInset+78).contentEndOffset(36).scrollBar(BarState.Off)
      StorePageHeader({title:'包编辑',statusInset:this.statusBarInset,visible:this.headerVisible,
        active:!this.busy,action:()=>{this.onBackPress();},backAction:()=>{this.onBackPress();},
        tools:()=>{this.headerTools();}}).position({x:0,y:0})
    }.width('100%').height('100%').backgroundColor(this.colors().bg).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
  }
}
