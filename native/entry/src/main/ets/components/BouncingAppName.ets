/** 长名称只移动超出可视宽度的距离，到边界后原路返回。 */
@Component
export struct BouncingAppName {
  @Prop @Watch('restart') title:string='';
  @Prop @Watch('restart') fontSize:number=17;
  @Prop @Watch('restart') viewportWidth:number=0;
  @Prop @Watch('restart') textWidth:number=0;
  @Prop color:string='#17213A';
  @State @Watch('restart') private visible:boolean=false;
  @State private titleOffset:number=0;
  private timer:number=-1;
  private epoch:number=0;
  private disposed:boolean=false;

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
    this.getUIContext().animateTo({duration:0},()=>{this.titleOffset=0;});
    if(!this.visible||this.viewportWidth<=0||this.textWidth-this.viewportWidth<=1)return;
    const token=this.epoch;
    this.timer=setTimeout(()=>{this.timer=-1;this.advance(token,true);},1100);
  }

  private advance(token:number,toEnd:boolean):void {
    if(this.disposed||!this.visible||token!==this.epoch)return;
    const distance=Math.max(0,this.textWidth-this.viewportWidth);
    if(distance<=1)return;
    this.getUIContext().animateTo({duration:Math.max(240,Math.round(distance/32*1000)),curve:Curve.Linear,
      onFinish:()=>{
        if(this.disposed||!this.visible||token!==this.epoch)return;
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
