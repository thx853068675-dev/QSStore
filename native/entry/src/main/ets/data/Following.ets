import { CatalogApp } from './CatalogApp';
import { releaseDisplayVersion } from './DisplayVersion';
import { ManagementSort } from './ManagementSort';
export class FollowChange {
  app_id:number=0;enabled:boolean=true;prerelease:boolean=false;muted:boolean=false;revision:number=0;
}
export class FollowedApp {
  app:CatalogApp=new CatalogApp();preview:boolean=false;muted:boolean=false;
  previousVersion:string='';latestVersion:string='';publishedAt:string='';followedAt:number=0;
  static fromCatalog(app:CatalogApp,preview:boolean):FollowedApp{
    const item=new FollowedApp();item.app=CatalogApp.copy(app);item.preview=preview;item.followedAt=Date.now();
    const asset=app.latestAsset;
    item.latestVersion=releaseDisplayVersion(asset?.releaseName??'',asset?.releaseTag??'',asset?.versionName??'',app.displayName,asset?.versionCode??0);
    item.publishedAt=app.latestPublishedAt;return item;
  }
  static fromJson(row:Record<string,Object>):FollowedApp{
    const item=new FollowedApp();item.app=CatalogApp.fromJson(row['app'] as Record<string,Object>);
    item.preview=row['prerelease']===true;item.muted=row['muted']===true;item.previousVersion=String(row['previous_version']??'');
    item.latestVersion=String(row['latest_version']??'');item.publishedAt=String(row['published_at']??'');
    item.followedAt=ManagementSort.timestamp(Number(row['followed_at']??0));return item;
  }
  static fromSaved(row:Record<string,Object>):FollowedApp|undefined{
    const app=row['app'] as CatalogApp;
    if(!app||!Number.isSafeInteger(app.id)||app.id<=0||typeof app.displayName!=='string')return undefined;
    const item=new FollowedApp();item.app=CatalogApp.copy(app);item.preview=row['preview']===true;item.muted=row['muted']===true;
    item.previousVersion=String(row['previousVersion']??'');item.latestVersion=String(row['latestVersion']??'');
    item.publishedAt=String(row['publishedAt']??'');item.followedAt=Number(row['followedAt']??0);return item;
  }
  static date(value:string):string{
    const at=ManagementSort.timestamp(value);if(!at)return '';
    const d=new Date(at),pad=(n:number):string=>n<10?'0'+n:String(n);
    return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate())+' '+pad(d.getHours())+':'+pad(d.getMinutes());
  }
}
