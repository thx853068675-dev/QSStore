/** Wait for committed input; an IME preview must also cancel an older pending search. */
export class InspectionSearch {
  private timer:number=-1;
  private closed:boolean=false;
  private apply:(query:string)=>void;
  constructor(apply:(query:string)=>void){this.apply=apply;}
  change(value:string,preview:string=''):void{
    if(this.closed)return;
    this.cancel();
    if(preview.length>0)return;
    const query=value.trim();
    if(!query){this.apply('');return;}
    this.timer=setTimeout(()=>{this.timer=-1;if(!this.closed)this.apply(query);},200);
  }
  private cancel():void{if(this.timer!==-1){clearTimeout(this.timer);this.timer=-1;}}
  close():void{this.closed=true;this.cancel();}
}
