import { Palette } from './Palette';
import { uiMaterial, LengthMetrics, LevelMode } from '@kit.ArkUI';
import { hdsMaterial, TitleBarStyleOptions, ScrollEffectType, BlurStrategy } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 四个主页面和浮层共用的布局尺度，宽屏保留舒适的阅读宽度。 */
export class StoreLayout {
  static readonly contentWidth: number = 720;
  static readonly sheetWidth: number = 520;
  static readonly cardActionRadius: number = 14;
  static readonly cardActionWidth: number = 64;
  static readonly cardWideActionWidth: number = 84;
  static readonly navigationBottomMargin: number = 20;
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
        .margin({ bottom: StoreLayout.navigationBottomMargin })
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

/** The detail action and selected capsules share the same native tinted material. */
export function storeTintedImmersiveMaterial(tint: string, strength: number = 1,
  applyShadow: boolean = true): uiMaterial.ImmersiveMaterial {
  const alpha = Math.round(153 * Math.min(1, Math.max(0, strength))).toString(16).padStart(2, '0');
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#' + alpha + tint.substring(1), colorInvert: false,
    applyShadow: applyShadow, interactive: true, lightEffect: { color: tint } });
}

/** 浮动主操作使用系统材质；低版本继续使用原有实色按钮。 */
@Component
export struct StoreImmersiveAction {
  @StorageProp('routeTransitioning') @Watch('onPopupRequestChanged') private routeTransitioning:boolean=false;
  @Prop @Watch('onPopupRequestChanged') visible:boolean=true;
  @Prop tint:string='#1F5DEF';
  @Prop controlHeight:number=52;
  @Prop controlRadius:number=18;
  @Prop tintStrength:number=1;
  @Prop colored:boolean=true;
  @Prop followsTarget:boolean=false;
  @Prop anchorAtStart:boolean=false;
  @Prop embedded:boolean=false;
  @Prop viewportOffset:number=0;
  @State private placementCorrectionX:number=0;
  @State private placementCorrectionY:number=0;
  private anchorX:number=NaN;
  private anchorY:number=NaN;
  @Prop popupShadow:boolean=true;
  backAction:()=>void=()=>{};
  @BuilderParam content:(immersive:boolean)=>void;
  @State @Watch('onPopupRequestChanged') private measuredWidth:number=0;
  @State private popupVisible:boolean=false;
  private canUseMaterial():boolean{
    try{return deviceInfo.sdkApiVersion>=26&&uiMaterial.isImmersiveMaterialSupported();}
    catch(_){return false;}
  }
  private popupWidth():number{return this.measuredWidth;}
  private popupRequested():boolean{return this.visible&&!this.routeTransitioning&&this.measuredWidth>0&&this.popupWidth()>0.5;}
  private onPopupRequestChanged():void{if(!this.popupRequested())this.popupVisible=false;}
  private onPopupStateChanged(visible:boolean):void{this.popupVisible=visible&&this.popupRequested();}
  private fallbackVisible():boolean{
    return this.visible&&!this.routeTransitioning&&(!this.canUseMaterial()||!this.popupVisible);
  }
  private actionMaterial():uiMaterial.ImmersiveMaterial{
    // Native material shadows override Popup.shadow. Disable both for clipped toolbar pills.
    if(this.colored)return storeTintedImmersiveMaterial(this.tint,this.tintStrength,this.popupShadow);
    return new uiMaterial.ImmersiveMaterial({style:uiMaterial.ImmersiveStyle.THIN,
      materialColor:'#00000000',colorInvert:false,applyShadow:false,interactive:true,lightEffect:{color:this.tint}});
  }
  // Keep the native bubble at its full size; only its NavDestination clips it.
  // Measure and cancel the system's placement inset, rather than hard-code a device margin.
  private correctEmbeddedPlacement(area:Area):void{
    if(!this.embedded||!this.popupRequested()||!Number.isFinite(this.anchorX)||!Number.isFinite(this.anchorY))return;
    const x=Number(area.globalPosition.x),y=Number(area.globalPosition.y);
    if(!Number.isFinite(x)||!Number.isFinite(y))return;
    const dx=this.anchorX+this.viewportOffset-x,dy=this.anchorY-y;
    if(Math.abs(dx)>0.2)this.placementCorrectionX+=dx;
    if(Math.abs(dy)>0.2)this.placementCorrectionY+=dy;
  }
  private popupAnchorX():number{return this.embedded?-this.viewportOffset:0;}
  private popupOffset():Position{
    return {x:this.embedded?this.viewportOffset+this.placementCorrectionX:0,
      y:(this.anchorAtStart?-this.controlHeight:this.controlHeight)+(this.embedded?this.placementCorrectionY:0)};
  }
  @Builder private immersiveContent(){
    Row(){
      this.content(true);
    }.width(this.popupWidth()).height(this.controlHeight)
      .onAreaChange((_old:Area,area:Area)=>{this.correctEmbeddedPlacement(area);})
  }
  build(){
    Stack({alignContent:Alignment.Start}){
      // Capability support is not proof that the separate popup window has appeared.
      // Keep a usable in-page action until the system confirms actual visibility.
      if(this.fallbackVisible()){this.content(false);}
      if(this.canUseMaterial()){
      Column(){}.width('100%').height(this.controlHeight)
        .onSizeChange((_old:SizeOptions,size:SizeOptions)=>{
          const width=Number(size.width);
          if(Number.isFinite(width)&&width>0)this.measuredWidth=width;
        })
      Column(){}.width(Math.max(0.5,this.popupWidth())).height(this.controlHeight).position({x:this.popupAnchorX(),y:0})
        .onAreaChange((_old:Area,area:Area)=>{
          this.anchorX=Number(area.globalPosition.x);this.anchorY=Number(area.globalPosition.y);
        })
        .bindPopup(this.popupRequested(),{builder:this.immersiveContent,width:this.popupWidth(),radius:this.controlRadius,
          // Header anchors open below themselves; the bottom install action retains its upward placement.
          placement:this.anchorAtStart?Placement.BottomLeft:Placement.Top,targetSpace:0,
          offset:this.popupOffset(),enableArrow:false,autoCancel:false,
          focusable:false,mask:false,
          followTransformOfTarget:this.followsTarget,transition:TransitionEffect.IDENTITY,
          levelMode:this.embedded?LevelMode.EMBEDDED:LevelMode.OVERLAY,
          shadow:this.popupShadow?undefined:{radius:0,color:Color.Transparent,offsetX:0,offsetY:0},
          popupColor:this.popupShadow?undefined:Color.Transparent,
          backgroundBlurStyle:this.popupShadow?undefined:BlurStyle.NONE,
          onStateChange:(event:PopupStateChangeParam)=>{this.onPopupStateChanged(event.isVisible);},
          onWillDismiss:(action:DismissPopupAction)=>{if(action.reason===DismissReason.PRESS_BACK)this.backAction();},
          systemMaterial:this.actionMaterial()})
      }
    }.width('100%').height(this.controlHeight)
  }
}
