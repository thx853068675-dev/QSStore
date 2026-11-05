import { common } from '@kit.AbilityKit';
import { ComponentContent, UIContext } from '@kit.ArkUI';
import { LevelOrder } from '@ohos.promptAction';
import { DeviceOrbOptions, deviceOrbBuilder } from './DeviceTargetOrb';

/** One in-app window overlay survives every router page. No system float permission. */
export class DeviceOrbHost {
  private static ui:UIContext|undefined;
  private static content:ComponentContent<DeviceOrbOptions>|undefined;
  static attached():boolean{return DeviceOrbHost.content!==undefined;}
  static install(ui:UIContext,context:common.UIAbilityContext):void{
    if(DeviceOrbHost.content)return;
    AppStorage.setOrCreate('deviceOrbOpened',false);
    AppStorage.setOrCreate('deviceOrbY',.64);AppStorage.setOrCreate('deviceOrbRight',true);
    try{ui.runScopedTask(()=>{
      const options=new DeviceOrbOptions(context);
      let content:ComponentContent<DeviceOrbOptions>|undefined;
      options.modalChanged=(modal:boolean)=>{
        const active=content;
        if(!active||DeviceOrbHost.content!==active||options.modal===modal)return;
        options.modal=modal;
        ui.runScopedTask(()=>active.update(options));
      };
      content=new ComponentContent(ui,wrapBuilder(deviceOrbBuilder),options);
      // API 18+ orders this with dialogs, unlike the ordinary page-only overlay.
      ui.getOverlayManager().addComponentContentWithOrder(content,LevelOrder.clamp(100000));
      DeviceOrbHost.ui=ui;DeviceOrbHost.content=content;
    });}catch(error){console.warn('Device overlay: '+String(error));}
  }
  static dispose():void{
    const ui=DeviceOrbHost.ui,content=DeviceOrbHost.content;
    DeviceOrbHost.ui=undefined;DeviceOrbHost.content=undefined;
    if(ui&&content)try{ui.runScopedTask(()=>{ui.getOverlayManager().removeComponentContent(content);content.dispose();});}catch(_){}
  }
}
