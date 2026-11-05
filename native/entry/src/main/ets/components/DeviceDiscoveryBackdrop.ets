import { Palette } from '../theme/Palette';
import { StoreMaterial } from '../theme/StoreMaterial';

/** A quiet coordinate field, painted only on resize or theme changes. */
@Component
export struct DeviceDiscoveryBackdrop {
  @StorageProp('materialMode') @Watch('draw') private materialMode:string='adaptive';
  @StorageProp('darkMode') @Watch('draw') private dark:boolean=false;
  private ready:boolean=false;
  private settings:RenderingContextSettings=new RenderingContextSettings(true);
  private context:CanvasRenderingContext2D=new CanvasRenderingContext2D(this.settings);
  private draw():void{
    if(!this.ready)return;
    const ctx=this.context,w=ctx.width,h=ctx.height,step=18;
    // White dots are inverted by the native compositor against the actual
    // glass backdrop. Geometry and edge fade stay cached; no pixel sampling.
    ctx.clearRect(0,0,w,h);ctx.fillStyle=StoreMaterial.supported(this.materialMode)?'#FFFFFF':Palette.forMode(this.dark).text;
    for(let y=h/2%step;y<h;y+=step){
      for(let x=w/2%step;x<w;x+=step){
        const distance=Math.min(x,w-x,y,h-y),edge=Math.max(0,Math.min(1,distance/72));
        const fade=edge*edge*(3-2*edge);
        ctx.globalAlpha=(this.dark?.20:.15)*fade;
        ctx.beginPath();ctx.arc(x,y,.9,0,Math.PI*2);ctx.fill();
      }
    }
    ctx.globalAlpha=1;
  }
  build(){
    Canvas(this.context).width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .blendMode(StoreMaterial.supported(this.materialMode)?BlendMode.DIFFERENCE:BlendMode.SRC_OVER,BlendApplyType.FAST)
      .accessibilityLevel('no-hide-descendants')
      .onReady(()=>{this.ready=true;this.draw();}).onSizeChange(()=>this.draw())
  }
}
