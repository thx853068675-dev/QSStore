import { image } from '@kit.ImageKit';

/** Relative image frame fitted to its visible silhouette, rather than PNG padding. */
export class DeviceArtworkFrame {
  x:number=0; y:number=0; width:number=1; height:number=1;
  contentWidth:number=1; contentHeight:number=1;
  private static cache:Map<string,Promise<DeviceArtworkFrame>>=new Map();
  static fromRgba(bytes:Uint8Array,width:number,height:number):DeviceArtworkFrame{
    const frame=new DeviceArtworkFrame();
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>256||height>256||bytes.length!==width*height*4)return frame;
    let left=width,top=height,right=-1,bottom=-1;
    for(let y=0;y<height;y++)for(let x=0;x<width;x++){
      if(bytes[(y*width+x)*4+3]<32)continue;
      left=Math.min(left,x);top=Math.min(top,y);right=Math.max(right,x);bottom=Math.max(bottom,y);
    }
    if(right<left||bottom<top)return frame;
    const contentWidth=right-left+1,contentHeight=bottom-top+1;
    const scale=.94/Math.max(contentWidth,contentHeight);
    frame.width=width*scale;frame.height=height*scale;
    frame.x=(1-contentWidth*scale)/2-left*scale;
    frame.y=(1-contentHeight*scale)/2-top*scale;
    frame.contentWidth=contentWidth*scale;frame.contentHeight=contentHeight*scale;
    return frame;
  }
  static load(path:string):Promise<DeviceArtworkFrame>{
    const pending=DeviceArtworkFrame.cache.get(path);if(pending)return pending;
    const flight=DeviceArtworkFrame.read(path).catch(()=>new DeviceArtworkFrame());
    if(DeviceArtworkFrame.cache.size>=64)for(const key of DeviceArtworkFrame.cache.keys()){DeviceArtworkFrame.cache.delete(key);break;}
    DeviceArtworkFrame.cache.set(path,flight);return flight;
  }
  static clear():void{DeviceArtworkFrame.cache.clear();}
  private static async read(path:string):Promise<DeviceArtworkFrame>{
    const source=image.createImageSource(path.replace(/^file:\/\//,''));
    try{
      const info=await source.getImageInfo(),ratio=Math.min(1,256/Math.max(info.size.width,info.size.height));
      const pixels=await source.createPixelMap({desiredPixelFormat:image.PixelMapFormat.RGBA_8888,
        desiredSize:{width:Math.max(1,Math.round(info.size.width*ratio)),height:Math.max(1,Math.round(info.size.height*ratio))}});
      try{
        const actual=await pixels.getImageInfo(),buffer=new ArrayBuffer(actual.size.width*actual.size.height*4);
        await pixels.readPixelsToBuffer(buffer);
        return DeviceArtworkFrame.fromRgba(new Uint8Array(buffer),actual.size.width,actual.size.height);
      }finally{await pixels.release();}
    }finally{await source.release();}
  }
}
