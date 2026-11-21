import { image } from '@kit.ImageKit';
import { DeviceArtworkCatalog } from './DeviceArtworkCatalog';

/** Device nodes never need to retain full-resolution marketing PNGs. */
export class DeviceArtworkThumbnail {
  static readonly EDGE:number=512;
  static async encode(bytes:ArrayBuffer):Promise<ArrayBuffer>{
    if(!DeviceArtworkCatalog.validPng(bytes))throw new Error('Invalid device artwork');
    const source=image.createImageSource(bytes);
    let pixels:image.PixelMap|undefined;
    let packer:image.ImagePacker|undefined;
    try{
      const info=await source.getImageInfo(),width=info.size.width,height=info.size.height;
      if(width<1||height<1||width>4096||height>4096)throw new Error('Invalid device artwork size');
      const ratio=Math.min(1,DeviceArtworkThumbnail.EDGE/Math.max(width,height));
      pixels=await source.createPixelMap({desiredPixelFormat:image.PixelMapFormat.RGBA_8888,
        desiredSize:{width:Math.max(1,Math.round(width*ratio)),height:Math.max(1,Math.round(height*ratio))}});
      packer=image.createImagePacker();
      // PNG preserves the transparent silhouette; JPEG would introduce a solid rectangle.
      const result=await packer.packToData(pixels,{format:'image/png',quality:100,bufferSize:2*1024*1024});
      if(!DeviceArtworkCatalog.validPng(result,DeviceArtworkThumbnail.EDGE))throw new Error('Invalid device artwork thumbnail');
      return result;
    }finally{
      try{await packer?.release();}catch(_){}
      try{await pixels?.release();}catch(_){}
      try{await source.release();}catch(_){}
    }
  }
}
