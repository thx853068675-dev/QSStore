import { Palette } from './Palette';
import { uiMaterial, LengthMetrics } from '@kit.ArkUI';
import { hdsMaterial, TitleBarStyleOptions, ScrollEffectType, BlurStrategy } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 四个主页面和浮层共用的布局尺度，宽屏保留舒适的阅读宽度。 */
export class StoreLayout {
  static readonly contentWidth: number = 720;
  static readonly sheetWidth: number = 520;
  static readonly cardActionRadius: number = 14;
  static readonly cardActionWidth: number = 64;
  static readonly cardWideActionWidth: number = 84;
  static inset(width: number): number { return width > 0 && width < 360 ? 16 : 24; }
}

/** 6.1 浮动栏的系统材质可能恢复为空，背景放在内容之上、原生页签之下。 */
@Component
export struct StoreTabBarBackdrop {
  @StorageProp('darkMode') private darkMode: boolean = false;
  build() {
    Column() {
      Column().width('calc(100% - 24vp)').constraintSize({ maxWidth: 328 }).height(56)
        .backgroundColor('#B3' + Palette.forMode(this.darkMode).surface.substring(1))
        .backgroundEffect({ radius: 24, saturation: 1.1, brightness: 1,
          color: '#66' + Palette.forMode(this.darkMode).surface.substring(1),
          policy: BlurStyleActivePolicy.ALWAYS_ACTIVE }, { disableSystemAdaptation: true })
        .borderRadius(28).clip(true)
        .border({ width: 0.5, color: Palette.forMode(this.darkMode).border, radius: 28 })
        .margin({ bottom: 20 })
    }.width('100%').height('100%').justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}

/** Single source for native HDS title bars and the shared top-glass component. */
export class StoreTopStyle {
  static readonly height: number = 55;
  static readonly extraHeight: number = 16;
  static readonly scrollDistance: number = 48;
  /** Eased opacity falloff, with gentle slopes at both ends. */
  static readonly fadeStops: Array<[ResourceColor, number]> = [
    ['#FFFFFFFF', 0], ['#FFFFFFFF', 0.16], ['#EBFFFFFF', 0.3],
    ['#C1FFFFFF', 0.42], ['#88FFFFFF', 0.54], ['#4EFFFFFF', 0.66],
    ['#1FFFFFFF', 0.78], ['#05FFFFFF', 0.9], ['#00FFFFFF', 1]
  ];

  static navigationStyle(titleHeight: number, statusInset: number, dark: boolean): TitleBarStyleOptions {
    return {
      // 系统默认 ADAPTIVE 允许动态改变模糊；固定启用，滚动速度不改变材质。
      blurStrategy: BlurStrategy.ENABLE,
      scrollEffectOpts: {
        enableScrollEffect: true,
        enableRefreshOffsetChange: false,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(Math.max(0, titleHeight - statusInset - StoreTopStyle.scrollDistance)),
        blurEffectiveEndOffset: LengthMetrics.vp(Math.max(StoreTopStyle.scrollDistance, titleHeight - statusInset))
      },
      originalStyle: { backgroundStyle: { backgroundColor: Color.Transparent } },
      scrollEffectStyle: { backgroundStyle: {
        backgroundColor: Palette.forMode(dark).bg, blurRadius: 32, maskExtraHeight: StoreTopStyle.extraHeight
      } },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
      }
    };
  }
}

/** Shared top glass: opaque at the status bar, fading into the scrolling content. */
@Component
export struct StoreTopFade {
  @Prop statusInset:number=0;
  @Prop fadeOpacity:number=1;
  @StorageProp('darkMode') private darkMode:boolean=false;
  build(){
    Stack(){
      // 模糊层与蒙版一起合成；放在外层背景上会留下未被渐隐的矩形底板。
      Column().width('100%').height('100%')
        .backgroundEffect({radius:32,saturation:1.1,brightness:1,
          color:'#80'+Palette.forMode(this.darkMode).bg.substring(1),policy:BlurStyleActivePolicy.ALWAYS_ACTIVE},
          {disableSystemAdaptation:true})
      Column().width('100%').height('100%').linearGradient({angle:180,colors:StoreTopStyle.fadeStops})
        .blendMode(BlendMode.DST_IN,BlendApplyType.OFFSCREEN)
    }.width('100%').height(this.statusInset+StoreTopStyle.height).opacity(this.fadeOpacity)
      .blendMode(BlendMode.SRC_OVER,BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}

/** 原生按钮提供按压与焦点反馈；符号、触摸区域和读屏名称始终一致。 */
@Component
export struct StoreIconButton {
  symbol: Resource = $r('sys.symbol.xmark');
  label: string = '关闭';
  controlSize: number = 44;
  @Prop active: boolean = true;
  action: () => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.symbol).fontSize(18)
        .fontColor([Palette.forMode(this.darkMode).textSecondary])
    }.width(this.controlSize).height(this.controlSize)
      .backgroundColor(Palette.forMode(this.darkMode).fill)
      .responseRegion({ x: (this.controlSize - 44) / 2, y: (this.controlSize - 44) / 2, width: 44, height: 44 })
      .enabled(this.active).stateEffect(true)
      .accessibilityText(this.label)
      .onClick(() => this.action())
  }
}

/** Same native floating material as DiscoverTopAction, with an older-system glass fallback. */
@Component
export struct StoreImmersiveIconButton {
  @StorageProp('routeTransitioning') private routeTransitioning:boolean=false;
  symbol:Resource=$r('sys.symbol.chevron_left');
  label:string='返回';
  title:string='';
  controlId:string='';
  action:()=>void=()=>{};
  backAction:()=>void=()=>{};
  @Prop visible:boolean=true;
  @Prop loading:boolean=false;
  @Prop active:boolean=true;
  @StorageProp('darkMode') private darkMode:boolean=false;
  @State private showing:boolean=false;
  aboutToAppear():void{this.showing=true;}
  aboutToDisappear():void{this.showing=false;}
  private controlWidth():number{return this.title?Math.min(220,56+this.title.length*16):44;}
  @Builder private content(){
    Button({type:this.title?ButtonType.Normal:ButtonType.Circle}){
      Row({space:6}){
        if(this.loading){LoadingProgress().width(22).height(22).color(Palette.forMode(this.darkMode).text);}
        else{SymbolGlyph(this.symbol).fontSize(18).fontColor([Palette.forMode(this.darkMode).text]);}
        if(this.title){Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Palette.forMode(this.darkMode).text).maxLines(1);}
      }.justifyContent(FlexAlign.Center)
    }.width(this.controlWidth()).height(44).borderRadius(22).padding({left:0,right:0})
      .backgroundColor(Color.Transparent).enabled(this.active&&!this.loading)
      .id(this.controlId).accessibilityText(this.loading?'正在刷新应用信息':this.label).onClick(()=>this.action())
  }
  build(){
    if(deviceInfo.sdkApiVersion>=26&&uiMaterial.isImmersiveMaterialSupported()){
      Column(){}.width(this.controlWidth()).height(44).bindPopup(this.showing&&this.visible&&!this.routeTransitioning,{builder:this.content,width:this.controlWidth(),radius:22,
        placement:Placement.Bottom,targetSpace:0,offset:{x:0,y:-44},enableArrow:false,autoCancel:false,
        onWillDismiss:(action:DismissPopupAction)=>{if(action.reason===DismissReason.PRESS_BACK)this.backAction();},
        focusable:false,mask:false,systemMaterial:new uiMaterial.ImmersiveMaterial({
          style:uiMaterial.ImmersiveStyle.THIN,colorInvert:true,applyShadow:true,interactive:true,
          lightEffect:{color:Palette.forMode(this.darkMode).surface}})})
    }else{
      Stack(){this.content();}.width(this.controlWidth()).height(44).borderRadius(22)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THIN,{colorMode:this.darkMode?ThemeColorMode.DARK:ThemeColorMode.LIGHT})
        .border({width:0.5,color:Palette.forMode(this.darkMode).border,radius:22}).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    }
  }
}

/** 详情与本地工具共用：返回符号和标题处于同一块系统光感材质中。 */
@Component
export struct StorePageHeader {
  title:string='';
  @Prop statusInset:number=0;
  @Prop fadeOpacity:number=1;
  @Prop visible:boolean=true;
  @Prop active:boolean=true;
  action:()=>void=()=>{};
  backAction:()=>void=()=>{};
  @BuilderParam tools:()=>void=this.emptyTools;
  @Builder private emptyTools(){}
  build(){
    Stack({alignContent:Alignment.Top}){
      StoreTopFade({statusInset:this.statusInset,fadeOpacity:this.fadeOpacity})
      Row(){
        StoreImmersiveIconButton({title:this.title,label:'返回 · '+this.title,visible:this.visible,
          active:this.active,action:this.action,backAction:this.backAction})
        Blank().layoutWeight(1)
        this.tools()
      }.width('100%').constraintSize({maxWidth:StoreLayout.contentWidth+40})
        .height(this.statusInset+58).padding({left:20,right:20,top:this.statusInset+6,bottom:8})
    }.width('100%').height(this.statusInset+58)
  }
}

/** 浮动主操作使用系统材质；低版本继续使用原有实色按钮。 */
@Component
export struct StoreImmersiveAction {
  @StorageProp('routeTransitioning') private routeTransitioning:boolean=false;
  @Prop visible:boolean=true;
  @Prop tint:string='#1F5DEF';
  backAction:()=>void=()=>{};
  @BuilderParam content:(immersive:boolean)=>void;
  @State private measuredWidth:number=0;
  @Builder private immersiveContent(){this.content(true);}
  build(){
    if(deviceInfo.sdkApiVersion>=26&&uiMaterial.isImmersiveMaterialSupported()){
      Column(){}.width('100%').height(52)
        .onSizeChange((_old:SizeOptions,size:SizeOptions)=>{this.measuredWidth=Number(size.width);})
        .bindPopup(this.visible&&!this.routeTransitioning&&this.measuredWidth>0,{builder:this.immersiveContent,width:this.measuredWidth,radius:18,
          // 底部浮层向上布局后回到锚点；向下布局会触发系统避让，再被负偏移推高。
          placement:Placement.Top,targetSpace:0,offset:{x:0,y:52},enableArrow:false,autoCancel:false,
          focusable:false,mask:false,
          onWillDismiss:(action:DismissPopupAction)=>{if(action.reason===DismissReason.PRESS_BACK)this.backAction();},
          systemMaterial:new uiMaterial.ImmersiveMaterial({style:uiMaterial.ImmersiveStyle.THIN,
            materialColor:'#99'+this.tint.substring(1),colorInvert:false,
            applyShadow:true,interactive:true,lightEffect:{color:this.tint}})})
    }else{this.content(false);}
  }
}
