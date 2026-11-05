const {test}=require('node:test'),assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {DeviceArtworkFrame:F}=loadEts('data/DeviceArtworkFrame',{'@kit.ImageKit':{image:{}}});
function rgba(w,h,left,top,width,height){
 const b=new Uint8Array(w*h*4);for(let y=top;y<top+height;y++)for(let x=left;x<left+width;x++)b[(y*w+x)*4+3]=255;return b;
}
test('different PNG padding yields equal visible heights and centers without stretching the body',()=>{
 for(const [w,h,l,t,bw,bh] of [[100,200,30,20,35,150],[200,200,60,40,60,110],[256,128,80,10,60,100]]){
  const b=rgba(w,h,l,t,bw,bh);b[3]=12;const f=F.fromRgba(b,w,h);
  assert(Math.abs(f.height*bh/h-.94)<1e-8);
  assert(Math.abs(f.x+(l+bw/2)/w*f.width-.5)<1e-8);
  assert(Math.abs(f.y+(t+bh/2)/h*f.height-.5)<1e-8);
  assert(Math.abs(f.width/f.height-w/h)<1e-8);
  assert(Math.abs(f.contentWidth-f.width*bw/w)<1e-8);
  assert(Math.abs(f.contentHeight-f.height*bh/h)<1e-8);
 }
 const wide=F.fromRgba(rgba(200,100,10,30,180,50),200,100);
 assert(Math.abs(wide.width*180/200-.94)<1e-8);
 assert.deepEqual({...F.fromRgba(new Uint8Array(16),2,2)},{x:0,y:0,width:1,height:1,contentWidth:1,contentHeight:1});
 assert.deepEqual({...F.fromRgba(new Uint8Array(4),10000,10000)},{x:0,y:0,width:1,height:1,contentWidth:1,contentHeight:1});
});
test('matching portraits share one bounded decode, release native images and can reload after clearing',async()=>{
 let sources=0,pixelsReleased=0,sourcesReleased=0;
 const image={PixelMapFormat:{RGBA_8888:1},createImageSource:()=>{
  sources++;return{getImageInfo:async()=>({size:{width:400,height:800}}),
   createPixelMap:async options=>{
    assert.equal(options.desiredSize.width,128);assert.equal(options.desiredSize.height,256);
    return{getImageInfo:async()=>({size:{width:128,height:256}}),readPixelsToBuffer:async b=>new Uint8Array(b).set(rgba(128,256,40,20,48,220)),release:async()=>pixelsReleased++};
   },release:async()=>sourcesReleased++};
 }};
 const {DeviceArtworkFrame:A}=loadEts('data/DeviceArtworkFrame',{'@kit.ImageKit':{image}});
 const [one,two]=await Promise.all([A.load('file:///cache/pura.png'),A.load('file:///cache/pura.png')]);
 assert.equal(one,two);assert.equal(sources,1);assert.equal(pixelsReleased,1);assert.equal(sourcesReleased,1);
 A.clear();await A.load('file:///cache/pura.png');assert.equal(sources,2);
});
