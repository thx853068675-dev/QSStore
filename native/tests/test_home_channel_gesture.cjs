const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync(`${__dirname}/../entry/src/main/ets/pages/Index.ets`, 'utf8');
const start = source.indexOf('  private judgeChannelGesture(');
const end = source.indexOf('\n  /** 手势在横向位移', start);
assert.ok(start >= 0 && end > start);
function fixture(rects = {}) {
  const box = { GestureJudgeResult: { CONTINUE: 'continue', REJECT: 'reject' } };
  vm.runInNewContext(ts.transpileModule(`class Page { ${source.slice(start, end)} };globalThis.Page=Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const queries = [];
  const page = Object.assign(new box.Page(), { homeChannel: 'discover', channelTransitioning: false,
    getUIContext: () => ({ vp2px: value => value * 3, getComponentUtils: () => ({
      getRectangleById: id => { queries.push(id); if (!rects[id]) throw Error('not mounted'); return rects[id]; }
    }) }) });
  const judge = (x, y, dx = -30, dy = 0, tag = 'home-channel-swipe') => page.judgeChannelGesture({ tag },
    { fingerList: [{ globalX: x + dx, globalY: y + dy }], offsetX: dx, offsetY: dy });
  return { page, judge, queries };
}
const shelf = { windowOffset: { x: 30, y: 600 }, size: { width: 900, height: 450 } };
test('native carousel and every horizontal shelf keep swipes that start inside, even if the finger leaves', () => {
  for (const id of ['discover-week-banner-carousel', 'discover-shelf-overseas', 'discover-shelf-downloads',
    'discover-shelf-new', 'discover-shelf-frequent']) {
    const f = fixture({ [id]: shelf });
    assert.equal(f.judge(20, 220, -100, 20), 'reject', id);
    assert.equal(f.judge(10, 200), 'reject', 'inclusive start edge');
    assert.equal(f.judge(310, 350), 'reject', 'inclusive end edge');
    assert.equal(f.judge(20, 190), 'continue', 'outside region remains a channel swipe');
  }
});
test('All Apps and child gestures never inherit hidden Discover exclusions', () => {
  const f = fixture({ 'discover-week-banner-carousel': shelf });
  assert.equal(f.judge(20, 220, -30, 0, 'child-swiper'), 'continue');
  f.page.homeChannel = 'apps';
  assert.equal(f.judge(20, 220), 'continue');
  assert.deepEqual(f.queries, []);
});
test('bounds are read at recognition after scrolling or rotation; missing or zero-size regions do not block', () => {
  const rects = { 'discover-shelf-downloads': shelf };
  const f = fixture(rects);
  assert.equal(f.judge(20, 220), 'reject');
  rects['discover-shelf-downloads'] = { ...shelf, windowOffset: { x: 30, y: -600 } };
  assert.equal(f.judge(20, 220), 'continue');
  rects['discover-shelf-downloads'] = { ...shelf, size: { width: 0, height: 0 } };
  assert.equal(f.judge(20, 220), 'continue');
  assert.equal(f.page.judgeChannelGesture({ tag: 'home-channel-swipe' }, { fingerList: [] }), 'continue');
  f.page.channelTransitioning = true;
  assert.equal(f.judge(20, 220), 'reject', 'do not interrupt a settling page');
});
