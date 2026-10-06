const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function load(name, mocks = {}, globals = {}) {
  const box = { exports: {}, console: { info() {}, warn() {} }, ...globals, require: key => mocks[key] ||
    (key === '@kit.PerformanceAnalysisKit' ? {hilog:{info(){},warn(){}}} : {}) };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/theme', name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return box.exports;
}
const { NavigationContrast: contrast } = load('NavigationContrast');
function bgra(w, h, color) {
  const bytes = new Uint8Array(w * h * 4);
  for (let i = 0; i < bytes.length; i += 4) bytes.set(color, i);
  return bytes;
}
const region = { left: 0, top: 0, width: 40, height: 20 };
test('each native navigation region gets readable foregrounds from its own background', () => {
  const bytes = bgra(160, 20, [255, 255, 255, 255]);
  for (let y = 0; y < 20; y++) for (let x = 40; x < 80; x++) bytes.set([0, 0, 0, 255], (y * 160 + x) * 4);
  assert.equal(contrast.sample(bytes, 160, 20, region).idle, '#17213A');
  const dark = contrast.sample(bytes, 160, 20, { ...region, left: 40 });
  assert.equal(dark.idle, '#FFFFFF'); assert.equal(dark.selected, '#BDD3FF');
  assert.equal(contrast.sample(bytes, 160, 20, { ...region, left: 80 }).selected, '#2463E9');
});
test('BGRA channel order is honored and icon/label ink does not drive color oscillation', () => {
  assert.equal(contrast.sample(bgra(40, 20, [255, 0, 0, 255]), 40, 20, region).idle, '#FFFFFF');
  const bytes = bgra(40, 20, [255, 255, 255, 255]);
  for (let y = 0; y < 20; y++) for (let x = 11; x < 29; x++) bytes.set([0, 0, 0, 255], (y * 40 + x) * 4);
  assert.equal(contrast.sample(bytes, 40, 20, region).idle, '#17213A');
});
test('glass reflections and dark rims cannot reverse its dominant light/dark background', () => {
  for (const [background, reflection, expected] of [
    [[84, 84, 84, 255], [255, 255, 255, 255], '#FFFFFF'],
    [[200, 200, 200, 255], [16, 16, 16, 255], '#17213A']
  ]) {
    const bytes = bgra(40, 20, background);
    // Four reflection/rim pixels among 32 background samples: old worst-case
    // scoring picked the opposite foreground in both of these real glass cases.
    for (const x of [4, 8, 31, 35]) bytes.set(reflection, (3 * 40 + x) * 4);
    assert.equal(contrast.sample(bytes, 40, 20, region).idle, expected);
  }
});
test('a clear background change overrides the previous opposite foreground', () => {
  const dark = {idle:'#17213A',selected:'#2463E9'}, light = {idle:'#FFFFFF',selected:'#BDD3FF'};
  assert.equal(contrast.sample(bgra(40, 20, [40, 40, 40, 255]), 40, 20, region, dark).idle, '#FFFFFF');
  assert.equal(contrast.sample(bgra(40, 20, [240, 240, 240, 255]), 40, 20, region, light).idle, '#17213A');
});
test('invalid, unpainted and transparent snapshots preserve the existing theme colors', () => {
  assert.equal(contrast.sample(bgra(40, 20, [0, 0, 0, 0]), 40, 20, region), undefined);
  assert.equal(contrast.sample(new Uint8Array(2), 40, 20, region), undefined);
  for (const bad of [{ ...region, left: -1 }, { ...region, width: 100 }, { ...region, top: NaN }]) {
    assert.equal(contrast.sample(bgra(40, 20, [255, 255, 255, 255]), 40, 20, bad), undefined);
  }
});
function fixture(bottomMargin = 0) {
  const timers = new Map(), published = [], crops = [], requests = [];
  let id = 0, active = true, calls = 0, releases = 0, failure = false;
  let contentId = 'navigation-content-0', dimensions = {width:60,height:75};
  let snapshot = async () => pixels;
  const pixels = {
    getImageInfo: async () => ({ size: dimensions }),
    readPixels: async area => { crops.push(area.region); new Uint8Array(area.pixels).set(bgra(area.region.size.width, area.region.size.height, [255, 255, 255, 255])); },
    release: async () => { releases++; }
  };
  const ui = {
    vp2px: value => value * 3,
    getComponentUtils: () => ({ getRectangleById: key => {
      if (failure) throw new Error('not mounted');
      if (key.startsWith('navigation-content-')) return { size: { width: 240, height: 300 }, windowOffset: { x: 10, y: 20 } };
      return { size: { width: 40, height: 24 }, windowOffset: { x: 50 + Number(key.at(-1)) * 40, y: 280 } };
    }}),
    getComponentSnapshot: () => ({ get: async (key, options) => {
      calls++; requests.push({key,options});
      dimensions={width:Math.round(240*options.scale),height:Math.round(300*options.scale)};
      return snapshot();
    } })
  };
  const { NavigationContrastSampler } = load('NavigationContrastSampler', { './NavigationContrast': { NavigationContrast: contrast }, '@kit.ArkUI': {window:{findWindow: () => {throw new Error('Never sample the glass-composited window');}}} }, {
    setTimeout: fn => { timers.set(++id, fn); return id; }, clearTimeout: key => timers.delete(key)
  });
  const sampler = new NavigationContrastSampler(ui, () => active, rows => published.push(rows), () => contentId, bottomMargin);
  return { sampler, timers, published, crops, requests, pixels, calls: () => calls, releases: () => releases,
    source: value => { contentId=value; },
    active: value => { active = value; }, fail: value => { failure = value; }, snapshot: fn => { snapshot = fn; },
    flush: async () => { for (const [key, fn] of [...timers]) { timers.delete(key); fn(); } await new Promise(setImmediate); } };
}
test('capture reads only underlying page content, excluding the floating glass and its foreground', async () => {
  const f = fixture(); f.sampler.request(); f.sampler.request(); assert.equal(f.timers.size, 1);
  await f.flush(); assert.equal(f.calls(), 1); assert.equal(f.published.length, 1); assert.equal(f.releases(), 1);
  assert.deepEqual(JSON.parse(JSON.stringify(f.requests[0])), {key:'navigation-content-0',options:{scale:0.25,waitUntilRenderFinished:true}});
  assert.deepEqual(JSON.parse(JSON.stringify(f.crops[0])), {x:10,y:65,size:{width:40,height:6}});
  assert.equal(f.timers.size, 0);
  f.sampler.request(); await f.flush(); assert.equal(f.published.length, 1); assert.equal(f.releases(), 2);
  f.sampler.reset(); f.sampler.request(); await f.flush(); assert.equal(f.published.length, 2);
});
test('HDS floating parent translation is applied using the current display density', async () => {
  const f = fixture(20); f.sampler.request(); await f.flush();
  assert.deepEqual(JSON.parse(JSON.stringify(f.crops[0])), {x:10,y:50,size:{width:40,height:6}});
  assert.equal(f.published.length, 1);
});
test('a capture from the previous page cannot set colors after changing the selected tab', async () => {
  const f=fixture(); let release; f.snapshot(()=>new Promise(resolve=>{release=resolve;}));
  f.sampler.request(); await f.flush(); f.source('navigation-content-2'); release(f.pixels);
  await new Promise(setImmediate); assert.equal(f.published.length,0); assert.equal(f.releases(),1);
  f.snapshot(async()=>f.pixels); f.sampler.request(); await f.flush();
  assert.equal(f.requests.at(-1).key,'navigation-content-2'); assert.equal(f.published.length,1);
});
test('scroll frames share one leading capture instead of starving a debounced update', async () => {
  const f = fixture(); f.sampler.motion(); const first = [...f.timers.keys()][0];
  for (let i = 0; i < 100; i++) f.sampler.motion();
  assert.deepEqual([...f.timers.keys()], [first]); await f.flush();
  assert.equal(f.calls(), 1); assert.equal(f.published.length, 1); assert.equal(f.timers.size, 0);
  f.active(false); f.sampler.motion(); assert.equal(f.timers.size, 0);
});
test('background, stale and failed captures never overwrite a native foreground or poison recovery', async () => {
  const f = fixture(); f.active(false); f.sampler.request(); assert.equal(f.timers.size, 0);
  f.active(true); f.fail(true); f.sampler.request(); await f.flush(); assert.equal(f.calls(), 0);
  f.fail(false); let release; f.snapshot(() => new Promise(resolve => { release = resolve; }));
  f.sampler.request(); await f.flush(); f.sampler.cancel(); f.active(false); release(f.pixels);
  await new Promise(setImmediate); assert.equal(f.published.length, 0); assert.equal(f.releases(), 1);
  assert.equal(f.timers.size, 0);
  f.active(true); f.snapshot(async () => { throw new Error('capture unavailable'); });
  f.sampler.request(); await f.flush(); assert.equal(f.published.length, 0);
  f.snapshot(async () => f.pixels); f.sampler.request(); await f.flush(); assert.equal(f.published.length, 1);
});
test('requests during a native capture keep only one fresh follow-up', async () => {
  const f = fixture(); let release; f.snapshot(() => new Promise(resolve => { release = resolve; }));
  f.sampler.request(); await f.flush(); f.sampler.request(); await f.flush();
  assert.equal(f.calls(), 1); release(f.pixels); await new Promise(setImmediate);
  assert.equal(f.published.length, 0); assert.equal(f.timers.size, 1);
  f.snapshot(async () => f.pixels); await f.flush(); assert.equal(f.calls(), 2);
  assert.equal(f.published.length, 1); assert.equal(f.releases(), 2); assert.equal(f.timers.size, 0);
});
