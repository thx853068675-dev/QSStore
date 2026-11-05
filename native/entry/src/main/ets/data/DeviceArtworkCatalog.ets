import { I18n } from './I18n';
export interface DeviceArtworkEntry { name:string; kind:string; image:string; }
interface ProductCatalogue { products:DeviceArtworkEntry[]; }

/** Exact market-model matching: never turn Pro into Pro+, or a PC emulator into a MateBook. */
export class DeviceArtworkCatalog {
  static normalize(value:string):string {
    return value.trim().toLowerCase().replace(/^(huawei|华为)\s*/,'')
      .replace(/[\s\u200b-\u200d\-_·]/g,'').replace(/英寸|inch|inches/g,'');
  }
  static validUrl(value:string):boolean {
    return /^https:\/\/consumer\.huawei\.com\/content\/dam\/huawei-cbg-site\/[a-zA-Z0-9_./%-]+\.png$/.test(value)&&
      !value.includes('/../')&&!/%2e|%2f|%5c/i.test(value)&&value.length<512;
  }
  static parse(text:string):DeviceArtworkEntry[] {
    const payload=JSON.parse(text) as ProductCatalogue;
    if(!Array.isArray(payload.products)||payload.products.length>512)throw new Error(I18n.t('设备图片索引无效'));
    return payload.products.filter((row)=>typeof row.name==='string'&&row.name.length>0&&row.name.length<=120&&
      ['phone','tablet','pc'].includes(row.kind)&&typeof row.image==='string'&&DeviceArtworkCatalog.validUrl(row.image));
  }
  static match(rows:DeviceArtworkEntry[],kind:string,model:string,marketName:string):DeviceArtworkEntry|undefined {
    if(/emulator|simulator|模拟器/i.test(model+' '+marketName))return undefined;
    // Known product codes disambiguate retail editions whose OS name includes an edition suffix.
    const code=model.trim().toUpperCase();
    const alias=code==='HBN-AL00'?'HUAWEI Pura 70 Pro':code==='VDE-AL10'?'HUAWEI Pura X':'';
    for(const candidate of [alias,marketName,model]){
      if(!candidate)continue;
      const key=DeviceArtworkCatalog.normalize(candidate);
      const found=rows.filter((row)=>row.kind===kind&&DeviceArtworkCatalog.normalize(row.name)===key);
      if(found.length===1)return found[0];
    }
    return undefined;
  }
  static validPng(bytes:ArrayBuffer):boolean {
    if(bytes.byteLength<33||bytes.byteLength>512*1024)return false;
    const b=new Uint8Array(bytes),magic=[137,80,78,71,13,10,26,10];
    if(magic.some((v,i)=>b[i]!==v)||b[12]!==73||b[13]!==72||b[14]!==68||b[15]!==82)return false;
    const view=new DataView(bytes),w=view.getUint32(16),h=view.getUint32(20);
    // Transparent product artwork only, with a bounded decoded allocation.
    return w>0&&h>0&&w<=1600&&h<=1600&&w*h<=1600000&&(b[25]===6||b[25]===4);
  }
}
