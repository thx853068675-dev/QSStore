import { StoreImmersiveAction } from '../theme/StoreDesign';
import { Palette } from '../theme/Palette';
import { DevicePortrait } from './DevicePortrait';
import { DevicePanelMaterial } from './DevicePanelMaterial';
import { DevicePanelInk } from './DevicePanelInk';

@Component
export struct DeviceGlassCircle {
  @StorageProp('darkMode') private darkMode:boolean=false;
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @Prop inline:boolean=false;
  @Prop selected:boolean=false;
  @Prop diameter:number=64;
  @Prop visible:boolean=true;
  @Prop loading:boolean=false;
  @Prop repeatWhileLoading:boolean=false;
  @Prop destructive:boolean=false;
  @State private inView:boolean=false;
  @Prop symbol:Resource=$r('sys.symbol.phone_1');
  @Prop text:string='';
  @Prop deviceKind:string='';
  @Prop model:string='';
  @Prop marketName:string='';
  controlId:string='';
  @Prop label:string='';
  @Prop caption:string='';
  @Prop dragEnabled:boolean=false;
  dragStart:()=>void=()=>{};
  dragUpdate:(x:number,y:number)=>void=()=>{};
  dragEnd:()=>void=()=>{};
  private touchX:number=0;
  private touchY:number=0;
  private touchMoved:boolean=false;
  private materialKey:string='';
  private materialValue:DevicePanelMaterial|undefined;
  private inlineMaterial():DevicePanelMaterial{
    const key=this.materialMode+':'+this.darkMode+':'+this.selected;
    if(this.materialKey!==key||!this.materialValue){this.materialKey=key;this.materialValue=new DevicePanelMaterial(this.materialMode,this.darkMode,this.selected);}
    return this.materialValue;
  }
  private dragTouch(event:TouchEvent):void{
    if(!this.dragEnabled)return;
    event.stopPropagation();
    const point=event.touches[0]??event.changedTouches[0];
    if(event.type===TouchType.Down&&point){this.touchX=point.screenX;this.touchY=point.screenY;this.touchMoved=false;}
    else if(event.type===TouchType.Move&&point){
      const x=point.screenX-this.touchX,y=point.screenY-this.touchY;
      if(!this.touchMoved&&Math.abs(x)+Math.abs(y)>8){this.touchMoved=true;this.dragStart();}
      if(this.touchMoved)this.dragUpdate(x,y);
    }else if((event.type===TouchType.Up||event.type===TouchType.Cancel)&&this.touchMoved)this.dragEnd();
  }
  action:()=>void=()=>{};
  backAction:()=>void=()=>{};
  build():void{
    if(this.deviceKind){
      // Product silhouettes have their own shape; do not surround them with a glass disc.
      this.circleContent(false)
    }else if(this.inline){
      Stack(){
        Toggle({type:ToggleType.Button,isOn:false}){this.circleContent(true)}.width(this.diameter).height(this.diameter).padding(0)
          .borderRadius(this.diameter/2).attributeModifier(this.inlineMaterial())
          .focusable(false).accessibilityLevel('no')
      }.width(this.diameter).height(this.diameter)
    }else{
    StoreImmersiveAction({controlHeight:this.diameter,controlRadius:this.diameter/2,colored:this.selected,
      tint:Palette.forMode(this.darkMode).accent,tintStrength:1,visible:this.visible&&this.inView,
      embedded:true,followsTarget:true,popupShadow:true,backAction:this.backAction,
      content:(immersive:boolean)=>this.circleContent(immersive)}).width(this.diameter).height(this.diameter)
      .onVisibleAreaChange([0,.1],(visible:boolean)=>{this.inView=visible;})
    }
  }
  private ink():ResourceColor{return this.destructive?Palette.forMode(this.darkMode).danger:this.selected&&!this.deviceKind?Palette.forMode(this.darkMode).onAccent:DevicePanelInk.icon(this.darkMode,this.materialMode);}
  private adaptiveInkColor():ResourceColor|ColoringStrategy{return this.destructive||this.selected&&!this.deviceKind?this.ink():DevicePanelInk.contrast(this.darkMode,false,this.materialMode);}
  private pictureSize():number{return this.diameter*(this.caption?.70:.94);}
  @Builder private deviceIcon(){
    Stack({alignContent:Alignment.BottomEnd}){
      DevicePortrait({kind:this.deviceKind,model:this.model,marketName:this.marketName,ink:this.ink(),adaptiveInk:true,
        glyphSize:Math.min(28,this.diameter*.44),pictureSize:this.pictureSize()})
      if(this.loading){
        LoadingProgress().width(15).height(15).color(DevicePanelInk.icon(this.darkMode,this.materialMode))
          .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
      }else if(this.selected){
        Stack(){
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.diameter<44?7:9).fontWeight(FontWeight.Bold).fontColor([Color.White])
        }.width(this.diameter<44?11:15).height(this.diameter<44?11:15).backgroundColor(Palette.forMode(this.darkMode).accent)
          .border({width:1.5,color:Palette.forMode(this.darkMode).surface,radius:8}).borderRadius(8)
          .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
      }
    }.width(this.pictureSize()).height(this.pictureSize())
  }
  @Builder private circleContent(immersive:boolean):void{
    Button({type:this.deviceKind?ButtonType.Normal:ButtonType.Circle}){
      Column({space:4}){
        if(this.deviceKind){this.deviceIcon()}
        else if(this.loading){LoadingProgress().width(Math.min(26,this.diameter*.44)).height(Math.min(26,this.diameter*.44)).color(this.ink())}
        else if(this.text){Text(this.text).fontSize(12).fontWeight(FontWeight.Medium).foregroundColor(this.adaptiveInkColor())}
        else if(this.destructive||this.selected){SymbolGlyph(this.symbol).fontSize(Math.min(28,this.diameter*.44)).fontColor([this.ink()])}
        else{SymbolGlyph(this.symbol).fontSize(Math.min(28,this.diameter*.44)).attributeModifier(DevicePanelInk.symbol(this.darkMode,this.materialMode))}
        if(this.caption){Text(this.caption).fontSize(11).foregroundColor(this.selected&&!this.deviceKind?Palette.forMode(this.darkMode).onAccent:DevicePanelInk.contrast(this.darkMode,false,this.materialMode))}
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }.width(this.diameter).height(this.diameter).backgroundColor(!this.deviceKind&&!immersive&&this.selected?Palette.forMode(this.darkMode).accent:Color.Transparent)
      .border({width:this.deviceKind||immersive?0:1,color:Palette.forMode(this.darkMode).border,radius:this.deviceKind?0:this.diameter/2}).padding(0).stateEffect(!this.deviceKind)
      .onTouch((event:TouchEvent)=>this.dragTouch(event))
      .id(this.controlId).enabled(this.visible&&(!this.loading||this.repeatWhileLoading)).accessibilityText(this.label).onClick(()=>{if(!this.dragEnabled||!this.touchMoved)this.action();})
  }
}
