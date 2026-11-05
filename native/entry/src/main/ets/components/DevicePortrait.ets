import { common } from '@kit.AbilityKit';
import { DeviceArtwork } from '../data/DeviceArtwork';
import { DeviceGlyph } from './DeviceGlyph';
import { DeviceArtworkFrame } from '../data/DeviceArtworkFrame';

/** Keeps geometry and the immersive surface stable while the transparent product image loads. */
@Component
export struct DevicePortrait {
  @Prop @Watch('reload') kind:string='phone';
  @Prop @Watch('reload') model:string='';
  @Prop @Watch('reload') marketName:string='';
  @Prop ink:ResourceColor=Color.White;
  @Prop adaptiveInk:boolean=false;
  @Prop glyphSize:number=28;
  @Prop pictureSize:number=40;
  @Prop fallbackFrame:DeviceArtworkFrame=new DeviceArtworkFrame();
  onFrameChanged:(frame:DeviceArtworkFrame)=>void=()=>{};
  @State private source:string='';
  @State private frame:DeviceArtworkFrame=new DeviceArtworkFrame();
  private alive:boolean=false;
  private generation:number=0;
  private timer:number=-1;
  aboutToAppear():void{this.alive=true;this.reload();}
  aboutToDisappear():void{this.alive=false;this.generation++;if(this.timer!==-1)clearTimeout(this.timer);}
  private reload():void{
    this.generation++;if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;
    if(!this.alive||this.kind==='multiple'||(!this.model&&!this.marketName)){this.source='';return;}
    const context=getContext(this) as common.UIAbilityContext;
    const cached=DeviceArtwork.cached(context,this.kind,this.model,this.marketName);
    if(cached){this.frame=cached.frame;this.source=cached.source;this.onFrameChanged(cached.frame);return;}
    this.source='';
    this.onFrameChanged(this.fallbackFrame);
    const generation=this.generation;
    // Let the surface morph finish first; product art is never on the connection's critical path.
    this.timer=setTimeout(()=>{
      this.timer=-1;
      DeviceArtwork.portrait(context,this.kind,this.model,this.marketName).then((portrait)=>{
        if(portrait&&this.alive&&generation===this.generation){this.frame=portrait.frame;this.source=portrait.source;this.onFrameChanged(portrait.frame);}
      });
    },450);
  }
  @Builder private photo(source:ResourceStr,frame:DeviceArtworkFrame){
    Image(source).width(this.pictureSize*frame.width).height(this.pictureSize*frame.height).objectFit(ImageFit.Contain)
      .position({x:this.pictureSize*frame.x,y:this.pictureSize*frame.y})
      .onError(()=>{if(this.source===source){DeviceArtwork.invalidate(this.source);this.source='';this.onFrameChanged(this.fallbackFrame);}}).accessibilityLevel('no')
  }
  build(){
    Stack({alignContent:Alignment.Center}){
      if(this.source){this.photo(this.source,this.frame)}
      else{DeviceGlyph({kind:this.kind,ink:this.ink,adaptiveInk:this.adaptiveInk,glyphSize:this.glyphSize})}
    }.width(this.pictureSize).height(this.pictureSize).clip(true).hitTestBehavior(HitTestMode.None)
  }
}
