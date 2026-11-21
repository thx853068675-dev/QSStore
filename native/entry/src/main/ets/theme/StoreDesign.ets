import { MaterialPreferences } from '../data/MaterialPreferences';
import { Palette } from './Palette';
import { uiMaterial, LengthMetrics, LevelMode } from '@kit.ArkUI';
import { hdsMaterial, TitleBarStyleOptions, ScrollEffectType, BlurStrategy } from '@kit.UIDesignKit';
import { StoreMaterial } from './StoreMaterial';
import { I18n } from '../data/I18n';

/** 四个主页面和浮层共用的布局尺度，宽屏保留舒适的阅读宽度。 */
export class StoreLayout {
  static readonly contentWidth: number = 720;
  /** 横屏（Pura X Max 等 940 × 664 vp）时首页改用双列合集版面，正文放宽。 */
  static readonly landscapeContentWidth: number = 900;
  static readonly sheetWidth: number = 520;
  static readonly cardActionRadius: number = 14;
  static readonly cardActionWidth: number = 64;
  static readonly cardWideActionWidth: number = 84;
  static readonly cardRadius: number = 22;
  static readonly heroRadius: number = 24;
  static readonly dialogRadius: number = 24;
  static readonly fieldHeight: number = 46;
  static readonly horizontalFadeLength: number = 14;
  static readonly navigationBottomMargin: number = 20;
  static readonly navigationHeight: number = 56;
  static readonly navigationActionGap: number = 8;
  /** 居中窄胶囊页签栏宽度：窄屏保持紧凑，宽屏略放宽。 */
  static readonly navigationCompactWidth: number = 208;
  static readonly navigationLargeWidth: number = 240;
  static readonly sidebarDetailScale: number = 0.84;
  static readonly sidebarCardInset: number = 12;
  private static readonly sidebarExitFraction: number = 0.36;
  /** One width is supplied to every native breakpoint and the fallback backplate. */
  static navigationBarWidth(width: number, height: number, sidebar: boolean): number {
    const wide = Number.isFinite(width) && (width >= 840 ||
      (width >= 600 && Number.isFinite(height) && height > 0 && width / height >= 0.8));
    if (!sidebar) {
      const desired = wide ? 320 : 280;
      return Number.isFinite(width) && width > 0 ? Math.min(desired, Math.max(0, width - 24)) : desired;
    }
    const desired = wide ? StoreLayout.navigationLargeWidth : StoreLayout.navigationCompactWidth;
    // Reserve space on both sides of the centered bar for the hand-aware action.
    return Number.isFinite(width) && width > 0 ? Math.min(desired, Math.max(160,
      width - 2 * (StoreLayout.navigationHeight + StoreLayout.navigationActionGap + 8))) : desired;
  }
  static sidebarFrameWidth(width: number): number {
    return Number.isFinite(width) && width > 0 ? Math.min(width, 1280) : 360;
  }
  static sidebarRailWidth(width: number): number { return width >= 600 ? 96 : 80; }
  static sidebarRailOnRight(fromRight: boolean, progress: number): boolean {
    return progress <= StoreLayout.sidebarExitFraction ? fromRight : !fromRight;
  }
  private static sidebarEntry(progress: number): number {
    const fraction = Math.max(0, (progress - StoreLayout.sidebarExitFraction) / (1 - StoreLayout.sidebarExitFraction));
    return fraction * fraction * (3 - 2 * fraction);
  }
  /** Keep the original list and article mounted. The rail only jumps when it is outside the window. */
  static sidebarRailShift(width: number, fromRight: boolean, progress: number): number {
    const frame = StoreLayout.sidebarFrameWidth(width);
    const rail = StoreLayout.sidebarRailWidth(width);
    const outside = Math.max(0, (width - frame) / 2) + 16;
    const onRight = StoreLayout.sidebarRailOnRight(fromRight, progress);
    const atRest = onRight ? frame - rail : 0;
    const origin = fromRight ? frame - rail : 0;
    const distance = progress <= StoreLayout.sidebarExitFraction ?
      Math.pow(progress / StoreLayout.sidebarExitFraction, 2) : 1 - StoreLayout.sidebarEntry(progress);
    return atRest - origin + (onRight ? 1 : -1) * (rail + outside) * distance;
  }
  static sidebarDetailShift(width: number, fromRight: boolean, progress: number): number {
    const entry = StoreLayout.sidebarEntry(progress);
    return (fromRight ? 1 : -1) * StoreLayout.sidebarRailWidth(width) * entry;
  }
  static dockExtraWidth(compactness: number): number {
    return (StoreLayout.navigationActionGap + StoreLayout.navigationHeight) * compactness;
  }
  static dockNavigationX(compactness: number, leftHand: boolean): number {
    return leftHand ? StoreLayout.dockExtraWidth(compactness) : 0;
  }
  static dockInstallX(barWidth: number, compactness: number, leftHand: boolean, hiddenProgress: number = 0): number {
    const extra = StoreLayout.dockExtraWidth(compactness);
    const resting = leftHand ? 0 : barWidth - StoreLayout.navigationHeight + extra;
    const centered = (barWidth + extra - StoreLayout.navigationHeight) / 2;
    const progress = Number.isFinite(hiddenProgress) ? Math.max(0, Math.min(1, hiddenProgress)) : 0;
    return resting + (centered - resting) * progress;
  }
  static inset(width: number): number { return width > 0 && width < 360 ? 16 : 24; }
  /** 横屏且宽度足够时启用宽版面；竖屏、分屏窄窗保持原单栏宽度。 */
  static wideLandscape(width: number, height: number): boolean {
    return Number.isFinite(width) && Number.isFinite(height) &&
      width >= 600 && height > 0 && width > height * 1.05;
  }
  /** 首页正文宽度：横屏放宽到 landscapeContentWidth，其余沿用 contentWidth。 */
  static discoverContentWidth(width: number, height: number): number {
    return StoreLayout.wideLandscape(width, height) ? StoreLayout.landscapeContentWidth : StoreLayout.contentWidth;
  }
  /** contentWidth is the readable area; frames include the same padding on both sides. */
  static frameMaxWidth(windowWidth: number = 0): number {
    return StoreLayout.contentWidth + StoreLayout.inset(windowWidth) * 2;
  }
  /** Keep the list viewport full-window while centering its readable area. */
  static contentInset(windowWidth: number, windowHeight: number = 0): number {
    if (!Number.isFinite(windowWidth) || windowWidth <= 0) return StoreLayout.inset(0);
    const content = StoreLayout.discoverContentWidth(windowWidth, windowHeight);
    return Math.max(StoreLayout.inset(windowWidth), (windowWidth - content) / 2);
  }
  static sheetMaxHeight(height: number, top: number = 0, bottom: number = 0): number {
    if (!Number.isFinite(height) || height <= 0) return 640;
    const topInset = Number.isFinite(top) ? Math.max(0, top) : 0;
    const bottomInset = Number.isFinite(bottom) ? Math.max(0, bottom) : 0;
    return Math.max(0, Math.min(height * 0.84, height - topInset - bottomInset - 32));
  }
}

/** Both dock controls use the same fallback paint, independent of native Button state styling. */
@Component
export struct StoreNavigationSurface {
  @Prop darkMode: boolean = false;
  @Prop sceneScale: number = 1;
  build() {
    Column().width('100%').height('100%')
      .backgroundColor('#A6' + Palette.forMode(this.darkMode).surface.substring(1))
      .backgroundEffect({ radius: 24 / this.sceneScale, saturation: 1.1, brightness: 1,
        color: '#33' + Palette.forMode(this.darkMode).surface.substring(1),
        policy: BlurStyleActivePolicy.ALWAYS_ACTIVE }, { disableSystemAdaptation: true })
      .borderRadius(28 / this.sceneScale).clip(true)
      .border({ width: 0.5 / this.sceneScale, color: Palette.forMode(this.darkMode).border,
        radius: 28 / this.sceneScale })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}

/** Single source for native HDS title bars and the shared top-glass component. */
export class StoreTopStyle {
  static readonly height: number = 55;
  static readonly extraHeight: number = 16;
  static readonly scrollDistance: number = 48;
  static readonly pinnedScrollDistance: number = 12;
  /** Eased opacity falloff, with gentle slopes at both ends. */
  static readonly fadeStops: Array<[ResourceColor, number]> = [
    ['#FFFFFFFF', 0], ['#FFFFFFFF', 0.16], ['#EBFFFFFF', 0.3],
    ['#C1FFFFFF', 0.42], ['#88FFFFFF', 0.54], ['#4EFFFFFF', 0.66],
    ['#1FFFFFFF', 0.78], ['#05FFFFFF', 0.9], ['#00FFFFFF', 1]
  ];

  static navigationStyle(titleHeight: number, statusInset: number, dark: boolean,
    level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE,
    pinned: boolean = false, mode: string = 'adaptive'): TitleBarStyleOptions {
    return {
      // 系统默认 ADAPTIVE 允许动态改变模糊；固定启用，滚动速度不改变材质。
      blurStrategy: BlurStrategy.ENABLE,
      scrollEffectOpts: {
        enableScrollEffect: true,
        enableRefreshOffsetChange: false,
        scrollEffectType: mode === 'off' ? ScrollEffectType.GRADIENT_BLUR : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(pinned ? 0 : Math.max(0, titleHeight - statusInset - StoreTopStyle.scrollDistance)),
        blurEffectiveEndOffset: LengthMetrics.vp(pinned ? StoreTopStyle.pinnedScrollDistance : Math.max(StoreTopStyle.scrollDistance, titleHeight - statusInset))
      },
      originalStyle: { backgroundStyle: { backgroundColor: Color.Transparent } },
      scrollEffectStyle: { backgroundStyle: {
        backgroundColor: Palette.forMode(dark).bg, blurRadius: 32, maskExtraHeight: StoreTopStyle.extraHeight
      } },
      systemMaterialEffect: {
        materialType: MaterialPreferences.type(mode),
        materialLevel: level
      }
    };
  }
}

/** Shared top glass: opaque at the status bar, fading into the scrolling content. */
@Component
export struct StoreTopFade {
  @Prop statusInset:number=0;
  @Prop extraHeight:number=0;
  @Prop fadeOpacity:number=1;
  @Prop darkSurface:boolean=false;
  @StorageProp('darkMode') private darkMode:boolean=false;
  build(){
    Stack(){
      // 模糊层与蒙版一起合成；放在外层背景上会留下未被渐隐的矩形底板。
      Column().width('100%').height('100%')
        .backgroundEffect({radius:32,saturation:1.1,brightness:1,
          color:'#80'+Palette.forMode(this.darkMode || this.darkSurface).bg.substring(1),policy:BlurStyleActivePolicy.ALWAYS_ACTIVE},
          {disableSystemAdaptation:true})
      Column().width('100%').height('100%').linearGradient({angle:180,colors:StoreTopStyle.fadeStops})
        .blendMode(BlendMode.DST_IN,BlendApplyType.OFFSCREEN)
    }.width('100%').height(this.statusInset+StoreTopStyle.height+this.extraHeight).opacity(this.fadeOpacity)
      .blendMode(BlendMode.SRC_OVER,BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}

/** 原生按钮提供按压与焦点反馈；符号、触摸区域和读屏名称始终一致。 */
@Component
export struct StoreIconButton {
  @Prop darkSurface: boolean = false;
  symbol: Resource = $r('sys.symbol.xmark');
  label: string = I18n.t('关闭');
  controlSize: number = 44;
  @Prop active: boolean = true;
  action: () => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.symbol).fontSize(18)
        .fontColor([Palette.forMode(this.darkMode || this.darkSurface).textSecondary])
    }.width(this.controlSize).height(this.controlSize)
      .backgroundColor(Palette.forMode(this.darkMode || this.darkSurface).fill)
      .responseRegion({ x: (this.controlSize - 44) / 2, y: (this.controlSize - 44) / 2, width: 44, height: 44 })
      .enabled(this.active).stateEffect(true)
      .accessibilityText(this.label)
      .onClick(() => this.action())
  }
}

/** Same native floating material as DiscoverTopAction, with an older-system glass fallback. */
@Component
export struct StoreImmersiveIconButton {
  @Prop darkSurface:boolean=false;
  @StorageProp('materialMode') @Watch('onPopupRequestChanged') private materialMode:string='adaptive';
  @StorageProp('routeTransitioning') @Watch('onPopupRequestChanged') private routeTransitioning:boolean=false;
  @StorageProp('windowWidth') @Watch('onViewportChanged') private windowWidth:number=0;
  @StorageProp('windowHeight') @Watch('onViewportChanged') private windowHeight:number=0;
  @Prop symbol:Resource=$r('sys.symbol.chevron_left');
  @Prop label:string=I18n.t('返回');
  title:string='';
  controlId:string='';
  action:()=>void=()=>{};
  backAction:()=>void=()=>{};
  @Prop @Watch('onPopupRequestChanged') visible:boolean=true;
  @Prop loading:boolean=false;
  @Prop active:boolean=true;
  @StorageProp('darkMode') private darkMode:boolean=false;
  @State private showing:boolean=false;
  @State private popupVisible:boolean=false;
  @State private anchorReady:boolean=true;
  private reopenTimer:number=-1;
  private retryAvailable:boolean=true;
  aboutToAppear():void{this.showing=true;this.retryAvailable=true;}
  aboutToDisappear():void{
    this.showing=false;this.popupVisible=false;
    if(this.reopenTimer!==-1)clearTimeout(this.reopenTimer);
    this.reopenTimer=-1;
  }
  private popupRequested():boolean{
    return this.showing&&this.visible&&!this.routeTransitioning&&this.anchorReady&&StoreMaterial.supported(this.materialMode);
  }
  private fallbackVisible():boolean{
    return this.showing&&this.visible&&!this.routeTransitioning&&
      (!StoreMaterial.supported(this.materialMode)||!this.popupVisible);
  }
  private onPopupRequestChanged():void{
    if(!this.popupRequested())this.popupVisible=false;
  }
  private reopenAfterLayout():void{
    this.popupVisible=false;this.anchorReady=false;
    if(this.reopenTimer!==-1)clearTimeout(this.reopenTimer);
    this.reopenTimer=setTimeout(()=>{
      this.reopenTimer=-1;
      if(this.showing)this.anchorReady=true;
    },32);
  }
  private onViewportChanged():void{
    // Rotation invalidates the system popup window even when its target survives.
    // Rebind after the new anchor is laid out; keep an inline button meanwhile.
    this.retryAvailable=true;
    if(this.showing&&StoreMaterial.supported(this.materialMode))this.reopenAfterLayout();
  }
  private onPopupStateChanged(visible:boolean):void{
    this.popupVisible=visible&&this.popupRequested();
    if(!visible&&this.popupRequested()&&this.retryAvailable){
      this.retryAvailable=false;
      this.reopenAfterLayout();
    }
  }
  private controlWidth():number{
    if(!this.title)return 44;
    // CJK glyphs are ~16vp at 16fp, Latin ~8.5vp. Counting every code unit as
    // 16 made English page titles 30-70% wider than their text.
    let cjk=0;
    for(let i=0;i<this.title.length;i++){
      const code=this.title.charCodeAt(i);
      if(code>=0x4e00&&code<=0x9fff)cjk++;
    }
    const latin=this.title.length-cjk;
    return Math.min(190,56+cjk*16+latin*8.5);
  }
  @Builder private content(){
    Button({type:this.title?ButtonType.Normal:ButtonType.Circle}){
      Row({space:6}){
        if(this.loading){LoadingProgress().width(22).height(22).color(Palette.forMode(this.darkMode || this.darkSurface).text);}
        else{SymbolGlyph(this.symbol).fontSize(18).fontColor([StoreMaterial.icon(this.darkMode || this.darkSurface,this.materialMode)]);}
        if(this.title){Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(StoreMaterial.foreground(this.darkMode || this.darkSurface,false,this.materialMode)).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis});}
      }.justifyContent(FlexAlign.Center)
    }.width(this.controlWidth()).height(44).borderRadius(22).padding({left:0,right:0})
      .backgroundColor(Color.Transparent).enabled(this.active&&!this.loading)
      .id(this.controlId).accessibilityText(this.loading?I18n.t('正在刷新应用信息'):this.label).onClick(()=>this.action())
  }
  build(){
    Stack(){
      if(this.fallbackVisible()){
        Stack(){this.content();}.width(this.controlWidth()).height(44).borderRadius(22)
          .backgroundBlurStyle(StoreMaterial.blurStyle(this.materialMode),{colorMode:this.darkMode || this.darkSurface?ThemeColorMode.DARK:ThemeColorMode.LIGHT})
          .backgroundColor(StoreMaterial.fallbackFill(this.darkMode || this.darkSurface))
          .border({width:0.5,color:Palette.forMode(this.darkMode || this.darkSurface).border,radius:22}).shadow(ShadowStyle.OUTER_DEFAULT_SM)
      }
      if(StoreMaterial.supported(this.materialMode)){
      Column(){}.width(this.controlWidth()).height(44).bindPopup(this.popupRequested(),{builder:this.content,width:this.controlWidth(),radius:22,
        placement:Placement.Bottom,targetSpace:0,offset:{x:0,y:-44},enableArrow:false,autoCancel:false,
        followTransformOfTarget:true,transition:TransitionEffect.IDENTITY,
        onStateChange:(event:PopupStateChangeParam)=>this.onPopupStateChanged(event.isVisible),
        onWillDismiss:(action:DismissPopupAction)=>{if(action.reason===DismissReason.PRESS_BACK)this.backAction();},
        focusable:false,mask:false,systemMaterial:StoreMaterial.glass(this.materialMode,this.darkMode || this.darkSurface)})
      }
    }.width(this.controlWidth()).height(44)
  }
}

/** 详情与本地工具共用：返回符号和标题处于同一块系统光感材质中。 */
@Component
export struct StorePageHeader {
  @StorageProp('windowWidth') private windowWidth:number=0;
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
        StoreImmersiveIconButton({title:this.title,label:I18n.t('返回 · ')+this.title,visible:this.visible,
          active:this.active,action:this.action,backAction:this.backAction})
        Blank().layoutWeight(1)
        this.tools()
      }.width('100%').constraintSize({maxWidth:StoreLayout.frameMaxWidth(this.windowWidth)})
        .height(this.statusInset+58).padding({left:StoreLayout.inset(this.windowWidth),right:StoreLayout.inset(this.windowWidth),top:this.statusInset+6,bottom:8})
    }.width('100%').height(this.statusInset+58)
  }
}

/** The detail action and selected capsules share the same native tinted material. */
export function storeTintedImmersiveMaterial(tint: string, strength: number = 1,
  applyShadow: boolean = true, mode: string = 'adaptive'): uiMaterial.ImmersiveMaterial {
  return StoreMaterial.tinted(mode, tint, strength, applyShadow);
}

/** 浮动主操作使用系统材质；低版本继续使用原有实色按钮。 */
@Component
export struct StoreImmersiveAction {
  @StorageProp('darkMode') private darkMode:boolean=false;
  @StorageProp('windowWidth') @Watch('onViewportChanged') private windowWidth:number=0;
  @StorageProp('windowHeight') @Watch('onViewportChanged') private windowHeight:number=0;
  @StorageProp('materialMode') @Watch('onPopupRequestChanged') private materialMode:string='adaptive';
  @StorageProp('routeTransitioning') @Watch('onPopupRequestChanged') private routeTransitioning:boolean=false;
  @Prop @Watch('onPopupRequestChanged') visible:boolean=true;
  @Prop @Watch('onPopupRequestChanged') suspendPopup:boolean=false;
  @Prop tint:string='#1F5DEF';
  @Prop controlHeight:number=52;
  @Prop controlWidth:number=0;
  @Prop controlRadius:number=18;
  @Prop moving:boolean=false;
  @Prop tintStrength:number=1;
  @Prop colored:boolean=true;
  @Prop contentDrawsFallback:boolean=false;
  @Prop glassInversion:boolean=true;
  @Prop followsTarget:boolean=false;
  @Prop anchorAtStart:boolean=false;
  @Prop embedded:boolean=false;
  @Prop viewportOffset:number=0;
  @State private placementCorrectionX:number=0;
  @State private placementCorrectionY:number=0;
  private anchorX:number=NaN;
  private anchorY:number=NaN;
  @Prop popupShadow:boolean=true;
  @Prop popupFocusable:boolean=false;
  backAction:()=>void=()=>{};
  @BuilderParam content:(immersive:boolean)=>void;
  @State @Watch('onPopupRequestChanged') private measuredWidth:number=0;
  @State private popupVisible:boolean=false;
  @State private anchorReady:boolean=true;
  private reopenTimer:number=-1;
  private retryAvailable:boolean=true;
  private disposed:boolean=false;
  private materialKey:string='';
  private materialCache:uiMaterial.ImmersiveMaterial|undefined;
  aboutToAppear():void{this.disposed=false;this.retryAvailable=true;}
  aboutToDisappear():void{
    this.disposed=true;this.popupVisible=false;
    if(this.reopenTimer!==-1)clearTimeout(this.reopenTimer);
    this.reopenTimer=-1;
  }
  private canUseMaterial():boolean{
    return StoreMaterial.supported(this.materialMode);
  }
  private popupWidth():number{return this.controlWidth>0?this.controlWidth:this.measuredWidth;}
  private popupRequested():boolean{return !this.disposed&&this.anchorReady&&this.canUseMaterial()&&this.visible&&!this.suspendPopup&&
    !this.routeTransitioning&&this.popupWidth()>0.5;}
  private onPopupRequestChanged():void{if(!this.popupRequested())this.popupVisible=false;}
  private reopenAfterLayout():void{
    this.popupVisible=false;this.anchorReady=false;
    if(this.reopenTimer!==-1)clearTimeout(this.reopenTimer);
    this.reopenTimer=setTimeout(()=>{
      this.reopenTimer=-1;
      if(!this.disposed)this.anchorReady=true;
    },32);
  }
  private onViewportChanged():void{
    this.retryAvailable=true;
    this.placementCorrectionX=0;this.placementCorrectionY=0;
    this.anchorX=NaN;this.anchorY=NaN;
    if(!this.disposed&&this.canUseMaterial())this.reopenAfterLayout();
  }
  private onPopupStateChanged(visible:boolean):void{
    this.popupVisible=visible&&this.popupRequested();
    if(!visible&&this.popupRequested()&&this.retryAvailable){
      this.retryAvailable=false;
      this.reopenAfterLayout();
    }
  }
  private fallbackVisible():boolean{
    return !this.disposed&&this.visible&&!this.routeTransitioning&&(!this.canUseMaterial()||!this.popupVisible);
  }
  private actionMaterial():uiMaterial.ImmersiveMaterial{
    // Geometry is animated every frame. Keep the native effect object stable until its appearance changes.
    const key=JSON.stringify([this.materialMode,this.colored,this.tint,this.tintStrength,this.popupShadow,this.glassInversion]);
    if(this.materialCache&&this.materialKey===key)return this.materialCache;
    // Fixed-color content needs clear glass without changing the native inversion mode during a morph.
    const material=this.colored||!this.glassInversion?
      storeTintedImmersiveMaterial(this.tint,this.colored?this.tintStrength:0,this.popupShadow,this.materialMode):
      StoreMaterial.glass(this.materialMode,false,false,this.tint);
    this.materialKey=key;this.materialCache=material;return material;
  }
  // Keep the native bubble at its full size; only its NavDestination clips it.
  // Measure and cancel the system's placement inset, rather than hard-code a device margin.
  private correctEmbeddedPlacement(area:Area):void{
    if(!this.embedded||this.moving||!this.popupRequested()||!Number.isFinite(this.anchorX)||!Number.isFinite(this.anchorY))return;
    // A morph supplies its exact dimensions. Ignore an area report from the previous sample.
    if(this.controlWidth>0&&(!Number.isFinite(Number(area.width))||!Number.isFinite(Number(area.height))||
      Math.abs(Number(area.width)-this.controlWidth)>0.5||Math.abs(Number(area.height)-this.controlHeight)>0.5))return;
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
      if(this.fallbackVisible()){
        Stack(){this.content(false);}.width('100%').height(this.controlHeight).borderRadius(this.controlRadius)
          .backgroundColor(this.colored||this.contentDrawsFallback?Color.Transparent:StoreMaterial.fallbackFill(this.darkMode))
      }
      if(this.canUseMaterial()){
      Column(){}.width('100%').height(this.controlHeight)
        .onSizeChange((_old:SizeOptions,size:SizeOptions)=>{
          const width=Number(size.width);
          if(this.controlWidth<=0&&Number.isFinite(width)&&width>0)this.measuredWidth=width;
        })
      Column(){}.width(Math.max(0.5,this.popupWidth())).height(this.controlHeight).position({x:this.popupAnchorX(),y:0})
        .onAreaChange((_old:Area,area:Area)=>{
          this.anchorX=Number(area.globalPosition.x);this.anchorY=Number(area.globalPosition.y);
        })
        .bindPopup(this.popupRequested(),{builder:this.immersiveContent,width:this.popupWidth(),radius:this.controlRadius,
          // Header anchors open below themselves; the bottom install action retains its upward placement.
          placement:this.anchorAtStart?Placement.BottomLeft:Placement.Top,targetSpace:0,
          offset:this.popupOffset(),enableArrow:false,autoCancel:false,
          focusable:this.popupFocusable,mask:false,
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
