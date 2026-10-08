const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/BouncingAppName.ets'), 'utf8');
function fixture() {
  const timers = new Map(), animations = []; let next = 0;
  const names = ['halt', 'restart', 'updateActivity', 'advance'];
  const methods = names.map(name => {
    const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
    assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  let time = 1000;
  const box = { Date: { now: () => time }, Curve: { Linear: 'linear' }, clearTimeout: id => timers.delete(id),
    setTimeout: callback => { timers.set(++next, callback); return next; } };
  vm.runInNewContext(ts.transpileModule('class Page { ' + methods.join('\n') + ' };globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { visible: true, active: true, disposed: false, epoch: 0, timer: -1,
    titleOffset: 0, textWidth: 260, viewportWidth: 200, getUIContext: () => ({ animateTo: (options, apply) => {
      apply(); if (options.duration > 0) animations.push(options);
    } }) });
  return { ui, animations, timers, elapse: ms => { time += ms; }, tick: () => {
    assert.equal(timers.size, 1); const [id, callback] = timers.entries().next().value;
    timers.delete(id); callback();
  } };
}
test('long titles move exactly the overflow distance and reverse after reaching each edge', () => {
  const f = fixture(); f.ui.restart(); f.tick();
  assert.equal(f.ui.titleOffset, -60); assert.equal(f.animations[0].duration, 1875);
  f.animations[0].onFinish(); f.tick(); assert.equal(f.ui.titleOffset, 0);
  f.animations[1].onFinish(); f.tick(); assert.equal(f.ui.titleOffset, -60);
});

test('route/tab hide freezes the visible title position and resumes the same direction without jumping to the start', () => {
  const f = fixture(); f.ui.restart(); f.tick(); const old = f.animations[0];
  f.elapse(625); f.ui.active = false; f.ui.updateActivity();
  assert.equal(f.ui.titleOffset, -20); assert.equal(f.timers.size, 0);
  old.onFinish(); assert.equal(f.timers.size, 0);
  f.ui.active = true; f.ui.updateActivity(); assert.equal(f.ui.titleOffset, -20);
  f.tick(); assert.equal(f.ui.titleOffset, -60); assert.equal(f.animations[1].duration, 1250);
});
test('fitting titles and offscreen titles schedule no animation', () => {
  const f = fixture(); f.ui.textWidth = 190; f.ui.restart(); assert.equal(f.timers.size, 0);
  f.ui.textWidth = 260; f.ui.visible = false; f.ui.restart(); assert.equal(f.timers.size, 0);
});
test('resizing or changing the title invalidates old completion callbacks and resets its position', () => {
  const f = fixture(); f.ui.restart(); f.tick(); const old = f.animations[0];
  f.ui.viewportWidth = 230; f.ui.restart(); assert.equal(f.ui.titleOffset, 0);
  old.onFinish(); assert.equal(f.timers.size, 1);
  f.tick(); assert.equal(f.ui.titleOffset, -30); assert.equal(f.animations[1].duration, 938);
});
test('leaving the viewport or disposing removes timers and cannot restart an old animation', () => {
  const f = fixture(); f.ui.restart(); f.tick(); f.ui.visible = false; f.ui.restart();
  f.animations[0].onFinish(); assert.equal(f.timers.size, 0);
  f.ui.visible = true; f.ui.restart(); f.ui.disposed = true; f.ui.halt();
  assert.equal(f.timers.size, 0); f.ui.advance(f.ui.epoch, true); assert.equal(f.animations.length, 1);
});

test('a cached page or inactive tab stops long-title animation and resumes only when active', () => {
  const f = fixture(); f.ui.restart(); f.tick(); const old = f.animations[0];
  f.ui.active = false; f.ui.restart(); old.onFinish();
  assert.equal(f.timers.size, 0); assert.equal(f.ui.titleOffset, 0);
  f.ui.advance(f.ui.epoch, true); assert.equal(f.animations.length, 1);
  f.ui.active = true; f.ui.restart(); f.tick();
  assert.equal(f.ui.titleOffset, -60); assert.equal(f.animations.length, 2);
});

test('the page cover pauses title motion before navigation, then resumes the frozen offset', () => {
  const f = fixture(); f.ui.restart(); f.tick(); const old = f.animations[0];
  f.elapse(625); f.ui.routeTransitioning = true; f.ui.updateActivity();
  assert.equal(f.ui.titleOffset, -20); assert.equal(f.timers.size, 0);
  old.onFinish(); assert.equal(f.timers.size, 0);
  f.ui.routeTransitioning = false; f.ui.updateActivity(); f.tick();
  assert.equal(f.animations[1].duration, 1250);
});

test('backgrounding home pauses only its name animation and invalidates old completion callbacks', () => {
  const f = fixture();
  Object.assign(f.ui, { pauseWhenHomeHidden: true, homePageVisible: true });
  f.ui.restart(); f.tick(); const old = f.animations[0];
  f.elapse(625); f.ui.homePageVisible = false; f.ui.updateActivity();
  assert.equal(f.ui.titleOffset, -20); assert.equal(f.timers.size, 0);
  old.onFinish(); assert.equal(f.timers.size, 0);
  f.ui.advance(f.ui.epoch, true); assert.equal(f.animations.length, 1);
  f.ui.homePageVisible = true; f.ui.updateActivity(); f.tick();
  assert.equal(f.animations[1].duration, 1250);
});

test('a static title needs no visual write on home lifecycle changes and detail titles remain independent', () => {
  const f = fixture(); Object.assign(f.ui, { pauseWhenHomeHidden: true, homePageVisible: true, textWidth: 190 });
  let writes = 0;
  Object.defineProperty(f.ui, 'titleOffset', { get: () => 0, set: () => { writes++; } });
  for (const visible of [false, true, false, true]) {
    f.ui.homePageVisible = visible; f.ui.updateActivity();
  }
  assert.equal(writes, 0); assert.equal(f.timers.size, 0);
  const detail = fixture(); Object.assign(detail.ui, { pauseWhenHomeHidden: false, homePageVisible: false });
  detail.ui.restart(); detail.tick(); assert.equal(detail.ui.titleOffset, -60);
});
