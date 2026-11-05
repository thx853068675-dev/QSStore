import { DeviceGlassCircle } from './DeviceGlassCircle';

@Component
export struct DevicePanelAction {
  @Prop symbol:Resource=$r('sys.symbol.xmark');
  @Prop active:boolean=true;
  @Prop destructive:boolean=false;
  @Prop loading:boolean=false;
  controlId:string='';
  @Prop label:string='';
  action:()=>void=()=>{};
  build(){
    DeviceGlassCircle({inline:true,diameter:36,symbol:this.symbol,visible:this.active,destructive:this.destructive,
      loading:this.loading,repeatWhileLoading:true,
      controlId:this.controlId,label:this.label,action:this.action})
  }
}
