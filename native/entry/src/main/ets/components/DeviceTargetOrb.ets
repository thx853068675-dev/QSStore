import { DeviceOrbGestureGuard } from '../jobs/DeviceOrbGestureGuard';
import { common } from '@kit.AbilityKit';
import { curves, uiObserver } from '@kit.ArkUI';
import { MultiDeviceTargets } from '../jobs/MultiDeviceTargets';
import { DeviceOrbPreferences } from '../data/DeviceOrbPreferences';
import { DeviceStackPortrait } from './DeviceStackPortrait';
import { Palette } from '../theme/Palette';
import { DeviceOrbMaterial } from './DeviceOrbMaterial';
import { DeviceOrbFrame } from './DeviceOrbFrame';
import { DeviceDiscoveryContent } from './DeviceDiscoveryContent';
import { StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

export class DeviceOrbOptions {
  context:common.UIAbilityContext;
  modal:boolean=false;
  modalChanged:(modal:boolean)=>void=()=>{};
  constructor(context:common.UIAbilityContext){this.context=context;}
}

@Component
export struct DeviceTargetOrb {
  context:common.UIAbilityContext|undefined=undefined;
  modalChanged:(modal:boolean)=>void=()=>{};
  @StorageProp('darkMode') private dark:boolean=false;
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @StorageProp('deviceMultiEnabled') @Watch('onAvailabilityChanged') private multiEnabled:boolean=false;
  @StorageProp('deviceDiscoveryVisible') @Watch('onAvailabilityChanged') private discovering:boolean=false;
  @StorageProp('installTargetCount') private count:number=1;
  @StorageProp('installTargetName') private targetName:string='';
  @StorageProp('windowWidth') @Watch('onWindowChanged') private windowWidth:number=360;
  @StorageProp('windowHeight') @Watch('onWindowChanged') private windowHeight:number=780;
  @StorageProp('statusBarInset') @Watch('onWindowChanged') private topInset:number=32;
  @StorageProp('navigationBottomInset') @Watch('onWindowChanged') private bottomInset:number=24;
  @StorageProp('deviceOrbForeground') @Watch('onForegroundChanged') private foreground:boolean=true;
  @StorageLink('deviceOrbY') private yRatio:number=.64;
  @StorageLink('deviceOrbRight') private right:boolean=true;
  @StorageLink('deviceOrbOpened') @Watch('onOpenedChanged') private opened:boolean=false;
  @State private expanded:boolean=false;
  @State private panelMaterial:boolean=false;
  @State private contentShown:boolean=false;
  @State private positionReady:boolean=false;
  @State private revision:number=0;
  @State @Watch('onPanelGeometryChanged') private requestedHeight:number=360;
  @State private dragging:boolean=false;
  @State private docked:boolean=false;
  @State private restingX:number=-1;
  @State private freeX:number=0;
  @State private paint:DeviceOrbFrame=new DeviceOrbFrame();
  @State private moving:boolean=false;
  private motionGeneration:number=0;
  private pendingDock:boolean=false;
  private subscription:number=-1;
  private revealTimer:number=-1;
  private observingScroll:boolean=false;
  private onPageScroll=(event:uiObserver.ScrollEventInfo):void=>{this.handleScroll(event);};
  private handleScroll(event:uiObserver.ScrollEventInfo):void{
    if(event.id?.startsWith('device-orb-')||event.id?.startsWith('multi-device-'))return;
    if(event.scrollEvent!==uiObserver.ScrollEventType.SCROLL_START)return;
    if(this.opened){this.collapseForScroll();return;}
    this.dock();
  }
  private collapseForScroll():void{
    if(!this.alive||!this.shown()||!this.foreground||!this.opened||this.dragging)return;
    // One gesture advances one shape. Keep the circle visible before a later
    // page scroll docks it; the existing spring owns both transitions.
    this.close();
  }
  private alive:boolean=false;
  private dragY:number=0;
  private dragX:number=0;
  private touchX:number=0;
  private touchY:number=0;
  private touchMoved:boolean=false;
  private hitLeft:number=NaN;
  private hitTop:number=NaN;
  private hitWidth:number=0;
  private hitHeight:number=0;
  private materialKey:string='';
  private materialStyle:DeviceOrbMaterial|undefined;
  private surfaceMaterial():DeviceOrbMaterial{
    const key=JSON.stringify([this.materialMode,this.dark]);
    if(this.materialStyle&&this.materialKey===key)return this.materialStyle;
    this.materialKey=key;this.materialStyle=new DeviceOrbMaterial(this.materialMode,this.dark);
    return this.materialStyle;
  }
  aboutToAppear():void{
    this.alive=true;
    try{this.getUIContext().getUIObserver().on('scrollEvent',this.onPageScroll);this.observingScroll=true;}catch(_){}
    this.subscription=MultiDeviceTargets.subscribe(()=>{this.revision++;});
    if(this.context){
      MultiDeviceTargets.load(this.context).catch(()=>{});
      DeviceOrbPreferences.load(this.context).then((position)=>{
        if(!this.alive)return;
        this.right=position.right;this.yRatio=position.ratio;this.paint=this.targetFrame();this.positionReady=true;
      });
    }else{this.paint=this.targetFrame();this.positionReady=true;}
  }
  aboutToDisappear():void{
    this.alive=false;this.clearReveal();this.cancelMotion();DeviceOrbGestureGuard.release();MultiDeviceTargets.unsubscribe(this.subscription);
    if(this.observingScroll)try{this.getUIContext().getUIObserver().off('scrollEvent',this.onPageScroll);}catch(_){}
    this.observingScroll=false;
  }
  private shown():boolean{return this.positionReady&&this.multiEnabled&&!this.discovering;}
  private top():number{return Math.max(12,this.topInset+8);}
  private orbBottom():number{return Math.max(this.top()+52,this.windowHeight-this.bottomInset-132);}
  private orbWidth():number{return this.docked&&!this.dragging?4:52;}
  private orbHeight():number{return this.docked&&!this.dragging?32:52;}
  private restX(value:number):number{return Math.max(8,Math.min(this.windowWidth-60,value));}
  private x():number{return this.dragging?this.freeX:this.docked?(this.right?this.windowWidth-7:3):this.restX(this.restingX>=0?this.restingX:this.right?this.windowWidth-64:12);}
  private y():number{return Math.max(this.top()+40,Math.min(this.orbBottom(),this.windowHeight*this.yRatio));}
  private panelWidth():number{return Math.max(0,this.windowWidth-StoreLayout.contentInset(this.windowWidth)*2);}
  private panelLimit():number{return Math.max(160,this.windowHeight-this.top()-this.bottomInset-24);}
  private panelHeight():number{return Math.min(this.panelLimit(),this.requestedHeight);}
  private surfaceX():number{return this.expanded?(this.windowWidth-this.panelWidth())/2:this.x();}
  private surfaceY():number{return this.expanded?Math.max(this.top(),Math.min(this.windowHeight-this.bottomInset-this.panelHeight()-12,this.y()+26-this.panelHeight()/2)):this.y()+(52-this.orbHeight())/2;}
  private targetFrame():DeviceOrbFrame{
    return new DeviceOrbFrame(this.surfaceX(),this.surfaceY(),this.expanded?this.panelWidth():this.orbWidth(),
      this.expanded?this.panelHeight():this.orbHeight(),this.expanded?28:this.docked&&!this.dragging?2:26,
      this.expanded||this.docked&&!this.dragging?0:1,!this.expanded&&this.docked&&!this.dragging?1:0);
  }
  private cancelMotion():void{this.motionGeneration++;this.moving=false;}
  private followDrag(frame:DeviceOrbFrame):DeviceOrbFrame{
    if(this.dragging){frame.x=this.freeX+26-frame.width/2;frame.y=this.y()+26-frame.height/2;}
    return frame;
  }
  private morph():void{
    const to=this.targetFrame();this.cancelMotion();
    if(!this.alive||!this.shown()||!this.foreground){this.paint=to;this.panelMaterial=this.expanded;return;}
    const generation=this.motionGeneration;this.moving=true;
    // ArkUI interpolates the painted geometry, opacity and radius. Only the
    // destination is committed on the UI thread; scrolling no longer competes
    // with a JS onFrame callback and state/layout update at every display tick.
    // Retargeting continues from ArkUI's current render values, not our last goal.
    this.getUIContext().animateTo({duration:460,curve:curves.interpolatingSpring(0,1,300,28),onFinish:()=>{
      if(!this.alive||generation!==this.motionGeneration)return;
      this.moving=false;
      // Keep the panel material stable until the shared closing morph finishes.
      this.panelMaterial=this.expanded;
      if(this.pendingDock&&!this.opened&&!this.dragging){this.pendingDock=false;this.dock();}

    }},()=>{this.paint=this.followDrag(to);});
  }
  private onWindowChanged():void{
    if(!this.alive||!this.positionReady)return;
    this.cancelMotion();this.pendingDock=false;this.paint=this.targetFrame();this.panelMaterial=this.expanded;
  }
  private onPanelGeometryChanged():void{if(this.alive&&this.positionReady&&this.expanded)this.morph();}
  private clearReveal():void{if(this.revealTimer!==-1){clearTimeout(this.revealTimer);this.revealTimer=-1;}}
  private dock():void{
    if(!this.alive||!this.shown()||!this.foreground||this.opened||this.dragging||this.docked)return;
    if(this.moving){this.pendingDock=true;return;}
    const right=this.x()+26>=this.windowWidth/2;
    this.right=right;this.docked=true;this.morph();
  }
  private onForegroundChanged():void{
    if(!this.foreground){this.cancelMotion();DeviceOrbGestureGuard.release();this.pendingDock=false;this.paint=this.targetFrame();this.panelMaterial=this.expanded;}

  }
  private onAvailabilityChanged():void{

    this.cancelMotion();this.pendingDock=false;
    if(!this.multiEnabled||this.discovering){DeviceOrbGestureGuard.release();this.opened=false;this.expanded=false;this.paint=this.targetFrame();this.panelMaterial=false;}
    else{this.docked=false;this.paint=this.targetFrame();this.panelMaterial=this.expanded;}
    this.modalChanged(this.opened&&this.multiEnabled&&!this.discovering);
  }
  private onOpenedChanged():void{
    this.modalChanged(this.opened&&this.multiEnabled&&!this.discovering);
    this.clearReveal();this.contentShown=false;this.pendingDock=false;
    this.expanded=this.opened;if(!this.opened)this.docked=false;
    if(this.opened)this.panelMaterial=true;
    this.morph();
    if(this.opened)this.revealTimer=setTimeout(()=>{
      this.revealTimer=-1;if(!this.alive||!this.opened)return;
      this.getUIContext().animateTo({duration:140,curve:Curve.EaseOut},()=>{this.contentShown=true;});
    },90);
  }
  private open():void{this.opened=true;}
  private close():void{this.opened=false;}
  private beginDrag():void{
    const center=this.paint.x+this.paint.width/2;
    this.close();this.dragY=this.y();this.dragX=Math.max(0,Math.min(this.windowWidth-52,center-26));this.freeX=this.dragX;
    this.dragging=true;this.docked=false;this.morph();
  }
  private moveDrag(x:number,y:number):void{
    this.yRatio=Math.max(0,Math.min(1,(this.dragY+y)/this.windowHeight));
    this.freeX=Math.max(0,Math.min(this.windowWidth-52,this.dragX+x));
    this.paint=this.followDrag(new DeviceOrbFrame(this.paint.x,this.paint.y,this.paint.width,this.paint.height,this.paint.radius,this.paint.iconOpacity,this.paint.edgeProgress));
  }
  private endDrag():void{
    this.right=this.freeX+26>=this.windowWidth/2;this.restingX=this.restX(this.freeX);
    this.dragging=false;this.docked=false;this.yRatio=this.y()/this.windowHeight;this.morph();
    if(this.context)DeviceOrbPreferences.save(this.context,this.right,this.yRatio).catch(()=>{});
  }
  private dragTouch(event:TouchEvent):void{
    event.stopPropagation();
    if(event.type===TouchType.Up||event.type===TouchType.Cancel)DeviceOrbGestureGuard.end(event.type===TouchType.Cancel);
    const point=event.touches[0]??event.changedTouches[0];
    if(event.type===TouchType.Down&&point){if(this.docked)DeviceOrbGestureGuard.begin();this.touchX=point.screenX;this.touchY=point.screenY;this.touchMoved=false;}
    else if(event.type===TouchType.Move&&point){
      const x=point.screenX-this.touchX,y=point.screenY-this.touchY;
      if(!this.touchMoved&&Math.abs(x)+Math.abs(y)>8){this.touchMoved=true;this.beginDrag();}
      if(this.touchMoved)this.moveDrag(x,y);
    }else if((event.type===TouchType.Up||event.type===TouchType.Cancel)&&this.touchMoved){this.endDrag();}
  }
  private rootTouch(event:TouchEvent):HitTestMode{
    if(event.type===TouchType.Down){
      const point=event.touches[0]??event.changedTouches[0];
      if(point&&this.shown()&&this.docked&&!this.opened&&point.screenX>=this.hitLeft&&point.screenX<=this.hitLeft+this.hitWidth&&point.screenY>=this.hitTop&&point.screenY<=this.hitTop+this.hitHeight)DeviceOrbGestureGuard.begin();
      else DeviceOrbGestureGuard.release();
    }
    return this.modalHitMode();
  }
  private modalHitMode():HitTestMode{
    return this.shown()&&this.opened?HitTestMode.Default:HitTestMode.Transparent;
  }
  @Builder private panel(){
    DeviceDiscoveryContent({active:this.expanded&&this.foreground,moving:this.moving,maxHeight:this.panelLimit(),
      onHeightChanged:(height:number)=>{if(Math.abs(height-this.requestedHeight)>1)this.requestedHeight=height;},
      onClose:()=>this.close()})
      .width(this.panelWidth()).height(this.panelHeight()).opacity(this.contentShown?1:0)
      .id('device-orb-panel').visibility(this.expanded?Visibility.Visible:Visibility.Hidden)
      .enabled(this.contentShown).accessibilityLevel(this.contentShown?'auto':'no-hide-descendants')
      .hitTestBehavior(this.contentShown?HitTestMode.Default:HitTestMode.None)
  }
  @Builder private surface(){
    Stack(){
      // Keep both contents mounted while the shared native surface changes shape.
      // Foreground resources must belong to the material subtree for system inversion.
      // Consume raw touch bubbling before it reaches Toggle's built-in pressed state.
      Toggle({type:ToggleType.Button,isOn:false}){
        Stack(){this.panel()}.width('100%').height('100%').borderRadius(this.paint.radius).clip(true)
          .onTouch((event:TouchEvent)=>event.stopPropagation())
      }.width(this.paint.width).height(this.paint.height).padding(0)
        .constraintSize({minWidth:0,minHeight:0}).borderRadius(this.paint.radius).selectedColor(Color.Transparent).hoverEffect(HoverEffect.None)
        .focusable(false).accessibilityLevel('no')
        .attributeModifier(this.surfaceMaterial())
        .opacity(this.panelMaterial?(1-this.paint.iconOpacity)*(1-this.paint.edgeProgress):0)
        .id('device-orb-material')
        .onGestureRecognizerJudgeBegin((_,recognizer:GestureRecognizer)=>recognizer.isBuiltIn()&&recognizer.getEventTargetInfo().getId()==='device-orb-material'?
          GestureJudgeResult.REJECT:GestureJudgeResult.CONTINUE)
      // Product photos stay mounted while the shared surface changes shape.
      Stack(){DeviceStackPortrait({glyphSize:44})}
        .width(52).height(52).align(Alignment.Center).opacity(this.paint.iconOpacity)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
    }.width(this.paint.width).height(this.paint.height)
  }
  build(){
    WithTheme({colorMode:this.dark?ThemeColorMode.DARK:ThemeColorMode.LIGHT}){
    Stack({alignContent:Alignment.TopStart}){
      if(this.revision>=0&&this.shown()){
        // A permanent, unpainted hit layer avoids inserting a full-window render node on each toggle.
        Column().width('100%').height('100%').hitTestBehavior(this.modalHitMode()===HitTestMode.Default?HitTestMode.Default:HitTestMode.None)
          .id('device-orb-dismiss')
          .onClick(()=>{if(this.opened)this.close();})
          .gesture(PanGesture({direction:PanDirection.Vertical,distance:12})
            .onActionStart(()=>this.collapseForScroll()))
        Stack(){
          this.surface()
          Column().width(4).height(32).borderRadius(2).backgroundColor(Palette.forMode(this.dark).accent)
            .id('device-orb-handle')
            .opacity(this.paint.edgeProgress).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
        }.width(this.paint.width).height(this.paint.height)
          .position({x:this.paint.x,y:this.paint.y})
          .id('device-orb-surface').onClick(()=>{})
        if(!this.expanded){
          // The slim handle keeps a full 44 × 64vp touch target inside the screen.
          Button({type:ButtonType.Normal}){}.width(this.docked&&!this.dragging?44:52).height(this.docked&&!this.dragging?64:52)
            .backgroundColor(Color.Transparent).padding(0).borderRadius(26)
            .position({x:this.docked?(this.right?this.windowWidth-44:0):this.paint.x+this.paint.width/2-26,
              y:this.paint.y+this.paint.height/2-(this.docked?32:26)})
            .id('global-device-orb').accessibilityText(I18n.t('切换安装设备，')+(this.count>1?this.count+I18n.t(' 台'):this.targetName||I18n.t('本机')))
            .onAreaChange((_old:Area,area:Area)=>{
              this.hitLeft=Number(area.globalPosition.x);this.hitTop=Number(area.globalPosition.y);
              this.hitWidth=Number(area.width);this.hitHeight=Number(area.height);
            })
            .monopolizeEvents(true).onTouchIntercept((event:TouchEvent)=>{
              if(event.type===TouchType.Down&&this.docked)DeviceOrbGestureGuard.begin();return HitTestMode.Default;
            })
            .onTouch((event:TouchEvent)=>this.dragTouch(event)).onClick(()=>{if(!this.touchMoved)this.open();})
        }
      }
    }.focusable(this.opened&&this.shown()).width('100%').height('100%').clip(true).hitTestBehavior(this.modalHitMode())
      .onTouchIntercept((event:TouchEvent)=>this.rootTouch(event))
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
    }
  }
}

@Builder export function deviceOrbBuilder(options:DeviceOrbOptions){
  DeviceTargetOrb({context:options.context,modalChanged:options.modalChanged}).focusable(options.modal)
    .hitTestBehavior(options.modal?HitTestMode.Default:HitTestMode.Transparent)
}
