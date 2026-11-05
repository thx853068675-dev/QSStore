import { NearbyDevice } from '../jobs/DeviceDiscovery';

/** Derived membership is stable across heartbeat and scan-progress notifications. */
export class DeviceDiscoveryIndex {
  connections:NearbyDevice[]=[];
  addresses:NearbyDevice[]=[];
  private rows:NearbyDevice[]|undefined;
  private hosts:string[]|undefined;
  private byHost:Map<string,NearbyDevice>=new Map();
  private pageRows:NearbyDevice[]|undefined;
  private pageIndex:number=-1;
  private pageSize:number=0;
  private pageValue:NearbyDevice[]=[];

  refresh(rows:NearbyDevice[],hosts:string[]):void{
    if(this.rows===rows&&this.hosts===hosts)return;
    this.rows=rows;this.hosts=hosts;
    const peers=rows.filter((row)=>row.debugDetected);
    if(peers.length!==this.connections.length||peers.some((row,index)=>row!==this.connections[index]))this.connections=peers;
    const present=new Set(hosts),next=new Map<string,NearbyDevice>();
    rows.forEach((row)=>{if(present.has(row.host))next.set(row.host,row);});
    if(next.size===this.byHost.size&&Array.from(next.keys()).every((host)=>this.byHost.get(host)===next.get(host)))return;
    this.byHost=next;
    const numeric=new Map<string,number>();
    next.forEach((_,host)=>numeric.set(host,host.split('.').reduce((value:number,part:string)=>value*256+Number(part),0)));
    this.addresses=Array.from(next.values()).sort((a,b)=>numeric.get(a.host)!-numeric.get(b.host)!);
  }
  page(index:number,size:number):NearbyDevice[]{
    if(this.pageRows!==this.connections||this.pageIndex!==index||this.pageSize!==size){
      this.pageRows=this.connections;this.pageIndex=index;this.pageSize=size;
      this.pageValue=this.connections.slice(index*size,(index+1)*size);
    }
    return this.pageValue;
  }
}
