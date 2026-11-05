import { DeviceDiscoveryContent } from './DeviceDiscoveryContent';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';

/** Reconnect-only host; ordinary device selection lives in the morphing capsule. */
@Component
export struct MultiDeviceDialog {
  @StorageProp('darkMode') private darkMode:boolean=false;
  maxHeight:number=680;
  expectedUdid:string='';
  onClose:()=>void=()=>{};
  onSelected:()=>void=()=>{};
  onConnected:(target:DeviceInstallTarget)=>void=()=>{};
  @State private dialogHeight:number=360;
  aboutToAppear():void{AppStorage.setOrCreate('deviceDiscoveryVisible',true);}
  aboutToDisappear():void{AppStorage.setOrCreate('deviceDiscoveryVisible',false);}
  build(){
    Stack({alignContent:Alignment.Center}){
      Column().width('100%').height('100%').backgroundColor(Palette.forMode(this.darkMode).scrim).onClick(()=>this.onClose())
      DeviceDiscoveryContent({expectedUdid:this.expectedUdid,maxHeight:this.maxHeight,
        onHeightChanged:(height:number)=>{this.dialogHeight=height;},onClose:this.onClose,onSelected:this.onSelected,onConnected:this.onConnected})
        .width('calc(100% - 40vp)').constraintSize({maxWidth:StoreLayout.sheetWidth}).height(Math.min(this.maxHeight,this.dialogHeight))
        .backgroundColor(Palette.forMode(this.darkMode).surface).borderRadius(StoreLayout.dialogRadius).clip(true)
    }.width('100%').height('100%')
  }
}
