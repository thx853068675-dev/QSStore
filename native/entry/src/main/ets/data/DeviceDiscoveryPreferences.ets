import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** View choice survives cache cleanup; a late read never overwrites a new tap. */
export class DeviceDiscoveryPreferences {
  private static selected:boolean=false;
  private static ready:boolean=false;
  private static revision:number=0;
  private static loading:Promise<boolean>|undefined;
  private static writes:Promise<void>=Promise.resolve();
  static current():boolean{return DeviceDiscoveryPreferences.selected;}
  static load(context:common.UIAbilityContext):Promise<boolean>{
    if(DeviceDiscoveryPreferences.ready)return Promise.resolve(DeviceDiscoveryPreferences.selected);
    if(DeviceDiscoveryPreferences.loading)return DeviceDiscoveryPreferences.loading;
    const flight=DeviceDiscoveryPreferences.read(context);DeviceDiscoveryPreferences.loading=flight;
    flight.finally(()=>{if(DeviceDiscoveryPreferences.loading===flight)DeviceDiscoveryPreferences.loading=undefined;}).catch(()=>{});
    return flight;
  }
  private static async read(context:common.UIAbilityContext):Promise<boolean>{
    const revision=DeviceDiscoveryPreferences.revision;
    try{
      await DeviceDiscoveryPreferences.writes;
      const store=await preferences.getPreferences(context,'device-discovery-layout');
      const saved=(await store.get('listView',false))===true;
      if(revision===DeviceDiscoveryPreferences.revision)DeviceDiscoveryPreferences.selected=saved;
      DeviceDiscoveryPreferences.ready=true;
    }catch(_){ /* Keep the current choice when storage is temporarily unavailable. */ }
    return DeviceDiscoveryPreferences.selected;
  }
  static save(context:common.UIAbilityContext,list:boolean):Promise<void>{
    DeviceDiscoveryPreferences.selected=list;DeviceDiscoveryPreferences.ready=true;DeviceDiscoveryPreferences.revision++;
    const write=DeviceDiscoveryPreferences.writes.then(async()=>{
      const store=await preferences.getPreferences(context,'device-discovery-layout');
      await store.put('listView',list);await store.flush();
    });
    DeviceDiscoveryPreferences.writes=write.catch(()=>{});return write;
  }
}
