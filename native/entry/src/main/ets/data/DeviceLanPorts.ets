import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';

/** Port hints survive a missing discovery row. They never establish device trust. */
export class DeviceLanPorts {
  private static ports:Map<string,string>=new Map();
  private static ready:boolean=false;
  private static loading:Promise<void>|undefined;
  private static writes:Promise<void>=Promise.resolve();
  private static dirty:boolean=false;
  private static key(signature:string,host:string):string{
    if(!signature||!DeviceInstallTarget.privateHost(host))return '';
    // Net IDs and this phone's DHCP address can change on the same LAN.
    const networks=signature.split(';').map((network):string=>{
      const parts=network.split('|');if(parts.length<3)return network;
      return parts[2].split(',').map((address):string=>{
        const values=address.split('/'),bits=Number(values[1]);
        if(!DeviceInstallTarget.privateHost(values[0])||!Number.isInteger(bits)||bits<1||bits>32)return address;
        const ip=values[0].split('.').reduce((value:number,part:string)=>value*256+Number(part),0),block=Math.pow(2,32-bits);
        return Math.floor(ip/block)*block+'/'+bits;
      }).sort().join(',');
    }).sort().join(';');
    return JSON.stringify([networks,host]);
  }
  static get(signature:string,host:string):string{return DeviceLanPorts.ports.get(DeviceLanPorts.key(signature,host))||'';}
  static load(context:common.UIAbilityContext):Promise<void>{
    if(DeviceLanPorts.ready)return Promise.resolve();
    if(DeviceLanPorts.loading)return DeviceLanPorts.loading;
    const flight=DeviceLanPorts.read(context);DeviceLanPorts.loading=flight;
    flight.finally(()=>{if(DeviceLanPorts.loading===flight)DeviceLanPorts.loading=undefined;}).catch(()=>{});return flight;
  }
  private static async read(context:common.UIAbilityContext):Promise<void>{
    try{
      const store=await preferences.getPreferences(context,'device-lan-ports');
      const rows=JSON.parse(String(await store.get('ports','[]'))) as string[][];
      if(Array.isArray(rows))rows.slice(-512).forEach((row:string[])=>{
        if(Array.isArray(row)&&row.length===2&&typeof row[0]==='string'&&row[0].length<=512&&typeof row[1]==='string'&&
          /^\d{5}$/.test(row[1])&&DeviceInstallTarget.validPort(Number(row[1]))&&!DeviceLanPorts.ports.has(row[0]))DeviceLanPorts.ports.set(row[0],row[1]);
      });
      DeviceLanPorts.ready=true;
    }catch(_){ /* Retain edits and retry storage on the next use. */ }
  }
  static save(context:common.UIAbilityContext,signature:string,host:string,port:string):Promise<void>{
    const key=DeviceLanPorts.key(signature,host);
    if(!key||(port!==''&&(!/^\d{5}$/.test(port)||!DeviceInstallTarget.validPort(Number(port)))))return Promise.resolve();
    if(DeviceLanPorts.ready&&!DeviceLanPorts.dirty&&DeviceLanPorts.ports.get(key)===port)return Promise.resolve();
    // Empty entries are tombstones until the pending read has merged, so a clear
    // made during startup cannot resurrect an older value from disk.
    DeviceLanPorts.ports.set(key,port);DeviceLanPorts.dirty=true;
    const ready=DeviceLanPorts.load(context);
    const write=DeviceLanPorts.writes.then(async()=>{
      await ready;
      const store=await preferences.getPreferences(context,'device-lan-ports');
      const rows=Array.from(DeviceLanPorts.ports.entries()).filter((row)=>row[1]!=='').slice(-512);
      const snapshot=JSON.stringify(rows);
      await store.put('ports',snapshot);await store.flush();
      if(snapshot===JSON.stringify(Array.from(DeviceLanPorts.ports.entries()).filter((row)=>row[1]!=='').slice(-512)))DeviceLanPorts.dirty=false;
    });
    DeviceLanPorts.writes=write.catch(()=>{});return write;
  }
}
