const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {loadEts}=require('./load_ets.cjs');
const {DeviceArtworkCatalog:C}=loadEts('data/DeviceArtworkCatalog');
const raw=fs.readFileSync(path.join(__dirname,'../entry/src/main/resources/rawfile/device-art/catalog.json'),'utf8');
const rows=C.parse(raw);
const {DeviceInstallTarget:T}=loadEts('jobs/DeviceInstallTarget');
test('actual local and remote market models use the correct transparent official product art',()=>{
 assert(rows.length>250);
 for(const [kind,model,market,name] of [
  ['phone','HBN-AL00','HUAWEI Pura 70 Pro','HUAWEI Pura 70 Pro'],
  ['phone','VDE-AL10','HUAWEI Pura X 典藏版','HUAWEI Pura X'],
  ['tablet','arbitrary','HUAWEI MatePad Pro 13.2 英寸','HUAWEI MatePad Pro 13.2 英寸'],
  ['pc','arbitrary','HUAWEI MateBook Pro','HUAWEI MateBook Pro'],
 ]){assert.equal(C.match(rows,kind,model,market).name,name);}
 for(const [kind,model,market] of [['pc','emulator','emulator'],['pc','simulator','HUAWEI MateBook Pro'],
  ['tablet','','Pura 70 Pro'],['phone','','Pura 70 Pro wrong variant'],['phone','UNKNOWN-AL00','']]){
  assert.equal(C.match(rows,kind,model,market),undefined);
 }
 assert.notEqual(C.match(rows,'phone','','Pura70 Pro').image,C.match(rows,'phone','','Pura 70 Pro+').image);
});
test('format normalization is precise, and arbitrary hosts or malformed index records are rejected',()=>{
 assert.equal(C.normalize(' HUAWEI MatePad Pro 13.2 英寸 '),'matepadpro13.2');
 assert.equal(C.normalize('华为 Pura-70_Pro'),'pura70pro');
 for(const url of ['http://consumer.huawei.com/content/dam/huawei-cbg-site/a.png',
  'https://evil.com/a.png','https://consumer.huawei.com.evil.com/content/dam/huawei-cbg-site/a.png',
  'https://consumer.huawei.com/content/dam/huawei-cbg-site/../a.png',
  'https://consumer.huawei.com/content/dam/huawei-cbg-site/%2e%2e/a.png'])assert(!C.validUrl(url));
 assert.equal(C.parse(JSON.stringify({products:[{name:'x',kind:'phone',image:'https://evil.com/a.png'}]})).length,0);
});
test('legacy remote records and bad optional art metadata cannot invalidate a usable installation target',()=>{
 const legacy={key:'b'.repeat(64),udid:'b'.repeat(64),kind:'phone',name:'HUAWEI Pura X',host:'192.168.3.160',port:43329};
 let row=T.parse(JSON.stringify(legacy));assert.equal(row.model,'');assert.equal(row.marketName,legacy.name);
 row=T.parse(JSON.stringify({...legacy,model:{bad:true},marketName:'bad\nname'}));
 assert.equal(row.model,'');assert.equal(row.marketName,legacy.name);assert.equal(row.key,legacy.key);
 T.localModel='HBN-AL00';T.localMarketName='HUAWEI Pura 70 Pro';
 try{row=T.parse('');assert.equal(row.model,'HBN-AL00');assert.equal(row.marketName,'HUAWEI Pura 70 Pro');}finally{T.localModel='';T.localMarketName='';}
});
function png(w=378,h=480,color=6){let b=new ArrayBuffer(40),u=new Uint8Array(b);u.set([137,80,78,71,13,10,26,10],0);u.set([73,72,68,82],12);let v=new DataView(b);v.setUint32(16,w);v.setUint32(20,h);u[25]=color;return b;}
test('image validation bounds the decoded size and rejects non-transparent or non-PNG responses',()=>{
 assert(C.validPng(png()));assert(!C.validPng(png(9999,9999)));assert(!C.validPng(png(378,480,2)));
 assert(!C.validPng(new ArrayBuffer(600*1024)));assert(!C.validPng(new TextEncoder().encode('<html>Error</html>').buffer));
});
function setup(){
 const files=new Map(),directories=new Set(),requests=[];let nextFd=1;const handles=new Map();
 const stat=p=>{if(!files.has(p)&&!directories.has(p))throw Error('missing');return {isFile:()=>files.has(p),isDirectory:()=>directories.has(p),isSymbolicLink:()=>false,size:files.get(p)?.byteLength??0,mtime:1}};
 const fileIo={OpenMode:{READ_ONLY:1,WRITE_ONLY:2,CREATE:4,TRUNC:8,NOFOLLOW:16},
 accessSync:p=>files.has(p)||directories.has(p),mkdirSync:p=>directories.add(p),lstat:async p=>stat(p),
 open:async(p,mode)=>{let fd=nextFd++;handles.set(fd,{path:p,at:0});if(mode&8)files.set(p,new ArrayBuffer(0));return{fd}},
 close:async f=>handles.delete(f.fd),write:async(fd,bytes)=>{files.set(handles.get(fd).path,bytes);return bytes.byteLength},
 read:async(fd,bytes)=>{let h=handles.get(fd),b=files.get(h.path),part=b.slice(h.at,h.at+bytes.byteLength);new Uint8Array(bytes).set(new Uint8Array(part));h.at+=part.byteLength;return part.byteLength},
 renameSync:(a,b)=>{files.set(b,files.get(a));files.delete(a)},unlinkSync:p=>files.delete(p),
 listFile:async dir=>Array.from(files.keys()).filter(p=>p.startsWith(dir+'/')).map(p=>p.slice(dir.length+1))};
 let networkResolve;let response=()=>new Promise(resolve=>networkResolve=resolve),allowed=true,frameReads=0,frameResponse=async()=>({contentWidth:.55,contentHeight:.94});
 const http={RequestMethod:{GET:'GET'},HttpDataType:{ARRAY_BUFFER:1},createHttp:()=>({request:(url,options)=>{requests.push({url,options});return response()},destroy(){}})};
 const {DeviceArtwork:A}=loadEts('data/DeviceArtwork',{'@kit.CoreFileKit':{fileIo},'@kit.NetworkKit':{http},
  '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeWithStream:()=>raw})}}},
  './DeviceArtworkCatalog':{DeviceArtworkCatalog:C},'./PrivacyConsent':{PrivacyConsent:{isBusinessAllowed:()=>allowed}},
  './DeviceArtworkFrame':{DeviceArtworkFrame:{clear(){},load:async()=>{frameReads++;return frameResponse();}}},
  '../jobs/ForegroundIdle':{ForegroundIdle:{wait:async()=>{}}}}, {ArrayBuffer,Uint8Array,DataView});
 const context={cacheDir:'/cache',resourceManager:{getRawFileContent:async()=>new Uint8Array()}};
 return{A,context,requests,files,resolve:()=>networkResolve({responseCode:200,result:png()}),setResponse:f=>response=f,setAllowed:v=>allowed=v,frameReads:()=>frameReads,setFrameResponse:f=>frameResponse=f};
}
const settle=async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
test('simultaneous local and remote portraits coalesce, persist and reload without network',async()=>{
 const s=setup(),one=s.A.load(s.context,'phone','HBN-AL00',''),two=s.A.load(s.context,'phone','','Pura 70 Pro');
 await settle();assert.equal(s.requests.length,1);assert.equal(s.requests[0].options.maxRedirects,0);s.resolve();
 const [a,b]=await Promise.all([one,two]);assert.equal(a,b);assert(a.startsWith('file:///cache/device-art/'));
 assert.equal(s.files.size,1);assert.equal(await s.A.load(s.context,'phone','HBN-AL00',''),a);assert.equal(s.requests.length,1);
 assert.equal(await s.A.size(s.context),40);await s.A.clear(s.context);assert.equal(s.files.size,0);
});
test('clearing an in-flight request prevents a late download from restoring deleted cache',async()=>{
 const s=setup(),one=s.A.load(s.context,'phone','HBN-AL00','');await settle();assert.equal(s.requests.length,1);
 await s.A.clear(s.context);s.resolve();assert.equal(await one,'');assert.equal(s.files.size,0);
});
test('missing art, offline responses and withdrawn network consent keep a harmless symbol fallback',async()=>{
 const s=setup();assert.equal(await s.A.load(s.context,'pc','emulator','emulator'),'');assert.equal(s.requests.length,0);
 s.setAllowed(false);assert.equal(await s.A.load(s.context,'phone','HBN-AL00',''),'');assert.equal(s.requests.length,0);
 s.setAllowed(true);s.setResponse(async()=>{throw Error('offline')});assert.equal(await s.A.load(s.context,'phone','HBN-AL00',''),'');
 assert.equal(await s.A.load(s.context,'phone','HBN-AL00',''),'');assert.equal(s.requests.length,1);
});

test('a warm portrait restores the exact model and frame synchronously across repeated capsule remounts',async()=>{
 const s=setup(),args=[s.context,'phone','VDE-AL10','HUAWEI Pura X 典藏版'];
 assert.equal(s.A.cached(...args),undefined);
 const pending=s.A.portrait(...args);await settle();s.resolve();const portrait=await pending;
 assert(portrait.source.startsWith('file:///cache/device-art/'));assert.equal(portrait.frame.contentWidth,.55);
 for(let i=0;i<20;i++){assert.equal(s.A.cached(...args),portrait);assert.equal(await s.A.portrait(...args),portrait);}
 assert.equal(s.requests.length,1);assert.equal(s.frameReads(),1);
 assert.equal(s.A.cached(s.context,'phone','HBN-AL00','HUAWEI Pura 70 Pro'),undefined,'a different model must never inherit Pura X');
 assert.equal(s.A.cached({...s.context,cacheDir:'/other'},...args.slice(1)),undefined,'contexts must not share a sandbox path');
 s.A.invalidate(portrait.source);assert.equal(s.A.cached(...args),undefined);
 const restored=await s.A.portrait(...args);assert.equal(restored.source,portrait.source);assert.equal(s.requests.length,1,'recover from the retained disk file');
 await s.A.clear(s.context);assert.equal(s.A.cached(...args),undefined);
});

test('cache clearing during silhouette decoding cannot repopulate a stale ready portrait',async()=>{
 const s=setup(),args=[s.context,'phone','VDE-AL10','HUAWEI Pura X'];let finish;
 s.setFrameResponse(()=>new Promise(resolve=>finish=resolve));
 const pending=s.A.portrait(...args);await settle();s.resolve();
 for(let i=0;i<8&&!finish;i++)await settle();assert(finish);
 await s.A.clear(s.context);finish({contentWidth:.55,contentHeight:.94});
 assert.equal(await pending,undefined);assert.equal(s.A.cached(...args),undefined);
});

test('product nodes have no circular fill or ring and keep adaptive text; toolbar glass stays intact',()=>{
 const s=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceGlassCircle.ets'),'utf8');
 assert(s.includes('if(this.deviceKind){'));assert(s.includes('this.circleContent(false)'));
 assert(s.includes('ButtonType.Normal:ButtonType.Circle'));
 assert(s.includes('!this.deviceKind&&!immersive&&this.selected'));
 assert(s.includes('width:this.deviceKind||immersive?0:1'));
 assert(s.includes('DevicePanelInk.icon(this.darkMode,this.materialMode)'));
 assert(s.includes('attributeModifier(this.inlineMaterial())'));
});

test('selecting or connecting a known device keeps its product image mounted while only the corner changes',()=>{
 const s=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/DeviceGlassCircle.ets'),'utf8');
 const body=s.slice(s.indexOf('@Builder private circleContent'));
 assert(body.indexOf('if(this.deviceKind){this.deviceIcon()}')<body.indexOf('else if(this.loading)'));
 const icon=s.slice(s.indexOf('@Builder private deviceIcon'),s.indexOf('@Builder private circleContent'));
 assert(icon.indexOf('DevicePortrait(')<icon.indexOf('if(this.loading)'));
});
