import { DevicePanelInk } from './DevicePanelInk';
/** One device silhouette family for the spatial map, floating orb and target list. */
@Component
export struct DeviceGlyph {
  @StorageProp('materialMode') private materialMode:string='adaptive';
  @Prop kind:string='phone';
  @StorageProp('darkMode') private darkMode:boolean=false;
  @Prop ink:ResourceColor=Color.White;
  @Prop adaptiveInk:boolean=false;
  @Prop glyphSize:number=28;
  private symbol():Resource{return this.kind==='multiple'?$r('sys.symbol.pad_and_iphone'):this.kind==='pc'||this.kind==='2in1'?$r('sys.symbol.computer'):this.kind==='tablet'?$r('sys.symbol.pad'):this.kind==='phone'?$r('sys.symbol.phone_1'):$r('sys.symbol.rectangle_on_rectangle');}
  build(){
    Stack({alignContent:Alignment.Center}){
      // Native symbols include their optical bounds; the former free-sized
      // Path lost the lower/right edges after viewport scaling on real devices.
      if(this.adaptiveInk){SymbolGlyph(this.symbol()).fontSize(this.glyphSize)
        .attributeModifier(DevicePanelInk.symbol(this.darkMode,this.materialMode)).renderingStrategy(SymbolRenderingStrategy.SINGLE)}
      else{SymbolGlyph(this.symbol()).fontSize(this.glyphSize).fontColor([this.ink]).renderingStrategy(SymbolRenderingStrategy.SINGLE)}
    }.width(this.glyphSize).height(this.glyphSize).hitTestBehavior(HitTestMode.None)
  }
}
