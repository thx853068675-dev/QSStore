import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { DeviceArtworkFrame } from '../data/DeviceArtworkFrame';
import { DeviceArtwork } from '../data/DeviceArtwork';
import { common } from '@kit.AbilityKit';
import { DevicePortrait } from './DevicePortrait';
import { MultiDeviceTargets } from '../jobs/MultiDeviceTargets';
import { DeviceStackLayout } from '../data/DeviceStackLayout';

function artworkFrame(x:number,y:number,width:number,height:number,contentWidth:number,contentHeight:number):DeviceArtworkFrame{
  const frame=new DeviceArtworkFrame();frame.x=x;frame.y=y;frame.width=width;frame.height=height;
  frame.contentWidth=contentWidth;frame.contentHeight=contentHeight;return frame;
}
const PHONE_FRAME=artworkFrame(.056958,-.063766,.886085,1.125187,.820449,.94);
const TABLET_FRAME=artworkFrame(-.019474,-.161023,1.038947,1.319298,.94,.640409);
const PC_FRAME=artworkFrame(-.080228,-.236384,1.157394,1.469707,.94,.535831);

/** One to three selected device photos, fitted to their combined visible silhouette. */
@Component
export struct DeviceStackPortrait {
  @Prop glyphSize:number=44;
  @StorageProp('deviceMultiEnabled') @Watch('syncDevices') private multiEnabled:boolean=false;
  @StorageProp('installTargetCount') @Watch('syncDevices') private count:number=1;
  @State private devices:DeviceInstallTarget[]=[new DeviceInstallTarget()];
  @State private frames:DeviceArtworkFrame[]=[PHONE_FRAME];
  private subscription:number=-1;
  private alive:boolean=false;
  private selectionKey:string='';
  aboutToAppear():void{this.alive=true;this.subscription=MultiDeviceTargets.subscribe(()=>this.syncDevices());this.syncDevices();}
  aboutToDisappear():void{this.alive=false;MultiDeviceTargets.unsubscribe(this.subscription);}
  private syncDevices():void{
    if(!this.alive)return;
    const rows=DeviceStackLayout.targets(this.multiEnabled?MultiDeviceTargets.selection:[new DeviceInstallTarget()]);
    const key=JSON.stringify(rows.map((row)=>[row.key,row.kind,row.model,row.marketName]));if(key===this.selectionKey)return;
    this.selectionKey=key;
    const context=getContext(this) as common.UIAbilityContext;
    this.frames=rows.map((row)=>DeviceArtwork.cached(context,row.kind,row.model,row.marketName||row.name)?.frame??this.frame(row.kind));
    this.devices=rows;
  }
  private visibleFrame(key:string,frame:DeviceArtworkFrame):void{
    if(!this.alive)return;const index=this.devices.findIndex((row)=>row.key===key);if(index<0)return;
    const old=this.frames[index];if(old&&Math.abs(old.contentWidth-frame.contentWidth)<.0001&&Math.abs(old.contentHeight-frame.contentHeight)<.0001)return;
    const next=this.frames.slice();next[index]=frame;this.frames=next;
  }
  private layout():DeviceStackLayout{return new DeviceStackLayout(this.frames);}
  private frame(kind:string):DeviceArtworkFrame{return kind==='pc'?PC_FRAME:kind==='tablet'?TABLET_FRAME:PHONE_FRAME;}
  build(){
    Stack({alignContent:Alignment.TopStart}){
      ForEach(this.devices,(row:DeviceInstallTarget,index:number)=>{
        DevicePortrait({kind:row.kind,model:row.model,marketName:row.marketName||row.name,
          pictureSize:this.glyphSize*this.layout().layers[index].size,
          adaptiveInk:true,glyphSize:Math.min(28,this.glyphSize*this.layout().layers[index].size*.7),fallbackFrame:this.frame(row.kind),
          onFrameChanged:(frame)=>this.visibleFrame(row.key,frame)})
          .position({x:this.glyphSize*this.layout().layers[index].x,y:this.glyphSize*this.layout().layers[index].y})
          .opacity(index===this.devices.length-1?1:.86)
      },(row:DeviceInstallTarget)=>row.key+'|'+row.kind+'|'+row.model+'|'+row.marketName)
    }.width(this.glyphSize).height(this.glyphSize).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
