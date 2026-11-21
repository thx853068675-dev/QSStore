const { test } = require('node:test'), assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { DeviceArtworkCatalog: C } = loadEts('data/DeviceArtworkCatalog');
function png(width, height, size = 40) {
  const bytes = new ArrayBuffer(size), data = new Uint8Array(bytes);
  data.set([137,80,78,71,13,10,26,10]); data.set([73,72,68,82],12);
  new DataView(bytes).setUint32(16,width); new DataView(bytes).setUint32(20,height); data[25]=6;
  return bytes;
}
function fixture(width=756,height=960) {
  const f={calls:[],released:[],width,height,packed:png(403,512)};
  const image={PixelMapFormat:{RGBA_8888:4},createImageSource:()=>({
    getImageInfo:async()=>({size:{width:f.width,height:f.height}}),
    createPixelMap:async opts=>{f.calls.push(opts);return{release:async()=>f.released.push('pixels')};},
    release:async()=>f.released.push('source')
  }),createImagePacker:()=>({packToData:async(_pixels,opts)=>{
    f.packOptions=opts;if(f.error)throw Error('codec failed');return f.packed;
  },release:async()=>f.released.push('packer')})};
  f.codec=loadEts('data/DeviceArtworkThumbnail',{'@kit.ImageKit':{image},
    './DeviceArtworkCatalog':{DeviceArtworkCatalog:C}}).DeviceArtworkThumbnail;
  return f;
}
test('Mate 70 Pro is reduced proportionally to 512px and re-encoded as transparent PNG',async()=>{
  const f=fixture(),result=await f.codec.encode(png(756,960,547970));
  assert.equal(result,f.packed);assert.equal(f.calls[0].desiredPixelFormat,4);
  assert.equal(f.calls[0].desiredSize.width,403);assert.equal(f.calls[0].desiredSize.height,512);
  assert.equal(f.packOptions.format,'image/png');assert.equal(f.packOptions.quality,100);
  assert.deepEqual(f.released,['packer','pixels','source']);assert(C.validPng(result,512));
});
test('small portraits are not upscaled',async()=>{
  const f=fixture(240,320);f.packed=png(240,320);await f.codec.encode(png(240,320));
  assert.equal(f.calls[0].desiredSize.width,240);assert.equal(f.calls[0].desiredSize.height,320);
});
test('5 MiB source is accepted, larger input is rejected before native decode',async()=>{
  const f=fixture();await f.codec.encode(png(756,960,5*1024*1024));assert.equal(f.calls.length,1);
  await assert.rejects(f.codec.encode(png(756,960,5*1024*1024+1)));assert.equal(f.calls.length,1);
});
test('bad encoded output and native codec failures release every acquired native object',async()=>{
  for(const mode of ['codec','opaque','too-large']){
    const f=fixture();if(mode==='codec')f.error=true;
    if(mode==='opaque'){f.packed=png(403,512);new Uint8Array(f.packed)[25]=2;}
    if(mode==='too-large')f.packed=png(756,960);
    await assert.rejects(f.codec.encode(png(756,960)));assert.deepEqual(f.released,['packer','pixels','source']);
  }
  const f=fixture(9000,9000);await assert.rejects(f.codec.encode(png(756,960)));
  assert.equal(f.calls.length,0);assert.deepEqual(f.released,['source']);
});
