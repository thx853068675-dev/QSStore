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
function navigationPage(api, dark, foreground) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = source.indexOf('  private navigationColor(');
  const method = source.slice(start, source.indexOf('\n  }', start) + 4).replace('private ', '');
  const box = { exports: {}, deviceInfo: { sdkApiVersion: api } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${method} } exports.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return Object.assign(new box.exports.Page(), { darkMode: dark, navigationForeground: foreground,
    colors: () => ({ accent: '#2463E9', tabIdle: '#66758D' }) });
}
test('API 24/25 keep black day and white night navigation even above opposite-colored cards', () => {
  for (const api of [24, 25]) for (const dark of [false, true]) {
    const page = navigationPage(api, dark, [{ idle: dark ? '#000000' : '#FFFFFF', selected: '#2463E9' }]);
    for (const index of [0, 1, 2, 3]) for (const selected of [false, true]) {
      assert.equal(page.navigationColor(index, selected), dark ? '#FFFFFF' : '#000000');
    }
  }
});
test('API 26 retains per-region adaptive navigation and its visible initial theme colors', () => {
  const page = navigationPage(26, false, [{ idle: '#FFFFFF', selected: '#BDD3FF' }]);
  assert.equal(page.navigationColor(0, false), '#FFFFFF');
  assert.equal(page.navigationColor(0, true), '#BDD3FF');
  assert.equal(page.navigationColor(1, false), '#66758D');
  assert.equal(page.navigationColor(1, true), '#2463E9');
});
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
  const timers = new Map(), published = []; let id = 0, active = true, failure = false, reads = 0;
  let backdrop = { background: '#FFFFFF', regions: [] };
  const ui = { vp2px: v => v * 3, getComponentSnapshot: () => { throw Error('Must not render/capture the page'); },
    getComponentUtils: () => ({ getRectangleById: key => {
      reads++; if (failure) throw Error('not mounted');
      return { size: {width:40,height:24}, windowOffset:{x:50+Number(key.at(-1))*40,y:280} };
    } }) };
  const { NavigationContrastSampler } = load('NavigationContrastSampler', {'./NavigationContrast': {NavigationContrast:contrast}}, {
    setTimeout: fn => {timers.set(++id,fn);return id;}, clearTimeout: key => timers.delete(key)
  });
  const sampler = new NavigationContrastSampler(ui, () => active, colors => published.push(colors), () => backdrop, bottomMargin);
  return {sampler,timers,published,active:v=>active=v,fail:v=>failure=v,reads:()=>reads,
    paint:v=>backdrop=v,flush:()=>{for(const [key,fn] of [...timers]){timers.delete(key);fn();}}};
}
test('mounted page paints determine per-tab contrast without snapshots or GPU readback', () => {
  const f=fixture();f.paint({background:'#FFFFFF',regions:[{left:50,top:280,width:40,height:24,radius:0,color:'#17365E'}]});
  f.sampler.request();f.sampler.request();assert.equal(f.timers.size,1);f.flush();
  assert.equal(f.reads(),4);assert.equal(f.published.length,1);
  assert.equal(f.published[0][0].idle,'#FFFFFF');assert.equal(f.published[0][1].idle,'#17213A');
  f.sampler.request();f.flush();assert.equal(f.published.length,1,'unchanged paints do not dirty navigation');
  f.sampler.reset();f.sampler.request();f.flush();assert.equal(f.published.length,2);
});
test('rounded gaps and floating HDS translation use window coordinates at the actual display density', () => {
  const f=fixture(20);f.paint({background:'#FFFFFF',regions:[{left:50,top:220,width:40,height:24,radius:0,color:'#09152D'}]});
  f.sampler.request();f.flush();assert.equal(f.published[0][0].idle,'#FFFFFF');
  const small={background:'#FFFFFF',regions:[{left:0,top:0,width:40,height:20,radius:10,color:'#09152D'}]};
  assert.equal(contrast.paint({left:0,top:0,width:4,height:4},small).idle,'#17213A','outside a rounded corner stays light');
});
test('continuous scrolling updates changing backgrounds once per throttle without starving the update', () => {
  const f=fixture();f.sampler.motion();const first=[...f.timers.keys()][0];
  for(let i=0;i<100;i++)f.sampler.motion();assert.deepEqual([...f.timers.keys()],[first]);f.flush();
  assert.equal(f.published.length,1);f.paint({background:'#111728',regions:[]});f.sampler.motion();f.flush();
  assert(f.published[1].every(c=>c.idle==='#FFFFFF'));
});
test('background and failed geometry preserve foreground; theme/tab resets recover without stale captures', () => {
  const f=fixture();f.active(false);f.sampler.request();assert.equal(f.timers.size,0);
  f.active(true);f.fail(true);f.sampler.request();f.flush();assert.equal(f.published.length,0);
  f.fail(false);f.sampler.request();f.sampler.cancel();f.flush();assert.equal(f.published.length,0);
  f.sampler.request();f.flush();assert.equal(f.published.length,1);
  f.paint({background:'#09152D',regions:[]});f.sampler.reset();f.sampler.request();f.flush();
  assert.equal(f.published.length,2);assert(f.published[1].every(c=>c.idle==='#FFFFFF'));
});
test('every featured gradient stop keeps light foreground, regardless of its tier or theme', () => {
  for(const color of ['#09152D','#17365E','#563968','#302758','#4E438C','#604279','#204BC0','#3263D5','#426BD3']) {
    assert.equal(contrast.paint(region,{background:color,regions:[]}).idle,'#FFFFFF',color);
  }
});
