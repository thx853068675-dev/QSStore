import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ManagementSort } from './ManagementSort';
export class ManagementSortPreferences {
  private static revision:number=0;
  private static writes:Promise<void>=Promise.resolve();
  static async load(context:common.UIAbilityContext):Promise<void>{
    const revision=ManagementSortPreferences.revision;
    await ManagementSortPreferences.writes;const prefs=await preferences.getPreferences(context,'management-sort');
    const key=ManagementSort.key(String(await prefs.get('installedKey','updated')));
    const direction=ManagementSort.direction(String(await prefs.get('installedDirection','desc')));
    const following=ManagementSort.direction(String(await prefs.get('followingDirection','desc')));
    const collapsed=await prefs.get('followingCollapsed',false)===true;
    if(revision!==ManagementSortPreferences.revision)return;
    AppStorage.setOrCreate('managementSort',key);AppStorage.setOrCreate('managementDirection',direction);
    AppStorage.setOrCreate('followingDirection',following);AppStorage.setOrCreate('followingCollapsed',collapsed);
  }
  static save(context:common.UIAbilityContext,key:string,value:string|boolean):Promise<void>{
    ManagementSortPreferences.revision++;
    const next=ManagementSortPreferences.writes.then(async()=>{const prefs=await preferences.getPreferences(context,'management-sort');await prefs.put(key,value);await prefs.flush();});
    ManagementSortPreferences.writes=next.catch(()=>{});return next;
  }
}
