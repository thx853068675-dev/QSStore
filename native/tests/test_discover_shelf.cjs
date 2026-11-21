const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { DiscoverShelfPosition: Bounds } = loadEts('components/DiscoverShelfPosition');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/DiscoverShelf.ets'), 'utf8');
function fixture() {
  const start = source.indexOf('  aboutToAppear(): void'), end = source.indexOf('\n  @Builder', start);
  assert(start >= 0 && end > start);
  const frames = [], moves = []; let offset = 0;
  const box = { Bounds, Curve: { EaseOut: 'ease-out' }, afterPaint: (_ui, fn) => frames.push(fn) };
  vm.runInNewContext(ts.transpileModule('class Shelf {' + source.slice(start, end) + '\n};globalThis.Shelf=Shelf;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const shelf = Object.assign(new box.Shelf(), { active: true, foreground: true, routeTransitioning: false,
    homeVisibility: { visible: true }, inView: true, canLeft: false, canRight: false, shelfHeight: 0,
    measuredHeight: 190, viewportWidth: 0, measuredWidth: 340, contentWidth: 804,
    mounted: false, metricsQueued: false, dragOffset: 0,
    getUIContext: () => ({}),
    scroller: { currentOffset: () => ({ xOffset: offset }), scrollTo: options => { moves.push(options); offset = options.xOffset; } } });
  const paint = () => frames.splice(0).forEach(fn => fn());
  shelf.aboutToAppear();
  return { shelf, frames, moves, paint, offset(value) { offset = value; shelf.onScroll(); } };
}
test('measured bounds yield right-only, both, left-only and no-overflow states, including elastic overscroll', () => {
  const f = fixture(); assert.equal(f.shelf.available(), false); f.paint();
  assert.equal(f.shelf.canLeft, false); assert.equal(f.shelf.canRight, true);
  f.offset(120); f.paint(); assert.equal(f.shelf.canLeft, true); assert.equal(f.shelf.canRight, true);
  f.offset(464); f.paint(); assert.equal(f.shelf.canLeft, true); assert.equal(f.shelf.canRight, false);
  f.offset(500); f.paint(); assert.equal(f.shelf.canRight, false);
  f.offset(-20); f.paint(); assert.equal(f.shelf.canLeft, false); assert.equal(f.shelf.canRight, true);
  f.shelf.contentWidth = 300; f.shelf.queueMetrics(); f.paint();
  assert.equal(f.shelf.canLeft, false); assert.equal(f.shelf.canRight, false);
});
test('scroll frames within the same available range schedule no redraw, and crossings coalesce until after paint', () => {
  const f = fixture(); f.paint();
  for (let x = 5; x < 100; x++) f.offset(x);
  assert.equal(f.frames.length, 1); assert.equal(f.shelf.canLeft, false, 'no state is published inside a native scroll callback');
  f.paint(); assert.equal(f.shelf.canLeft, true);
  for (let x = 100; x < 300; x++) f.offset(x);
  assert.equal(f.frames.length, 0);
});
test('rotation, resized split windows and refreshed data recalculate actual overflow without resetting scroll position', () => {
  const f = fixture(); f.paint(); f.offset(120); f.paint();
  f.shelf.measuredWidth = 1000; f.shelf.queueMetrics(); f.paint();
  assert.equal(f.shelf.canLeft, false); assert.equal(f.shelf.canRight, false);
  f.shelf.measuredWidth = 600; f.shelf.contentWidth = 1200; f.shelf.measuredHeight = 240;
  f.shelf.queueMetrics(); f.paint();
  assert.equal(f.shelf.canLeft, true); assert.equal(f.shelf.canRight, true); assert.equal(f.shelf.shelfHeight, 240);
  assert.equal(f.moves.length, 0, 'measuring is read-only; native scrolling owns offset clamping');
});
test('clicking browses exactly one card with bounded targets, including a short final page', () => {
  const f = fixture(); f.paint();
  f.shelf.move(1); assert.equal(f.moves[0].xOffset, 134); assert.equal(f.moves[0].animation.duration, 280);
  for (let i = 0; i < 10; i++) f.shelf.move(1);
  assert.equal(f.moves.at(-1).xOffset, 464);
  for (let i = 0; i < 10; i++) f.shelf.move(-1);
  assert.equal(f.moves.at(-1).xOffset, 0);
});
test('dragging a material button relays to the shelf and remains clamped to the same real scroll range', () => {
  const f = fixture(); f.paint(); f.shelf.dragOffset = 200;
  f.shelf.drag(-80); assert.equal(f.moves[0].xOffset, 280); assert.equal(f.moves[0].animation, false);
  f.shelf.drag(900); assert.equal(f.moves[1].xOffset, 0);
  f.shelf.drag(-900); assert.equal(f.moves[2].xOffset, 464);
});
test('background, navigation, hidden channel and offscreen shelves immediately stop arrow interaction', () => {
  const f = fixture(); f.paint(); assert.equal(f.shelf.available(), true);
  for (const [key, value] of [['foreground', false], ['active', false], ['routeTransitioning', true], ['inView', false]]) {
    const old = f.shelf[key]; f.shelf[key] = value;
    assert.equal(f.shelf.available(), false); const n = f.moves.length; f.shelf.move(1); assert.equal(f.moves.length, n);
    f.shelf[key] = old;
  }
  f.shelf.homeVisibility.visible = false; assert.equal(f.shelf.available(), false);
});
test('a destroyed shelf discards queued metrics rather than reviving its overlay', () => {
  const f = fixture(); f.shelf.aboutToDisappear(); f.paint();
  assert.equal(f.shelf.shelfHeight, 0); assert.equal(f.shelf.canRight, false); assert.equal(f.shelf.available(), false);
});
test('arrow bodies, response regions and bounded light-feedback containers stay within either edge', () => {
  const bodyOffset = (Bounds.touchWidth - Bounds.arrowWidth) / 2;
  for (const viewport of [280, 320, 600, 1000]) {
    const anchors = [Bounds.anchorInset(), viewport - Bounds.anchorInset() - Bounds.touchWidth];
    for (const x of anchors) {
      assert(x >= 0 && x + Bounds.touchWidth <= viewport);
      assert(x + bodyOffset >= Bounds.arrowInset);
      assert(x + bodyOffset + Bounds.arrowWidth <= viewport - Bounds.arrowInset);
    }
  }
  assert.equal((Bounds.touchHeight - Bounds.arrowHeight) / 2, 12, 'leave room for native lift and press feedback');
});
test('fractional layout tolerance and invalid first-frame measurements do not produce phantom arrows', () => {
  for (const [content, viewport] of [[340,340],[341.5,340],[NaN,340],[800,0],[800,Infinity]]) {
    assert.equal(Bounds.left(0,content,viewport),false); assert.equal(Bounds.right(0,content,viewport),false);
  }
  assert.equal(Bounds.left(1.8,804,340),false); assert.equal(Bounds.right(463,804,340),false);
});
