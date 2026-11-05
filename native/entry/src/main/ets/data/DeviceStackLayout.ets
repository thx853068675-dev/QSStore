import { DeviceArtworkFrame } from './DeviceArtworkFrame';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';

export class DeviceStackLayer {
  x:number; y:number; size:number;
  constructor(x:number,y:number,size:number){this.x=x;this.y=y;this.size=size;}
}
/** Center the visible union, rather than the transparent image boxes. */
export class DeviceStackLayout {
  layers:DeviceStackLayer[]=[];
  static targets(rows:DeviceInstallTarget[]):DeviceInstallTarget[]{
    const unique=rows.filter((row,index)=>rows.findIndex((other)=>other.key===row.key)===index);
    const front=unique.find((row)=>row.key==='local')||unique[0]||new DeviceInstallTarget();
    return [...unique.filter((row)=>row.key!==front.key).slice(0,2).reverse(),front];
  }
  constructor(frames:DeviceArtworkFrame[]){
    const count=Math.min(3,frames.length);if(!count)return;
    const raw=count===1?[new DeviceStackLayer(0,0,1)]:count===2?
      [new DeviceStackLayer(0,0,.86),new DeviceStackLayer(.14,.14,.86)]:
      [new DeviceStackLayer(0,0,.84),new DeviceStackLayer(.08,.1,.82),new DeviceStackLayer(.24,.24,.76)];
    let left=Infinity,top=Infinity,right=-Infinity,bottom=-Infinity;
    raw.forEach((layer,index)=>{
      const frame=frames[index],w=Number.isFinite(frame.contentWidth)&&frame.contentWidth>0?frame.contentWidth:1;
      const h=Number.isFinite(frame.contentHeight)&&frame.contentHeight>0?frame.contentHeight:1;
      left=Math.min(left,layer.x+layer.size*(1-w)/2);right=Math.max(right,layer.x+layer.size*(1+w)/2);
      top=Math.min(top,layer.y+layer.size*(1-h)/2);bottom=Math.max(bottom,layer.y+layer.size*(1+h)/2);
    });
    const scale=.94/Math.max(right-left,bottom-top),cx=(left+right)/2,cy=(top+bottom)/2;
    this.layers=raw.map((layer)=>new DeviceStackLayer(.5+(layer.x-cx)*scale,.5+(layer.y-cy)*scale,layer.size*scale));
  }
}
