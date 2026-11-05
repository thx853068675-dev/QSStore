import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { InstallTaskState } from './InstallTaskState';
import { JobStore } from './JobStore';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { DeviceNetwork } from './DeviceNetwork';
import { I18n } from '../data/I18n';

/** Public discovery metadata is a hint; only authenticated HDC identities are remembered. */
export class MultiDeviceTargets {
  static selected: DeviceInstallTarget = new DeviceInstallTarget();
  static remembered: DeviceInstallTarget[] = [];
  static modeEnabled:boolean=false;
  static enable(allowed:()=>boolean=()=>true):Promise<void>{
    const task=MultiDeviceTargets.writing.then(async()=>{
      if(!MultiDeviceTargets.context||!allowed())return;
      PrivacyConsent.assertBusinessAllowed();const previous=MultiDeviceTargets.modeEnabled;
      const store=await preferences.getPreferences(MultiDeviceTargets.context,'multi-device');
      await store.put('enabled',true);await store.flush();
      if(!allowed()){await store.put('enabled',previous);await store.flush();return;}
      MultiDeviceTargets.modeEnabled=true;MultiDeviceTargets.emit();
    });MultiDeviceTargets.writing=task.catch(()=>{});return task;
  }
  static disable():Promise<void>{return MultiDeviceTargets.writeSelection(()=>[new DeviceInstallTarget()],()=>true,false);}
  static selection: DeviceInstallTarget[] = [new DeviceInstallTarget()];
  static snapshots(): string[] { return DeviceNetwork.ready&&!DeviceNetwork.available?['']:MultiDeviceTargets.selection.map((row) => DeviceInstallTarget.snapshot(row)); }
  private static activeSnapshot():string{return DeviceNetwork.ready&&!DeviceNetwork.available?'':DeviceInstallTarget.snapshot(MultiDeviceTargets.selected);}
  static contains(key: string): boolean { return MultiDeviceTargets.selection.some((row) => row.key === key.toLowerCase()); }
  static toggle(row:DeviceInstallTarget,allowed:()=>boolean=()=>true,retainLocal:boolean=false):Promise<void>{
    if(row.key!=='local'&&!DeviceNetwork.available)return Promise.reject(new Error(I18n.t('请先连接 Wi-Fi')));
    const text=DeviceInstallTarget.snapshot(row),copy=text?DeviceInstallTarget.parse(text):new DeviceInstallTarget();
    return MultiDeviceTargets.writeSelection(()=>{
      const current=MultiDeviceTargets.selection;
      const selected=MultiDeviceTargets.contains(copy.key)?current.filter((item)=>item.key!==copy.key):
        !retainLocal&&copy.key!=='local'&&current.length===1&&current[0].key==='local'?[copy]:
          copy.key==='local'?[...current,copy]:[copy,...current];
      return selected.length?selected:[new DeviceInstallTarget()];
    },allowed);
  }
  private static context: common.UIAbilityContext | undefined;
  private static opening: Promise<void> | undefined;
  private static writing: Promise<void> = Promise.resolve();
  private static listeners: Map<number, () => void> = new Map();
  private static next: number = 0;
  private static networkSubscription:number=-1;

  static load(context: common.UIAbilityContext): Promise<void> {
    if (!MultiDeviceTargets.opening) {
      MultiDeviceTargets.context=context;
      MultiDeviceTargets.opening=MultiDeviceTargets.restore(context).catch((error: Error) => {
        MultiDeviceTargets.opening=undefined; throw error;
      });
      if(MultiDeviceTargets.networkSubscription<0)MultiDeviceTargets.networkSubscription=DeviceNetwork.subscribe(()=>{
        if(DeviceNetwork.ready&&!DeviceNetwork.available&&MultiDeviceTargets.selection.some((row)=>row.key!=='local'))
          MultiDeviceTargets.writeSelection(()=>[new DeviceInstallTarget()],()=>!DeviceNetwork.available).catch(()=>{});
      });
      MultiDeviceTargets.opening.then(()=>DeviceNetwork.start()).catch(()=>{});
    }
    DeviceInstallTarget.snapshotProvider=()=>MultiDeviceTargets.activeSnapshot();
    JobStore.setTargetProvider(() => PrivacyConsent.isBusinessAllowed() ? MultiDeviceTargets.activeSnapshot() : '');
    InstallTaskState.setTargetProvider(()=>MultiDeviceTargets.activeSnapshot());
    return MultiDeviceTargets.opening;
  }
  private static async restore(context: common.UIAbilityContext): Promise<void> {
    const store=await preferences.getPreferences(context,'multi-device');
    let rows: string[]=[];
    try { const parsed=JSON.parse(String(await store.get('remembered','[]'))) as string[];if(Array.isArray(parsed))rows=parsed; } catch (_) {}
    const remembered: DeviceInstallTarget[]=[];
    for(const text of rows.slice(0,24)) {
      try { const row=DeviceInstallTarget.parse(text); if(row.key!=='local'&&!remembered.some((saved)=>saved.key===row.key))remembered.push(row); }catch(_){}
    }
    const key=String(await store.get('selected','local'));
    const previous=DeviceInstallTarget.snapshot(MultiDeviceTargets.selected);
    MultiDeviceTargets.remembered=remembered;
    MultiDeviceTargets.selected=remembered.find((row)=>row.key===key) ?? new DeviceInstallTarget();
    let keys: string[] = [key];
    try { const saved = JSON.parse(String(await store.get('selection', JSON.stringify(keys)))) as string[]; if (Array.isArray(saved)) keys = saved.slice(0,24); } catch (_) {}
    MultiDeviceTargets.selection = [];
    for (const id of keys) {
      const row = id === 'local' ? new DeviceInstallTarget() : remembered.find((row) => row.key === id);
      if (row && !MultiDeviceTargets.selection.some((saved) => saved.key === row.key)) MultiDeviceTargets.selection.push(row);
    }
    if (!MultiDeviceTargets.selection.length) MultiDeviceTargets.selection = [new DeviceInstallTarget()];
    MultiDeviceTargets.selected = MultiDeviceTargets.selection[0];
    MultiDeviceTargets.modeEnabled=Boolean(await store.get('enabled',MultiDeviceTargets.selection.some((row)=>row.key!=='local')));
    AppStorage.setOrCreate('deviceMultiEnabled',MultiDeviceTargets.modeEnabled);
    AppStorage.setOrCreate('installTargetCount',MultiDeviceTargets.selection.length);
    if(previous!==DeviceInstallTarget.snapshot(MultiDeviceTargets.selected))MultiDeviceTargets.emit();
  }
  static subscribe(handler:()=>void):number {const id=++MultiDeviceTargets.next;MultiDeviceTargets.listeners.set(id,handler);return id;}
  static unsubscribe(id:number):void {MultiDeviceTargets.listeners.delete(id);}
  private static emit():void {AppStorage.setOrCreate('deviceMultiEnabled',MultiDeviceTargets.modeEnabled);AppStorage.setOrCreate('installTargetCount',MultiDeviceTargets.selection.length);InstallTaskState.targetChanged();AppStorage.setOrCreate('installTargetName',MultiDeviceTargets.selected.key==='local'?'':MultiDeviceTargets.selected.name);MultiDeviceTargets.listeners.forEach((handler)=>handler());}
  static select(row:DeviceInstallTarget, allowed:()=>boolean=()=>true):Promise<void> {
    return MultiDeviceTargets.selectMany([row], allowed);
  }
  static selectMany(rows:DeviceInstallTarget[],allowed:()=>boolean=()=>true):Promise<void>{
    // Copy the caller's accepted choice before another page can mutate it.
    const copies=rows.map((row)=>{const text=DeviceInstallTarget.snapshot(row);return text?DeviceInstallTarget.parse(text):new DeviceInstallTarget();});
    return MultiDeviceTargets.writeSelection(()=>copies,allowed);
  }
  static forget(key:string,allowed:()=>boolean=()=>true):Promise<void>{
    if(!/^[0-9a-fA-F]{40,128}$/.test(key))return Promise.reject(new Error(I18n.t('设备记录无效')));
    const normalized=key.toLowerCase();
    return MultiDeviceTargets.writeSelection(()=>{
      const remaining=MultiDeviceTargets.selection.filter((row)=>row.key!==normalized);
      return remaining.length?remaining:[new DeviceInstallTarget()];
    },allowed,undefined,normalized);
  }
  private static writeSelection(resolve:()=>DeviceInstallTarget[],allowed:()=>boolean,enabledOverride?:boolean,forgottenKey:string=''):Promise<void>{
    PrivacyConsent.assertBusinessAllowed();
    const task=MultiDeviceTargets.writing.then(async()=>{
      PrivacyConsent.assertBusinessAllowed();
      if(!MultiDeviceTargets.context)throw new Error(I18n.t('设备记录尚未准备好'));
      if(!allowed())return;
      const copies=resolve();
      if(copies.some((row)=>row.key!=='local')&&DeviceNetwork.ready&&!DeviceNetwork.available)throw new Error(I18n.t('请先连接 Wi-Fi'));
      if(!copies.length||copies.length>24||new Set(copies.map((row)=>row.key)).size!==copies.length)throw new Error(I18n.t('请选择有效设备'));
      const previousKey=MultiDeviceTargets.selected.key;
      const previousEnabled=MultiDeviceTargets.modeEnabled;
      const previousSelection=JSON.stringify(MultiDeviceTargets.selection.map((row)=>row.key));
      const previousRecords=JSON.stringify(MultiDeviceTargets.remembered.map((saved)=>DeviceInstallTarget.snapshot(saved)));
      const remote=copies.filter((row)=>row.key!=='local');
      const records=[...remote,...MultiDeviceTargets.remembered.filter((saved)=>saved.key!==forgottenKey&&!remote.some((row)=>row.key===saved.key))].slice(0,24);
      const store=await preferences.getPreferences(MultiDeviceTargets.context,'multi-device');
      await store.put('remembered',JSON.stringify(records.map((saved)=>DeviceInstallTarget.snapshot(saved))));
      const enabled=enabledOverride??(MultiDeviceTargets.modeEnabled||copies.some((row)=>row.key!=='local'));
      await store.put('enabled',enabled);
      await store.put('selected',copies[0].key);await store.put('selection',JSON.stringify(copies.map((row)=>row.key)));await store.flush();
      PrivacyConsent.assertBusinessAllowed();
      if(!allowed()||(DeviceNetwork.ready&&!DeviceNetwork.available&&copies.some((row)=>row.key!=='local'))){await store.put('remembered',previousRecords);await store.put('enabled',previousEnabled);await store.put('selected',previousKey);await store.put('selection',previousSelection);await store.flush();return;}
      MultiDeviceTargets.modeEnabled=enabled;MultiDeviceTargets.remembered=records;MultiDeviceTargets.selection=copies;MultiDeviceTargets.selected=copies[0];MultiDeviceTargets.emit();
    });MultiDeviceTargets.writing=task.catch(()=>{});return task;
  }
}
