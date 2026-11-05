import { connection } from '@kit.NetworkKit';
import { DeviceInstallTarget } from './DeviceInstallTarget';

/** A cellular/VPN default route is not evidence of a usable physical local network. */
export class DeviceNetwork {
  static available:boolean=false;
  static ready:boolean=false;
  static signature:string='';
  private static flight:Promise<boolean>|undefined;
  private static eventTimer:number=-1;
  private static pendingRefresh:boolean=false;
  private static watchers:Map<connection.NetBearType,connection.NetConnection>=new Map();
  private static generation:number=0;
  private static ids:Set<number>=new Set();
  private static listeners:Map<number,()=>void>=new Map();
  private static next:number=0;
  static subscribe(listener:()=>void):number{const id=++DeviceNetwork.next;DeviceNetwork.listeners.set(id,listener);return id;}
  static unsubscribe(id:number):void{DeviceNetwork.listeners.delete(id);}
  private static publish(available:boolean,signature:string=''):void{
    const changed=!DeviceNetwork.ready||DeviceNetwork.available!==available||DeviceNetwork.signature!==signature;
    DeviceNetwork.signature=signature;
    DeviceNetwork.ready=true;DeviceNetwork.available=available;
    if(changed)DeviceNetwork.listeners.forEach((listener)=>{try{listener();}catch(_){}});
  }
  static start():Promise<boolean>{
    const bearers=[connection.NetBearType.BEARER_WIFI];
    if(DeviceInstallTarget.localKind==='pc')bearers.push(connection.NetBearType.BEARER_ETHERNET);
    bearers.forEach((bearer)=>DeviceNetwork.watch(bearer));
    return DeviceNetwork.refresh();
  }
  private static watch(bearer:connection.NetBearType):void{
    if(DeviceNetwork.watchers.has(bearer))return;
    try{
      const watcher=connection.createNetConnection({netCapabilities:{bearerTypes:[bearer]}});DeviceNetwork.watchers.set(bearer,watcher);
      watcher.on('netAvailable',()=>{DeviceNetwork.requestRefresh();});
      watcher.on('netCapabilitiesChange',()=>{DeviceNetwork.requestRefresh();});
      watcher.on('netConnectionPropertiesChange',()=>{DeviceNetwork.requestRefresh();});
      watcher.on('netLost',(net:connection.NetHandle)=>{
        if(DeviceNetwork.ids.delete(net.netId)&&DeviceNetwork.ids.size===0){DeviceNetwork.generation++;DeviceNetwork.publish(false);}
        DeviceNetwork.requestRefresh();
      });
      watcher.register((error)=>{if(error)DeviceNetwork.watchers.delete(bearer);});
    }catch(_){DeviceNetwork.watchers.delete(bearer);}
  }
  private static requestRefresh():void{
    DeviceNetwork.generation++;
    if(DeviceNetwork.eventTimer!==-1)return;
    DeviceNetwork.eventTimer=setTimeout(()=>{
      DeviceNetwork.eventTimer=-1;
      if(DeviceNetwork.flight){DeviceNetwork.pendingRefresh=true;return;}
      DeviceNetwork.refresh().catch(()=>{});
    },150);
  }
  static refresh():Promise<boolean>{
    if(DeviceNetwork.flight)return DeviceNetwork.flight;
    const flight=DeviceNetwork.read();DeviceNetwork.flight=flight;
    flight.finally(()=>{if(DeviceNetwork.flight===flight)DeviceNetwork.flight=undefined;
      if(DeviceNetwork.pendingRefresh){DeviceNetwork.pendingRefresh=false;DeviceNetwork.requestRefresh();}}).catch(()=>{});
    return flight;
  }
  private static async read():Promise<boolean>{
    const generation=++DeviceNetwork.generation;
    try{
      const nets=await connection.getAllNets();
      const candidates=await Promise.all(nets.map(async(net:connection.NetHandle):Promise<string>=>{
        try{
          const capabilities=await connection.getNetCapabilities(net),properties=await connection.getConnectionProperties(net);
          const wifi=capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI);
          const wired=DeviceInstallTarget.localKind==='pc'&&capabilities.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET);
          const physical=/^(wlan|wifi|eth|en)/.test(properties.interfaceName);
          const address=properties.linkAddresses.some((row)=>DeviceInstallTarget.privateHost(row.address.address));
          return (wifi||wired)&&physical&&address?net.netId+'|'+properties.interfaceName+'|'+properties.linkAddresses.filter((row)=>DeviceInstallTarget.privateHost(row.address.address)).map((row)=>row.address.address+'/'+(row.prefixLength??0)).sort().join(','):'';
        }catch(_){return '';}
      }));
      if(generation===DeviceNetwork.generation){DeviceNetwork.ids=new Set(candidates.filter((row)=>row.length>0).map((row)=>Number(row.split('|')[0])));DeviceNetwork.publish(DeviceNetwork.ids.size>0,candidates.filter((row)=>row.length>0).sort().join(';'));}
    }catch(_){if(generation===DeviceNetwork.generation){DeviceNetwork.ids.clear();DeviceNetwork.publish(false);}}
    return DeviceNetwork.available;
  }
}
