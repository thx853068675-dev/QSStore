import { displayVersion } from '../data/DisplayVersion';
import { router, promptAction, uiMaterial } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { InstalledInspection,InstalledSelection,InspectionSection,InspectionField } from '../data/InstalledInspection';
import { InspectionSearch } from '../data/InspectionSearch';
import { InstalledIconCache } from '../data/InstalledIconCache';
import { LocalBundles } from '../jobs/LocalBundles';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { JobStore } from '../jobs/JobStore';
import { InstalledSigningExpiry } from '../jobs/InstalledSigningExpiry';
import { Palette } from '../theme/Palette';
import { StoreImmersiveIconButton,StoreLayout,StoreTopFade } from '../theme/StoreDesign';

@Entry
@Component
struct InstalledDetail {
  @StorageProp('darkMode') darkMode:boolean=false;
  @StorageProp('statusBarInset') statusBarInset:number=0;
  @State private info:InstalledSelection=new InstalledSelection();
  @State private sections:InspectionSection[]=[];
  @State private matches:InspectionSection[]=[];
  @State private searchText:string='';
  @State private query:string='';
  @State private informationRevision:number=0;
  @State private headerVisible:boolean=false;
  @State private searchWidth:number=0;
  @State private pixels:image.PixelMap|null=null;
  @State private busy:boolean=false;
  @State private notice:string='';
  @State private expanded:string[]=[];
  @State private renewalExpiry:string='';
  private scroller:Scroller=new Scroller();
  private initialRead:boolean=true;
  private expiryReadToken:number=0;
  private disposed:boolean=false;
  private returning:boolean=false;
  private backTimer:number=-1;
  private ownedPixels?:image.PixelMap;
  private searchDebounce:InspectionSearch=new InspectionSearch((query:string)=>{this.query=query;this.applySearch();if(query)this.scroller.scrollTo({xOffset:0,yOffset:0});});
  private colors():Palette{return Palette.forMode(this.darkMode);}
  aboutToAppear():void {
    this.headerVisible=true;
    const params=router.getParams() as Record<string,Object>;
    this.info=JSON.parse(String(params['selection']??'{}')) as InstalledSelection;
    this.pixels=InstalledInspection.selectedIcon??null;
    this.read();this.readIcon();
  }
  aboutToDisappear():void{this.headerVisible=false;this.disposed=true;if(this.backTimer!==-1)clearTimeout(this.backTimer);this.searchDebounce.close();this.ownedPixels?.release();this.ownedPixels=undefined;this.pixels=null;}
  onPageShow():void{if(!this.disposed&&!this.returning){this.headerVisible=true;this.readRenewalExpiry();}}
  onPageHide():void{this.headerVisible=false;}
  onBackPress():boolean{this.back();return true;}
  private back():void{
    if(this.disposed||this.returning)return;
    this.returning=true;
    // Material popups share the page's lifetime. Remove all overlays before routing back.
    this.headerVisible=false;
    this.backTimer=setTimeout(()=>{if(!this.disposed)router.back({url:'pages/Index'});},32);
  }
  private applySearch():void{this.matches=InstalledInspection.filter(this.sections,this.query);this.informationRevision++;}
  private search(value:string,preview?:PreviewText):void{const composing=preview?.value??'';this.searchDebounce.change(value,composing);if(!composing)this.searchText=value;}
  private acceptIcon(pixels:image.PixelMap):void{if(this.disposed){pixels.release();return;}this.ownedPixels?.release();this.ownedPixels=pixels;this.pixels=pixels;}
  private async readIcon():Promise<void>{
    try{const context=getContext(this) as common.UIAbilityContext;
      const live=await LocalBundles.installedIcon(context,this.info.bundleName,this.info.mainAbility);
      if(live){this.acceptIcon(live);return;}
      if(this.pixels!==null)return;
      const bytes=await InstalledIconCache.load(context,this.info.bundleName,this.info.versionCode);
      if(bytes){const source=image.createImageSource(bytes);try{this.acceptIcon(await source.createPixelMap());}finally{source.release();}}
    }catch(_){}
  }
  private async read():Promise<void>{
    if(this.busy)return;this.busy=true;this.notice='';
    const base = new Map<string,Object>([['安装来源',this.info.source],['versionName',this.info.versionName],['versionCode',this.info.versionCode],['bundleName',this.info.bundleName],['moduleName',this.info.moduleName],['mainAbility',this.info.mainAbility]]);
    const known:Record<string,Object>={};base.forEach((value:Object,key:string)=>known[key]=value);
    if(!this.sections.length){this.sections=InstalledInspection.sections(known);this.applySearch();}
    try{const data=await InstalledInspection.read(getContext(this) as common.UIAbilityContext,this.info.bundleName);if(this.disposed)return;this.info.title=String(data['displayName']??this.info.title);Object.keys(data).forEach((key:string)=>known[key]=data[key]);this.sections=InstalledInspection.sections(known);this.applySearch();this.info.versionName=String(data['versionName']??this.info.versionName);this.info.versionCode=Number(data['versionCode']??this.info.versionCode);}
    catch(error){this.notice=String(error);}
    finally{this.busy=false;this.readRenewalExpiry();if(this.initialRead){this.initialRead=false;setTimeout(()=>{if(!this.disposed)this.scroller.scrollTo({xOffset:0,yOffset:0});},50);}}
  }
  private async readRenewalExpiry():Promise<void>{
    const token=++this.expiryReadToken,bundle=this.info.bundleName,version=this.info.versionCode;
    try{const context=getContext(this) as common.UIAbilityContext,store=await JobStore.open(context);
      const expiry=await InstalledSigningExpiry.read(bundle,version,await store.listAll());
      const materials=expiry>0?[]:await InstalledSigningExpiry.estimateMaterials(context,[bundle]);
      const estimate=expiry>0?0:InstalledSigningExpiry.estimate(bundle,version,materials,this.info.updatedAt);
      if(!this.disposed&&token===this.expiryReadToken&&bundle===this.info.bundleName&&version===this.info.versionCode)
        this.renewalExpiry=InstalledSigningExpiry.label(expiry,estimate);
    }catch(_){}
  }
  private async copy(text:string):Promise<void>{try{await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,text));const preview=text.replace(/\s+/g,' ');promptAction.showToast({message:'已复制：'+preview.substring(0,100)+(preview.length>100?'…':''),duration:2500});}catch(_){promptAction.showToast({message:'暂时无法复制，请重试'});}}
  @Builder private section(section:InspectionSection){
    Column({space:12}){
      Row(){Text(section.name).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1);
        if(!this.query&&section.fields.length>8){Text(this.expanded.includes(section.name)?'收起':'展开 '+section.fields.length+' 项').fontSize(12).fontColor(this.colors().accent).onClick(()=>{this.expanded=this.expanded.includes(section.name)?this.expanded.filter((name:string)=>name!==section.name):this.expanded.concat(section.name);});}}
      ForEach(this.query||this.expanded.includes(section.name)?section.fields:section.fields.slice(0,8),(field:InspectionField)=>{
        Row({space:14}){
          Text(field.key).fontSize(11).wordBreak(WordBreak.BREAK_ALL).fontColor(this.colors().textTertiary).width('34%');
          Text(field.value).fontSize(12).fontColor(this.colors().text).wordBreak(WordBreak.BREAK_ALL).textAlign(TextAlign.End).layoutWeight(1).onClick(()=>this.copy(field.value)).accessibilityText(field.key+'：'+field.value+'，点按复制');
        }.width('100%').alignItems(VerticalAlign.Top);
      },(field:InspectionField)=>field.key)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(18).backgroundColor(this.colors().surface).borderRadius(18)
  }
  @Builder private searchInput(){
    Row({space:8}){SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(16).fontColor([this.colors().textSecondary]);
      TextInput({text:this.searchText,placeholder:'搜索信息'}).height(44).layoutWeight(1).fontSize(14).fontColor(this.colors().text).placeholderColor(this.colors().textSecondary).backgroundColor(Color.Transparent).caretColor(this.colors().accent).padding({left:0,right:0}).cancelButton({style:CancelButtonStyle.INPUT}).enablePreviewText(true).maxLength(120).id('installed-info-search').onChange((value:string,preview?:PreviewText)=>this.search(value,preview));
    }.width('100%').height(44).padding({left:13,right:8}).backgroundColor(Color.Transparent).focusable(true).defaultFocus(true)
  }
  @Builder private informationHeader(){
    Stack({alignContent:Alignment.Top}){
      StoreTopFade({statusInset:this.statusBarInset})
      Row({space:10}){
        StoreImmersiveIconButton({symbol:$r('sys.symbol.chevron_left'),label:'返回',controlId:'installed-info-back',visible:this.headerVisible,action:()=>this.back(),backAction:()=>this.back()});
        if(deviceInfo.sdkApiVersion>=26&&uiMaterial.isImmersiveMaterialSupported()){
          Column(){}.height(44).layoutWeight(1).onSizeChange((_old:SizeOptions,size:SizeOptions)=>{const width=Number(size.width);if(Number.isFinite(width)&&width>0&&Math.abs(width-this.searchWidth)>0.5)this.searchWidth=width;})
            .bindPopup(this.headerVisible&&this.searchWidth>0,{builder:this.searchInput,width:this.searchWidth,radius:22,
              placement:Placement.Bottom,targetSpace:0,offset:{x:0,y:-44},enableArrow:false,autoCancel:false,focusable:true,mask:false,
              onWillDismiss:(action:DismissPopupAction)=>{if(action.reason===DismissReason.PRESS_BACK)this.back();},
              systemMaterial:new uiMaterial.ImmersiveMaterial({style:uiMaterial.ImmersiveStyle.THIN,colorInvert:true,applyShadow:true,interactive:true,lightEffect:{color:this.colors().surface}})})
        }else{
          Stack(){this.searchInput();}.height(44).layoutWeight(1).borderRadius(22).clip(true)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN,{colorMode:this.darkMode?ThemeColorMode.DARK:ThemeColorMode.LIGHT})
            .border({width:0.5,color:this.colors().border,radius:22}).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        }
        StoreImmersiveIconButton({symbol:$r('sys.symbol.arrow_clockwise'),label:'刷新应用信息',controlId:'installed-info-refresh',loading:this.busy,visible:this.headerVisible,action:()=>this.read(),backAction:()=>this.back()});
      }.width('100%').constraintSize({maxWidth:StoreLayout.contentWidth+48}).padding({left:16,right:16,top:this.statusBarInset+6,bottom:8})
    }.width('100%').height(this.statusBarInset+58).position({x:0,y:0})
  }
  build(){
    Stack({alignContent:Alignment.Top}){
      Scroll(this.scroller){Column({space:16}){
        if(!this.query){
        Column({space:12}){
          if(this.pixels){Image(this.pixels).width(80).height(80).borderRadius(22);}else{Text(this.info.title.substring(0,1)||'应').fontSize(32).fontColor(this.colors().accent).textAlign(TextAlign.Center).width(80).height(80).backgroundColor(this.colors().accentSoft).borderRadius(22);}
          Row({space:5}){Text(this.info.title).fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.colors().text).textAlign(TextAlign.Center).maxLines(2).constraintSize({maxWidth:'58%'}).onClick(()=>this.copy(this.info.title));Text(displayVersion(this.info.versionName||String(this.info.versionCode),this.info.title)).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.colors().surface).backgroundColor(this.colors().text).height(22).padding({left:5,right:5}).borderRadius(4).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).constraintSize({maxWidth:'38%'}).onClick(()=>this.copy(this.info.versionName||String(this.info.versionCode)));}.width('100%').justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center);
          Button({type:ButtonType.Normal}){Row({space:6}){Text(this.info.bundleName).fontSize(11).fontColor(this.colors().textTertiary).maxLines(2).textAlign(TextAlign.Center);}}.backgroundColor(Color.Transparent).padding(4).id('installed-copy-bundle').onClick(()=>this.copy(this.info.bundleName));
          Text(this.renewalExpiry||InstalledSigningExpiry.label(0,0,
            InstalledAppRegistry.installationTime(this.info.bundleName,this.info.versionCode)||this.info.updatedAt))
            .fontSize(11).fontColor(this.colors().textTertiary);
        }.width('100%').padding(22).backgroundColor(this.colors().surface).borderRadius(22)
        }
        if(this.notice){Text(this.notice).fontSize(12).fontColor(this.colors().textSecondary).width('100%');}
        if(this.query){Text(this.matches.length?'找到 '+this.matches.reduce((count:number,section:InspectionSection)=>count+section.fields.length,0)+' 项':'未找到匹配信息').fontSize(12).fontColor(this.colors().textSecondary).width('100%');}
        ForEach(this.matches,(section:InspectionSection)=>{this.section(section);},(section:InspectionSection)=>section.name+'|'+this.informationRevision)
      }.width('100%').constraintSize({maxWidth:StoreLayout.contentWidth}).padding({left:24,right:24,top:this.statusBarInset+78,bottom:36})}.height('100%').width('100%').align(Alignment.Top).scrollBar(BarState.Off)
      this.informationHeader()
    }.width('100%').height('100%').backgroundColor(this.colors().bg).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
  }
}
