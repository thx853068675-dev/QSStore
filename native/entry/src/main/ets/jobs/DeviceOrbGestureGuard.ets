import { window } from '@kit.ArkUI';

/** Protect app-delivered handle touches; restore the window after each sequence.
 * System-owned outer-edge gestures may not deliver Down here (verified on 6.1).
 * This is not a system gesture exclusion region.
 */
export class DeviceOrbGestureGuard {
  private static mainWindow:window.Window|undefined;
  private static original:boolean=true;
  private static active:boolean=false;
  private static suppressUntil:number=0;
  private static releaseTimer:number=-1;
  private static tail:Promise<void>=Promise.resolve();
  static attach(mainWindow:window.Window):void{
    DeviceOrbGestureGuard.detach();DeviceOrbGestureGuard.mainWindow=mainWindow;
    try{DeviceOrbGestureGuard.original=mainWindow.isGestureBackEnabled();}catch(_){DeviceOrbGestureGuard.original=true;}
  }
  private static clearTimer():void{
    if(DeviceOrbGestureGuard.releaseTimer!==-1){clearTimeout(DeviceOrbGestureGuard.releaseTimer);DeviceOrbGestureGuard.releaseTimer=-1;}
  }
  private static request(enabled:boolean):void{
    const mainWindow=DeviceOrbGestureGuard.mainWindow;if(!mainWindow)return;
    DeviceOrbGestureGuard.tail=DeviceOrbGestureGuard.tail.catch(()=>{}).then(async()=>{
      if(DeviceOrbGestureGuard.mainWindow!==mainWindow||enabled!==(DeviceOrbGestureGuard.active?false:DeviceOrbGestureGuard.original))return;
      await mainWindow.setGestureBackEnabled(enabled);
    }).catch((error:Error)=>{console.warn('Device handle back gesture: '+String(error));});
  }
  static begin():void{
    const wasActive=DeviceOrbGestureGuard.active;
    DeviceOrbGestureGuard.clearTimer();DeviceOrbGestureGuard.active=true;DeviceOrbGestureGuard.suppressUntil=0;
    if(!wasActive)DeviceOrbGestureGuard.request(false);
    console.debug('Device handle gesture begin');
    DeviceOrbGestureGuard.releaseTimer=setTimeout(()=>DeviceOrbGestureGuard.release(),30000);
  }
  static end(cancelled:boolean=false):void{
    if(!DeviceOrbGestureGuard.active)return;
    const delay=cancelled?1600:280;
    DeviceOrbGestureGuard.clearTimer();DeviceOrbGestureGuard.active=false;DeviceOrbGestureGuard.suppressUntil=Date.now()+delay;
    DeviceOrbGestureGuard.request(DeviceOrbGestureGuard.original);
    console.debug('Device handle gesture end, cancelled='+cancelled);
    DeviceOrbGestureGuard.releaseTimer=setTimeout(()=>{
      DeviceOrbGestureGuard.releaseTimer=-1;if(!DeviceOrbGestureGuard.active)DeviceOrbGestureGuard.suppressUntil=0;
    },delay);
  }
  static blocksBack():boolean{return DeviceOrbGestureGuard.active||Date.now()<DeviceOrbGestureGuard.suppressUntil;}
  static release():void{
    const held=DeviceOrbGestureGuard.active||DeviceOrbGestureGuard.suppressUntil>0||DeviceOrbGestureGuard.releaseTimer!==-1;
    DeviceOrbGestureGuard.clearTimer();DeviceOrbGestureGuard.active=false;DeviceOrbGestureGuard.suppressUntil=0;
    if(held)DeviceOrbGestureGuard.request(DeviceOrbGestureGuard.original);
  }
  static detach():void{
    const mainWindow=DeviceOrbGestureGuard.mainWindow,original=DeviceOrbGestureGuard.original;
    DeviceOrbGestureGuard.clearTimer();DeviceOrbGestureGuard.active=false;DeviceOrbGestureGuard.suppressUntil=0;DeviceOrbGestureGuard.mainWindow=undefined;
    if(mainWindow)DeviceOrbGestureGuard.tail=DeviceOrbGestureGuard.tail.catch(()=>{}).then(()=>mainWindow.setGestureBackEnabled(original)).catch(()=>{});
  }
}
