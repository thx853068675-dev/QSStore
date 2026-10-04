const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/BouncingAppName.ets'), 'utf8');
function fixture() {
  const timers = new Map(), animations = []; let next = 0;
  const names = ['halt', 'restart', 'advance'];
  const methods = names.map(name => {
    const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
    assert.ok(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { Curve: { Linear: 'linear' }, clearTimeout: id => timers.delete(id),
    setTimeout: callback => { timers.set(++next, callback); return next; } };
  vm.runInNewContext(ts.transpileModule('class Page { ' + methods.join('\n') + ' };globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const ui = new box.Page(); Object.assign(ui, { visible: true, active: true, disposed: false, epoch: 0, timer: -1,
    titleOffset: 0, textWidth: 260, viewportWidth: 200, getUIContext: () => ({ animateTo: (options, apply) => {
      apply(); if (options.duration > 0) animations.push(options);
    } }) });
  return { ui, animations, timers, tick: () => {
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
