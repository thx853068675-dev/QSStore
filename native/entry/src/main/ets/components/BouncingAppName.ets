/** 长名称只移动超出可视宽度的距离，到边界后原路返回。 */
@Component
export struct BouncingAppName {
  @StorageProp('routeTransitioning') @Watch('updateActivity') private routeTransitioning:boolean=false;
  @Prop @Watch('restart') title:string='';
  @Prop @Watch('restart') fontSize:number=17;
  @Prop @Watch('restart') viewportWidth:number=0;
  @Prop @Watch('restart') textWidth:number=0;
  @Prop color:string='#17213A';
  @Prop @Watch('updateActivity') active:boolean=true;
  @State @Watch('updateActivity') private visible:boolean=false;
  @State private titleOffset:number=0;
  private timer:number=-1;
  private epoch:number=0;
  private disposed:boolean=false;
  private moving:boolean=false;
  private motionFrom:number=0;
  private motionTo:number=0;
  private motionAt:number=0;
  private motionDuration:number=0;
  private nextToEnd:boolean=true;

  aboutToDisappear():void{this.disposed=true;this.halt();}

  private halt():void {
    this.epoch++;
    if(this.timer!==-1)clearTimeout(this.timer);
    this.timer=-1;
  }

  private restart():void {
    this.halt();
    if(this.disposed)return;
    // duration=0 同时结束旧的位移动画，避免滚出屏幕后继续消耗绘制资源。
    if(this.moving||this.titleOffset!==0){
      this.getUIContext().animateTo({duration:0},()=>{this.titleOffset=0;});
      this.moving=false;
    }
    this.nextToEnd=true;
    if(this.routeTransitioning||!this.active||!this.visible||this.viewportWidth<=0||this.textWidth-this.viewportWidth<=1)return;
    const token=this.epoch;
    this.timer=setTimeout(()=>{this.timer=-1;this.advance(token,true);},1100);
  }

  private updateActivity():void {
    this.halt();
    if(this.disposed)return;
    if(this.moving){
      // Linear movement can be frozen once from its elapsed time, without a per-frame JS callback.
      const progress=Math.min(1,Math.max(0,(Date.now()-this.motionAt)/Math.max(1,this.motionDuration)));
      const offset=this.motionFrom+(this.motionTo-this.motionFrom)*progress;
      this.getUIContext().animateTo({duration:0},()=>{this.titleOffset=offset;});
      this.moving=false;
    }
    if(this.routeTransitioning||!this.active||!this.visible||this.viewportWidth<=0||this.textWidth-this.viewportWidth<=1)return;
    const token=this.epoch;
    this.timer=setTimeout(()=>{this.timer=-1;this.advance(token,this.nextToEnd);},1100);
  }

  private advance(token:number,toEnd:boolean):void {
    if(this.disposed||this.routeTransitioning||!this.active||!this.visible||token!==this.epoch)return;
    const distance=Math.max(0,this.textWidth-this.viewportWidth);
    if(distance<=1)return;
    this.moving=true;
    this.nextToEnd=toEnd;
    this.motionFrom=this.titleOffset;this.motionTo=toEnd?-distance:0;
    this.motionAt=Date.now();
    this.motionDuration=Math.max(240,Math.round(Math.abs(this.motionTo-this.motionFrom)/32*1000));
    this.getUIContext().animateTo({duration:this.motionDuration,curve:Curve.Linear,
      onFinish:()=>{
        if(this.disposed||this.routeTransitioning||!this.active||!this.visible||token!==this.epoch)return;
        this.moving=false;
        this.nextToEnd=!toEnd;
        this.timer=setTimeout(()=>{this.timer=-1;this.advance(token,!toEnd);},1100);
      }},()=>{this.titleOffset=toEnd?-distance:0;});
  }

  build(){
    Stack({alignContent:Alignment.Start}){
      Text(this.title).fontSize(this.fontSize).fontWeight(FontWeight.Bold).fontColor(this.color)
        .maxLines(1).width(this.textWidth).flexShrink(0).translate({x:this.titleOffset})
    }.width(this.viewportWidth).clip(true).accessibilityText(this.title)
      .onVisibleAreaChange([0,0.5],(visible:boolean,ratio:number)=>{this.visible=visible&&ratio>=0.5;})
  }
}
