export class ManagementSort {
  static key(value:string):string{return value==='expiry'?'expiry':'updated';}
  static direction(value:string):string{return value==='asc'?'asc':'desc';}
  static timestamp(value:string|number):number{
    if(typeof value==='number'&&!(value>0))return 0;
    if(typeof value==='string'&&/^\s*[+-]?\d+(?:\.\d+)?\s*$/.test(value)&&!(Number(value)>0))return 0;
    const numeric=Number(value),parsed=Number.isFinite(numeric)&&numeric>0?numeric:Date.parse(String(value));
    return Number.isFinite(parsed)&&parsed>0?(parsed<100000000000?parsed*1000:parsed):0;
  }
  static compare(a:number,b:number,direction:string,aKey:string,bKey:string):number{
    const unknown=Number(!(a>0))-Number(!(b>0));
    return unknown||((direction==='asc'?1:-1)*(a-b))||aKey.localeCompare(bKey);
  }
}
