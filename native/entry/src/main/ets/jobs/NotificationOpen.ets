import { Want } from '@kit.AbilityKit';
import { router,UIContext } from '@kit.ArkUI';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { StorePageMotion } from '../theme/StorePageMotion';
export class NotificationTarget {
  appId:number=0;preview:number=0;section:string='';
  static parse(uri:string):NotificationTarget|undefined{
    if(uri.length>256)return undefined;
    const match=/^qingqi-installer:\/\/(app\/([1-9][0-9]*)|following|updates)(?:\?preview=([01]))?$/.exec(uri);
    if(!match||(!match[2]&&match[3]))return undefined;const value=new NotificationTarget();
    if(match[2]){value.appId=Number(match[2]);if(!Number.isSafeInteger(value.appId))return undefined;value.preview=match[3]==='1'?1:0;}
    else value.section=match[1]==='following'?'following':'installed';return value;
  }
}
export class NotificationOpen {
  private static pending:NotificationTarget|undefined;private static ui:UIContext|undefined;
  private static timer:number=-1;private static attempts:number=0;private static routing:boolean=false;
  static receive(want:Want):boolean{
    const target=NotificationTarget.parse(String(want.uri??''));if(!target)return false;
    NotificationOpen.pending=target;NotificationOpen.attempts=0;return true;
  }
  static configure(ui:UIContext):void{NotificationOpen.ui=ui;}
  static openPending():void{
    if(!PrivacyConsent.isBusinessAllowed()||!NotificationOpen.pending||!NotificationOpen.ui||NotificationOpen.routing||NotificationOpen.timer!==-1)return;
    const state=NotificationOpen.ui.getRouter().getState();
    if(!state.path&&!state.name){if(++NotificationOpen.attempts<=30)NotificationOpen.timer=setTimeout(()=>{NotificationOpen.timer=-1;NotificationOpen.openPending();},32);return;}
    const target=NotificationOpen.pending;NotificationOpen.pending=undefined;
    if(target.appId){
      NotificationOpen.routing=true;
      StorePageMotion.pushUrl({url:'pages/Detail',params:{id:target.appId,notificationPreview:target.preview}},router.RouterMode.Standard,NotificationOpen.ui)
        .then(()=>{NotificationOpen.routing=false;NotificationOpen.openPending();})
        .catch(()=>{NotificationOpen.routing=false;if(!NotificationOpen.pending)NotificationOpen.pending=target;});
    }else{
      AppStorage.setOrCreate('notificationSection',target.section);
      if(state.path!=='pages/Index'&&state.name!=='Index'){
        NotificationOpen.routing=true;
        StorePageMotion.pushUrl({url:'pages/Index'},router.RouterMode.Single,NotificationOpen.ui)
          .then(()=>{NotificationOpen.routing=false;NotificationOpen.openPending();})
          .catch(()=>{NotificationOpen.routing=false;if(!NotificationOpen.pending)NotificationOpen.pending=target;});
      }
    }
  }
  static suspendRouting():void{if(NotificationOpen.timer!==-1)clearTimeout(NotificationOpen.timer);NotificationOpen.timer=-1;NotificationOpen.ui=undefined;}
}
