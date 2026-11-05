import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

/** Permanent material popups delegate Back instead of swallowing page navigation. */
export class DeviceOrbNavigation {
  static rootBack:(()=>void)|undefined;
  static back(ui:UIContext,context?:common.UIAbilityContext):void{
    try{
      const router=ui.getRouter(),state=router.getState();
      if(Number(state.index)===1&&DeviceOrbNavigation.rootBack){DeviceOrbNavigation.rootBack();return;}
      if(Number(router.getLength())>1){router.back();return;}
      context?.moveAbilityToBackground().catch(()=>{});
    }catch(_){}
  }
}
