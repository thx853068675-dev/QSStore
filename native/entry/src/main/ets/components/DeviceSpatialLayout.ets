import { I18n } from '../data/I18n';
/** Every peer connects to the local hub. Upper links stay in the name-free gutter. */
export class DeviceSpatialLink {
  startX:number=0;
  startY:number=0;
  turnY:number=0;
  endX:number=0;
  endY:number=0;
  curved:boolean=false;
  points:number[][]=[];
}

/** Reserve complete name rows before placing the center hub or the next row. */
export class DeviceSpatialLayout {
  static readonly capacity:number=6;
  width:number;
  nameWidth:number;
  topHeight:number;
  bottomHeight:number;
  localHeight:number;
  diameter:number=64;
  private count:number;
  private columns:number=2;
  constructor(width:number,names:string[],localName:string=I18n.t('本机')){
    this.width=width;this.count=names.length;this.columns=this.count>4?3:2;
    this.nameWidth=this.columns===3?Math.max(40,(width-24)/3):Math.max(92,(width-24)/2);
    this.diameter=Math.min(64,this.nameWidth);
    this.topHeight=this.rowHeight(names.slice(0,this.columns));
    this.bottomHeight=this.rowHeight(names.slice(this.columns,DeviceSpatialLayout.capacity));
    this.localHeight=this.rowHeight([localName]);
  }
  nameHeight(name:string):number{
    let units=0;
    for(const character of name){units+=character===' '?0.34:/[\x21-\x7e]/.test(character)?0.72:1;}
    return Math.max(16,Math.ceil(units*12/this.nameWidth)*16);
  }
  private rowHeight(names:string[]):number{return this.diameter+8+Math.max(16,...names.map((name)=>this.nameHeight(name)))+4+14;}
  centerX():number{return this.count===1?this.width/4:this.width/2;}
  centerY():number{return this.count<=1?56:12+this.topHeight+24+this.diameter/2;}
  localBottom():number{return this.centerY()-this.diameter/2+this.localHeight;}
  x(index:number,count:number):number{
    if(count===1)return this.width*.75-this.nameWidth/2;
    if(this.columns===3){
      const column=count===5&&index===4?2:index%3;
      return column*(this.nameWidth+12);
    }
    if(count===3&&index===2)return (this.width-this.nameWidth)/2;
    return index%2===0?0:this.width-this.nameWidth;
  }
  y(index:number):number{return this.count===1?24:index<this.columns?12:this.localBottom()+24;}
  height(count:number):number{
    if(count===1)return Math.max(this.y(0)+this.topHeight,this.localBottom())+12;
    return count>this.columns?this.y(this.columns)+this.bottomHeight+12:this.localBottom()+12;
  }
  link(index:number):DeviceSpatialLink{
    const link=new DeviceSpatialLink(),cx=this.centerX(),cy=this.centerY();
    const nx=this.x(index,this.count)+this.nameWidth/2,ny=this.y(index)+this.diameter/2;
    if(this.columns===3){
      const column=this.count===5&&index===4?2:index%3;
      const side=column-1,radius=this.diameter/2;
      if(index<3){
        // Route above-name branches through the fixed gutters between columns.
        const gutter=column===2?2*this.nameWidth+18:this.nameWidth+6;
        link.startX=cx+side*6;link.startY=cy-radius-8;
        link.endX=nx+(nx<gutter?radius+4:-radius-4);link.endY=ny;
        const turn=12+this.topHeight+12;
        link.points=[[link.startX,link.startY],[link.startX,turn],[gutter,turn],[gutter,ny],[link.endX,link.endY]];
      }else{
        link.startX=cx+side*6;link.startY=this.localBottom()+4;
        link.endX=nx;link.endY=ny-radius-4;
        const turn=this.y(index)-12;
        link.points=[[link.startX,link.startY],[link.startX,turn],[nx,turn],[link.endX,link.endY]];
      }
      return link;
    }
    if(this.count===1){link.startX=cx+40;link.startY=cy;link.endX=nx-36;link.endY=ny;return link;}
    if(Math.abs(nx-cx)<1){link.startX=cx;link.startY=this.localBottom()+4;link.endX=nx;link.endY=ny-36;return link;}
    const side=nx<cx?-1:1,vertical=ny<cy?-1:1;
    link.startX=cx+side*6;link.startY=vertical>0?this.localBottom()+4:cy-Math.sqrt(40*40-6*6);
    link.turnY=ny-vertical*28;link.endX=nx-side*36;link.endY=ny;link.curved=true;
    return link;
  }
}
