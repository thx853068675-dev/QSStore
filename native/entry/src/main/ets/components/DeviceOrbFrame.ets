/** One geometry sample drives the native material, its contents and its touch target. */
export class DeviceOrbFrame {
  x:number;
  y:number;
  width:number;
  height:number;
  radius:number;
  iconOpacity:number;
  edgeProgress:number;
  constructor(x:number=0,y:number=0,width:number=52,height:number=52,radius:number=26,iconOpacity:number=1,edgeProgress:number=0){
    this.x=x;this.y=y;this.width=width;this.height=height;this.radius=radius;this.iconOpacity=iconOpacity;
    this.edgeProgress=edgeProgress;
  }
  static between(from:DeviceOrbFrame,to:DeviceOrbFrame,progress:number):DeviceOrbFrame{
    const width=Math.max(4,from.width+(to.width-from.width)*progress);
    const height=Math.max(32,from.height+(to.height-from.height)*progress);
    const centerX=from.x+from.width/2+(to.x+to.width/2-from.x-from.width/2)*progress;
    const centerY=from.y+from.height/2+(to.y+to.height/2-from.y-from.height/2)*progress;
    const radius=Math.max(2,Math.min(width/2,height/2,from.radius+(to.radius-from.radius)*progress));
    return new DeviceOrbFrame(centerX-width/2,centerY-height/2,width,height,radius,
      Math.max(0,Math.min(1,from.iconOpacity+(to.iconOpacity-from.iconOpacity)*progress)),
      Math.max(0,Math.min(1,from.edgeProgress+(to.edgeProgress-from.edgeProgress)*progress)));
  }
}
