import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class DeviceOrbPosition {
  right:boolean=true;
  ratio:number=.64;
}

/** Persist only on release; moving the orb never writes storage on the render path. */
export class DeviceOrbPreferences {
  private static writes:Promise<void>=Promise.resolve();
  static async load(context:common.UIAbilityContext):Promise<DeviceOrbPosition>{
    const position=new DeviceOrbPosition();
    try{
      await DeviceOrbPreferences.writes;
      const store=await preferences.getPreferences(context,'device-orb');
      position.right=(await store.get('right',true))===true;
      const ratio=Number(await store.get('ratio',.64));
      if(Number.isFinite(ratio))position.ratio=Math.max(0,Math.min(1,ratio));
    }catch(_){ /* Use a reachable default if preferences are unavailable. */ }
    return position;
  }
  static save(context:common.UIAbilityContext,right:boolean,ratio:number):Promise<void>{
    const bounded=Number.isFinite(ratio)?Math.max(0,Math.min(1,ratio)):.64;
    const write=DeviceOrbPreferences.writes.then(async()=>{
      const store=await preferences.getPreferences(context,'device-orb');
      await store.put('right',right);await store.put('ratio',bounded);await store.flush();
    });
    DeviceOrbPreferences.writes=write.catch(()=>{});return write;
  }
}
