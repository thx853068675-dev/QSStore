import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { DeviceArtworkCatalog, DeviceArtworkEntry } from './DeviceArtworkCatalog';
import { PrivacyConsent } from './PrivacyConsent';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { DeviceArtworkFrame } from './DeviceArtworkFrame';
import { I18n } from './I18n';

interface ArtworkFile { name:string; size:number; mtime:number; }
export class DeviceArtworkPortrait {
  source:string;
  frame:DeviceArtworkFrame;
  constructor(source:string,frame:DeviceArtworkFrame){this.source=source;this.frame=frame;}
}
/** Optional public product artwork. Never holds up pairing, discovery or an installation. */
export class DeviceArtwork {
  private static catalogue:Promise<DeviceArtworkEntry[]>|undefined;
  private static flights:Map<string,Promise<string>>=new Map();
  private static misses:Map<string,number>=new Map();
  private static generation:number=0;
  private static writes:Promise<void>=Promise.resolve();
  private static portraits:Map<string,DeviceArtworkPortrait>=new Map();
  private static readonly LIMIT:number=8*1024*1024;
  private static directory(context:common.UIAbilityContext):string{return context.cacheDir+'/device-art';}
  private static async checked(context:common.UIAbilityContext,create:boolean=false):Promise<string>{
    const dir=DeviceArtwork.directory(context);
    if(create&&!fileIo.accessSync(dir))fileIo.mkdirSync(dir,true);
    const stat=await fileIo.lstat(dir);if(!stat.isDirectory()||stat.isSymbolicLink())throw new Error('设备图片缓存不可用');
    return dir;
  }
  private static index(context:common.UIAbilityContext):Promise<DeviceArtworkEntry[]>{
    if(!DeviceArtwork.catalogue){
      const flight=context.resourceManager.getRawFileContent('device-art/catalog.json')
        .then((bytes:Uint8Array)=>DeviceArtworkCatalog.parse(util.TextDecoder.create('utf-8').decodeWithStream(bytes)));
      DeviceArtwork.catalogue=flight;flight.catch(()=>{if(DeviceArtwork.catalogue===flight)DeviceArtwork.catalogue=undefined;});
    }
    return DeviceArtwork.catalogue!;
  }
  private static portraitKey(context:common.UIAbilityContext,kind:string,model:string,name:string):string{
    return JSON.stringify([context.cacheDir,kind,model,name]);
  }
  /** Synchronous warm snapshot: remounting an orb must not show a different model first. */
  static cached(context:common.UIAbilityContext,kind:string,model:string,name:string):DeviceArtworkPortrait|undefined{
    return DeviceArtwork.portraits.get(DeviceArtwork.portraitKey(context,kind,model,name));
  }
  static async portrait(context:common.UIAbilityContext,kind:string,model:string,name:string):Promise<DeviceArtworkPortrait|undefined>{
    const key=DeviceArtwork.portraitKey(context,kind,model,name),ready=DeviceArtwork.portraits.get(key);
    if(ready)return ready;
    const generation=DeviceArtwork.generation,source=await DeviceArtwork.load(context,kind,model,name);
    if(!source||generation!==DeviceArtwork.generation)return undefined;
    const frame=await DeviceArtworkFrame.load(source);
    if(generation!==DeviceArtwork.generation)return undefined;
    const portrait=new DeviceArtworkPortrait(source,frame);
    if(DeviceArtwork.portraits.size>=64)for(const oldest of DeviceArtwork.portraits.keys()){DeviceArtwork.portraits.delete(oldest);break;}
    DeviceArtwork.portraits.set(key,portrait);return portrait;
  }
  static invalidate(source:string):void{
    DeviceArtwork.portraits.forEach((row,key)=>{if(row.source===source)DeviceArtwork.portraits.delete(key);});
  }
  static async load(context:common.UIAbilityContext,kind:string,model:string,name:string):Promise<string>{
    try{
      const entry=DeviceArtworkCatalog.match(await DeviceArtwork.index(context),kind,model,name);
      if(!entry)return '';
      const rows=await DeviceArtwork.index(context),nameOnDisk=String(rows.indexOf(entry))+'-'+DeviceArtwork.hash(entry.image)+'.png';
      const key=context.cacheDir+':'+entry.image;
      const pending=DeviceArtwork.flights.get(key);if(pending)return pending;
      const generation=DeviceArtwork.generation;
      const flight=DeviceArtwork.read(context,entry,nameOnDisk,generation).catch(()=>{
        if(generation===DeviceArtwork.generation)DeviceArtwork.misses.set(key,Date.now());return '';
      }).finally(()=>{if(DeviceArtwork.flights.get(key)===flight)DeviceArtwork.flights.delete(key);});
      DeviceArtwork.flights.set(key,flight);return await flight;
    }catch(_){return '';}
  }
  private static hash(value:string):string{
    let code=2166136261;for(let i=0;i<value.length;i++)code=Math.imul(code^value.charCodeAt(i),16777619);return(code>>>0).toString(16);
  }
  private static async validFile(path:string):Promise<boolean>{
    try{
      const stat=await fileIo.lstat(path);if(!stat.isFile()||stat.isSymbolicLink()||stat.size<33||stat.size>512*1024)return false;
      const file=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
      try{
        const bytes=new ArrayBuffer(stat.size);let at=0;
        while(at<stat.size){const part=new ArrayBuffer(stat.size-at),count=await fileIo.read(file.fd,part);if(count<=0)return false;
          new Uint8Array(bytes).set(new Uint8Array(part,0,count),at);at+=count;}
        return DeviceArtworkCatalog.validPng(bytes);
      }finally{await fileIo.close(file);}
    }catch(_){return false;}
  }
  private static async read(context:common.UIAbilityContext,entry:DeviceArtworkEntry,name:string,generation:number):Promise<string>{
    const dir=DeviceArtwork.directory(context),path=dir+'/'+name,key=context.cacheDir+':'+entry.image;
    if(fileIo.accessSync(dir)){await DeviceArtwork.checked(context);if(await DeviceArtwork.validFile(path))return 'file://'+path;}
    const last=DeviceArtwork.misses.get(key)??0;
    if(last&&Date.now()-last<60000)return '';
    if(!PrivacyConsent.isBusinessAllowed())return '';
    await ForegroundIdle.wait();
    if(generation!==DeviceArtwork.generation||!PrivacyConsent.isBusinessAllowed())return '';
    const request=http.createHttp();let bytes:ArrayBuffer;
    try{
      const response=await request.request(entry.image,{method:http.RequestMethod.GET,expectDataType:http.HttpDataType.ARRAY_BUFFER,
        connectTimeout:5000,readTimeout:6000,maxLimit:512*1024,maxRedirects:0,usingCache:false});
      if(response.responseCode!==200||!(response.result instanceof ArrayBuffer)||!DeviceArtworkCatalog.validPng(response.result))throw new Error(I18n.t('设备图片暂不可用'));
      bytes=response.result;
    }finally{request.destroy();}
    let result='';
    const write=DeviceArtwork.writes.catch(()=>{}).then(async()=>{
      if(generation!==DeviceArtwork.generation||!PrivacyConsent.isBusinessAllowed())return;
      await DeviceArtwork.checked(context,true);const temporary=path+'.part';
      try{
        const file=await fileIo.open(temporary,fileIo.OpenMode.CREATE|fileIo.OpenMode.TRUNC|fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.NOFOLLOW);
        try{let at=0;while(at<bytes.byteLength){const count=await fileIo.write(file.fd,bytes.slice(at));if(count<=0)throw new Error('设备图片写入失败');at+=count;}}
        finally{await fileIo.close(file);}
        if(generation!==DeviceArtwork.generation||!PrivacyConsent.isBusinessAllowed())return;
        fileIo.renameSync(temporary,path);await DeviceArtwork.trim(context,name);result='file://'+path;
      }finally{try{fileIo.unlinkSync(temporary);}catch(_){}}
    });
    DeviceArtwork.writes=write;await write;return result;
  }
  private static async files(context:common.UIAbilityContext):Promise<ArtworkFile[]>{
    const dir=await DeviceArtwork.checked(context),result:ArtworkFile[]=[];
    for(const name of await fileIo.listFile(dir)){
      if(!/^\d+-[a-f0-9]+\.png(\.part)?$/.test(name))continue;
      try{const stat=await fileIo.lstat(dir+'/'+name);if(stat.isFile()&&!stat.isSymbolicLink())result.push({name:name,size:stat.size,mtime:stat.mtime});}catch(_){}
    }
    return result;
  }
  private static async trim(context:common.UIAbilityContext,newest:string):Promise<void>{
    const rows=(await DeviceArtwork.files(context)).sort((a,b)=>a.mtime-b.mtime);
    let bytes=rows.reduce((sum,row)=>sum+row.size,0),count=rows.length;
    for(const row of rows){if(bytes<=DeviceArtwork.LIMIT&&count<=64)break;if(row.name===newest)continue;
      try{const path=DeviceArtwork.directory(context)+'/'+row.name;fileIo.unlinkSync(path);DeviceArtwork.invalidate('file://'+path);bytes-=row.size;count--;}catch(_){}}
  }
  static async size(context:common.UIAbilityContext):Promise<number>{try{return(await DeviceArtwork.files(context)).reduce((sum,row)=>sum+row.size,0);}catch(_){return 0;}}
  static async clear(context:common.UIAbilityContext):Promise<void>{
    DeviceArtwork.portraits.clear();
    DeviceArtworkFrame.clear();
    DeviceArtwork.generation++;DeviceArtwork.misses.clear();
    // A pre-clear request is invalidated, so reopening cannot immediately restore a cleared file.
    DeviceArtwork.flights.clear();await DeviceArtwork.writes.catch(()=>{});
    try{for(const row of await DeviceArtwork.files(context))try{fileIo.unlinkSync(DeviceArtwork.directory(context)+'/'+row.name);}catch(_){}}catch(_){}
  }
}
