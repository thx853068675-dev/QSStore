/** A row can leave the lazy viewport without losing typed input or its result. */
@Observed
export class DeviceLanDraft {
  port:string='';
  edited:boolean=false;
  busy:boolean=false;
  notice:string='';
  onNoticeChanged:()=>void=()=>{};
  private noticeTimer:number=-1;
  private noticeRevision:number=0;
  setNotice(value:string):void{
    if(this.noticeTimer!==-1)clearTimeout(this.noticeTimer);this.noticeTimer=-1;
    const revision=++this.noticeRevision;
    this.notice=value;this.onNoticeChanged();
    if(value)this.noticeTimer=setTimeout(()=>{
      if(revision!==this.noticeRevision)return;
      this.noticeTimer=-1;this.notice='';this.onNoticeChanged();
    },10000);
  }
  dispose():void{this.onNoticeChanged=()=>{};this.setNotice('');}
}
