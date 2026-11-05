import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountSession } from './DeveloperAccount';
import { CatalogApp } from './CatalogApp';
import { FollowedApp,FollowChange } from './Following';
import { StoreClient } from './StoreClient';
import { PrivacyConsent } from './PrivacyConsent';
import { ReleaseChannelRegistry } from './ReleaseChannelRegistry';
import { UpdatePolicy } from './UpdatePolicy';
export class FollowingRegistry {
  private static scope:string='';private static loaded:boolean=false;
  private static rows:Map<number,FollowedApp>=new Map();private static dirty:Map<number,FollowChange>=new Map();
  private static writes:Promise<void>=Promise.resolve();private static flight:Promise<void>|undefined;
  private static loading:Promise<void>|undefined;
  private static lastSynced:number=0;private static resync:boolean=false;private static forceSync:boolean=false;
  private static revision:number=0;private static epoch:number=0;
  private static listeners:Map<number,()=>void>=new Map();private static nextListener:number=0;
  static subscribe(callback:()=>void):number{const key=++FollowingRegistry.nextListener;FollowingRegistry.listeners.set(key,callback);return key;}
  static unsubscribe(key:number):void{FollowingRegistry.listeners.delete(key);}
  private static notify():void{FollowingRegistry.listeners.forEach((fn)=>fn());}
  static has(id:number):boolean{return FollowingRegistry.rows.has(id);}
  static entries():FollowedApp[]{return Array.from(FollowingRegistry.rows.values());}
  static async load(context:common.UIAbilityContext):Promise<void>{
    if(!PrivacyConsent.isBusinessAllowed())return;
    const account=await AccountSession.load(context),scope=account?.userId||'guest';
    if(FollowingRegistry.loaded&&FollowingRegistry.scope===scope)return;
    if(FollowingRegistry.loading&&FollowingRegistry.scope===scope)return FollowingRegistry.loading;
    const flight=FollowingRegistry.read(context,scope).finally(()=>{if(FollowingRegistry.loading===flight)FollowingRegistry.loading=undefined;});
    FollowingRegistry.loading=flight;return flight;
  }
  private static async read(context:common.UIAbilityContext,scope:string):Promise<void>{
    const epoch=++FollowingRegistry.epoch;FollowingRegistry.loaded=false;FollowingRegistry.scope=scope;FollowingRegistry.lastSynced=0;
    FollowingRegistry.rows.clear();FollowingRegistry.dirty.clear();FollowingRegistry.notify();
    await FollowingRegistry.writes;const prefs=await preferences.getPreferences(context,'following');
    const raw=String(await prefs.get('account:'+scope,''));if(epoch!==FollowingRegistry.epoch)return;
    try{
      if(raw.length>2*1024*1024)throw new Error('following cache exceeds limit');
      const saved=JSON.parse(raw||'{}') as Record<string,Object>;
      const rows=saved['items'] as Array<Record<string,Object>>;
      if(Array.isArray(rows))for(const row of rows.slice(0,200)){const item=FollowedApp.fromSaved(row);if(item)FollowingRegistry.rows.set(item.app.id,item);}
      const pending=saved['pending'] as FollowChange[];
      if(Array.isArray(pending))for(const row of pending.slice(0,400))if(Number.isSafeInteger(row.app_id)&&row.app_id>0&&typeof row.enabled==='boolean'&&typeof row.prerelease==='boolean'){FollowingRegistry.dirty.set(row.app_id,row);FollowingRegistry.revision=Math.max(FollowingRegistry.revision,row.revision||0);}
    }catch(_){ /* Invalid cache never changes server subscriptions. */ }
    FollowingRegistry.loaded=true;FollowingRegistry.notify();
  }
  private static persist(context:common.UIAbilityContext):Promise<void>{
    const scope=FollowingRegistry.scope,items=FollowingRegistry.entries(),pending=Array.from(FollowingRegistry.dirty.values());
    const value=JSON.stringify({items:items,pending:pending});
    const write=FollowingRegistry.writes.then(async()=>{const prefs=await preferences.getPreferences(context,'following');await prefs.put('account:'+scope,value);await prefs.flush();});
    FollowingRegistry.writes=write.catch(()=>{});return write;
  }
  static async set(context:common.UIAbilityContext,app:CatalogApp,enabled:boolean):Promise<void>{
    await FollowingRegistry.load(context);
    if(!Number.isSafeInteger(app.id)||app.id<=0)throw new Error('无效的应用');
    if(enabled&&!FollowingRegistry.has(app.id)&&FollowingRegistry.rows.size>=200)throw new Error('最多关注 200 个应用');
    const epoch=FollowingRegistry.epoch;
    const previous=FollowingRegistry.rows.get(app.id),oldChange=FollowingRegistry.dirty.get(app.id);
    if(enabled)FollowingRegistry.rows.set(app.id,FollowedApp.fromCatalog(ReleaseChannelRegistry.apply(app),ReleaseChannelRegistry.preview(app.id)));
    else FollowingRegistry.rows.delete(app.id);
    const change=new FollowChange();change.app_id=app.id;change.enabled=enabled;change.prerelease=ReleaseChannelRegistry.preview(app.id);change.revision=++FollowingRegistry.revision;
    FollowingRegistry.dirty.set(app.id,change);
    FollowingRegistry.notify();
    try{await FollowingRegistry.persist(context);}catch(error){
      if(epoch===FollowingRegistry.epoch&&FollowingRegistry.dirty.get(app.id)?.revision===change.revision){if(previous)FollowingRegistry.rows.set(app.id,previous);else FollowingRegistry.rows.delete(app.id);if(oldChange)FollowingRegistry.dirty.set(app.id,oldChange);else FollowingRegistry.dirty.delete(app.id);FollowingRegistry.notify();}
      throw error as Error;
    }
  }
  static sync(context:common.UIAbilityContext,force:boolean=false):Promise<void>{
    FollowingRegistry.forceSync=FollowingRegistry.forceSync||force;
    if(FollowingRegistry.flight){FollowingRegistry.resync=true;return FollowingRegistry.flight;}
    const next=FollowingRegistry.drainSync(context).finally(()=>{if(FollowingRegistry.flight===next)FollowingRegistry.flight=undefined;});
    FollowingRegistry.flight=next;return next;
  }
  private static async drainSync(context:common.UIAbilityContext):Promise<void>{
    for(let pass=0;pass<3;pass++){
      FollowingRegistry.resync=false;const force=FollowingRegistry.forceSync;FollowingRegistry.forceSync=false;
      await FollowingRegistry.syncOnce(context,force);
      if(!FollowingRegistry.resync)return;
    }
  }
  private static async syncOnce(context:common.UIAbilityContext,force:boolean):Promise<void>{
    await FollowingRegistry.load(context);if(!PrivacyConsent.isBusinessAllowed())return;
    const account=await AccountSession.load(context);if(!account||account.userId!==FollowingRegistry.scope)return;
    const scope=FollowingRegistry.scope,epoch=FollowingRegistry.epoch;
    await ReleaseChannelRegistry.restore(context);await UpdatePolicy.restore(context);
    if(scope!==FollowingRegistry.scope||epoch!==FollowingRegistry.epoch||account.userId!==scope)return;
    // Channel and stop-update preferences are part of the subscription, not just presentation.
    for(const item of FollowingRegistry.entries()){
      const preview=ReleaseChannelRegistry.preview(item.app.id),muted=!!item.app.latestAsset?.bundleName&&UpdatePolicy.disabled(item.app.latestAsset.bundleName);
      if(preview!==item.preview||muted!==item.muted){item.preview=preview;item.muted=muted;const c=new FollowChange();c.app_id=item.app.id;c.prerelease=preview;c.muted=muted;c.revision=++FollowingRegistry.revision;FollowingRegistry.dirty.set(c.app_id,c);}
    }
    if(!force&&FollowingRegistry.dirty.size===0&&Date.now()-FollowingRegistry.lastSynced<60000)return;
    const changes=Array.from(FollowingRegistry.dirty.values()).map((old:FollowChange)=>{const c=new FollowChange();c.app_id=old.app_id;c.enabled=old.enabled;c.prerelease=old.prerelease;c.revision=old.revision;
      const item=FollowingRegistry.rows.get(c.app_id);c.muted=!!item?.app.latestAsset?.bundleName&&UpdatePolicy.disabled(item.app.latestAsset.bundleName);return c;});
    const result=await new StoreClient(context).following(account,changes);
    if(scope!==FollowingRegistry.scope||epoch!==FollowingRegistry.epoch||!PrivacyConsent.isBusinessAllowed())return;
    FollowingRegistry.lastSynced=Date.now();
    const remote=new Map<number,FollowedApp>();
    for(const item of result)if(Number.isSafeInteger(item.app.id)&&item.app.id>0)remote.set(item.app.id,item);
    for(const sent of changes)if(FollowingRegistry.dirty.get(sent.app_id)?.revision===sent.revision)FollowingRegistry.dirty.delete(sent.app_id);
    for(const change of FollowingRegistry.dirty.values()){
      if(!change.enabled)remote.delete(change.app_id);else{const item=FollowingRegistry.rows.get(change.app_id);if(item)remote.set(change.app_id,item);}
    }
    const changed=JSON.stringify(FollowingRegistry.entries())!==JSON.stringify(Array.from(remote.values()));
    FollowingRegistry.rows=remote;await FollowingRegistry.persist(context);if(changed)FollowingRegistry.notify();
  }
}
