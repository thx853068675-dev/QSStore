const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

// Evaluate the production layout class only. StoreDesign also contains ArkUI's
// declarative DSL, which is not executable in a Node VM. No layout algorithm is
// copied into this fixture, so changing production behavior changes the result.
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/theme/StoreDesign.ets'), 'utf8');
const start = source.indexOf('export class StoreLayout {');
assert.ok(start >= 0);
let depth = 0, end = start;
for (let index = source.indexOf('{', start); index < source.length; index++) {
  if (source[index] === '{') depth++;
  if (source[index] === '}' && --depth === 0) { end = index + 1; break; }
}
assert.ok(end > start, 'the actual production StoreLayout class must be found');
const exportsForTest = {};
vm.runInNewContext(ts.transpileModule(source.slice(start, end), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsForTest });
const { StoreLayout } = exportsForTest;

test('navigation and its backdrop share compact widths across rotation and split windows', () => {
  for (const [width, height, expected] of [[320,640,176],[440,667,208],[599,900,208],
    [600,1000,208],[800,1200,208],[600,700,240],[800,600,240],[840,1200,240],[1280,800,240]]) {
    assert.equal(StoreLayout.navigationBarWidth(width,height,true),expected);
  }
  assert.deepEqual([[800,600],[440,667],[800,1200],[1280,800],[320,640]].map(([w,h])=>StoreLayout.navigationBarWidth(w,h,true)),
    [240,208,208,240,176], 'rotation never retains the previous wider blur capsule');
  assert.equal(StoreLayout.navigationBarWidth(0,0,true),208);
  assert.equal(StoreLayout.navigationBarWidth(NaN,Infinity,true),208);
});

test('ordinary navigation gives the four tabs more space within the window', () => {
  for (const [width, height, expected] of [[280,640,256],[320,640,280],[440,667,280],[822,362,320],[1280,800,320]]) {
    const actual = StoreLayout.navigationBarWidth(width,height,false);
    assert.equal(actual, expected);
    assert.ok(actual > StoreLayout.navigationBarWidth(width,height,true));
    assert.ok(width - actual >= 24, 'floating bar keeps clearance on both sides');
  }
});

test('a quick mode reversal resumes from the visible width and discards stale animation frames', () => {
  const index = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const start = index.indexOf('  private navigationWidthTarget(): number {');
  const end = index.indexOf('\n  @Builder', start);
  assert.ok(start >= 0 && end > start);
  const box = { StoreLayout };
  vm.runInNewContext(ts.transpileModule(`class Index { static TAB_DISCOVER = 0; ${index.slice(start, end)} }
    globalThis.Page = Index;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const animations = [];
  const page = Object.assign(new box.Page(), { currentTab: 0, homeChannel: 'discover', discoverLayout: 'sidebar',
    navigationCompactness: 0, viewportWidth: 360, viewportHeight: 800,
    pageVisible: true, discoverChromeReady: true,
    showHomeNavigation() {},
    getUIContext: () => ({ createAnimator: options => {
      const animation = { options, play() {}, cancel() { this.cancelled = true; } };
      animations.push(animation);
      return animation;
    } }) });
  page.syncNavigationWidth();
  assert.equal(animations.length, 0, 'saved sidebar preference must not shrink the Discover channel');
  page.homeChannel = 'apps';
  page.syncNavigationWidth();
  const [enter] = animations;
  assert.equal(page.fallbackBarWidth(), 280);
  enter.onFrame(0.5);
  const halfway = page.fallbackBarWidth();
  assert.ok(halfway > 208 && halfway < 280);
  page.discoverLayout = 'normal';
  page.syncNavigationWidth();
  const reverse = animations[1];
  assert.equal(enter.cancelled, true);
  assert.equal(reverse.options.begin, 0.5);
  enter.onFrame(1);
  enter.onFinish();
  assert.equal(page.fallbackBarWidth(), halfway);
  reverse.onFinish();
  assert.equal(page.fallbackBarWidth(), 280);
});

test('the entire dock stays centered for both hands and the button emerges from the bar', () => {
  assert.ok(Math.abs(StoreLayout.sidebarDetailScale / 0.7 - 1.2) < 1e-9);
  const size = StoreLayout.navigationHeight;
  for (const [width,height] of [[320,640],[362,822],[440,667],[822,362],[1280,800],[1920,1080]]) {
    const normal = StoreLayout.navigationBarWidth(width,height,false);
    const compact = StoreLayout.navigationBarWidth(width,height,true);
    for (const left of [false,true]) {
      for (const progress of [0,0.25,0.5,0.75,1]) {
        const bar = normal + (compact-normal)*progress;
        const group = bar+StoreLayout.dockExtraWidth(progress);
        const start = (width-group)/2;
        const navX = StoreLayout.dockNavigationX(progress,left);
        const actionX = StoreLayout.dockInstallX(bar,progress,left);
        assert.ok(start >= 8);
        assert.equal(Math.min(navX,actionX),0);
        assert.equal(Math.max(navX+bar,actionX+size),group);
        if (progress===0) assert.ok(actionX>=navX && actionX+size<=navX+bar);
        if (progress===1) assert.equal(left?navX-actionX-size:actionX-navX-bar,StoreLayout.navigationActionGap);
      }
    }
  }
});

test('hiding navigation moves the sidebar action to the window center for either hand', () => {
  const size = StoreLayout.navigationHeight;
  for (const [width, height] of [[320,640], [440,667], [822,362], [1280,800], [1920,1080]]) {
    const bar = StoreLayout.navigationBarWidth(width, height, true);
    const group = bar + StoreLayout.dockExtraWidth(1);
    const start = (width - group) / 2;
    for (const left of [false, true]) {
      const resting = StoreLayout.dockInstallX(bar, 1, left);
      let previousDistance = Infinity;
      for (const progress of [0, .1, .25, .5, .75, .9, 1]) {
        const position = StoreLayout.dockInstallX(bar, 1, left, progress);
        const center = start + position + size / 2;
        const distance = Math.abs(center - width / 2);
        assert.ok(distance <= previousDistance, 'the action never travels away from the center');
        assert.ok(position >= 0 && position + size <= group);
        if (progress === 0) assert.equal(position, resting, 'visible navigation keeps the existing hand-aware layout');
        if (progress === 1) assert.equal(center, width / 2, 'the whole window defines the center, not the detail column');
        previousDistance = distance;
      }
      assert.equal(StoreLayout.dockInstallX(bar, 1, left, -1), resting);
      assert.equal(StoreLayout.dockInstallX(bar, 1, left, 2), StoreLayout.dockInstallX(bar, 1, left, 1));
      for (const invalid of [NaN, Infinity]) assert.equal(StoreLayout.dockInstallX(bar, 1, left, invalid), resting);
    }
    assert.equal(StoreLayout.dockInstallX(bar, 1, false, 1), StoreLayout.dockInstallX(bar, 1, true, 1),
      'changing the holding side while hidden leaves the action centered');
  }
});

test('the sidebar leaves the window before entering the other edge and never overlaps the article', () => {
  for (const width of [320, 412, 822, 1920]) {
    const frame = StoreLayout.sidebarFrameWidth(width);
    const rail = StoreLayout.sidebarRailWidth(width);
    const margin = (width - frame) / 2;
    for (const fromRight of [false, true]) {
      const start = fromRight ? frame - rail : 0;
      const articleStart = fromRight ? 0 : rail;
      const railLeft = progress => margin + start + StoreLayout.sidebarRailShift(width, fromRight, progress);
      const articleLeft = progress => articleStart + StoreLayout.sidebarDetailShift(width, fromRight, progress);
      assert.equal(railLeft(0), margin + start);
      assert.equal(railLeft(1), margin + (fromRight ? 0 : frame - rail));
      assert.equal(articleLeft(0), articleStart);
      assert.equal(articleLeft(1), fromRight ? rail : 0);
      assert.ok(fromRight ? railLeft(.36) > width : railLeft(.36) + rail < 0);
      assert.ok(fromRight ? railLeft(.360001) + rail < 0 : railLeft(.360001) > width);
      for (let step = 0; step <= 100; step++) {
        const progress = step / 100;
        const railX = railLeft(progress) - margin;
        const detailX = articleLeft(progress);
        assert.ok(railX + rail <= detailX + 1e-8 || railX >= detailX + frame - rail - 1e-8);
      }
    }
  }
});

test('phone, tablet and desktop frames preserve the same maximum readable body width', () => {
  for (const [viewport, inset, frame] of [
    [320, 16, 752], [360, 24, 768], [800, 24, 768],
    [1280, 24, 768], [1920, 24, 768]
  ]) {
    assert.equal(StoreLayout.inset(viewport), inset);
    assert.equal(StoreLayout.frameMaxWidth(viewport), frame);
    assert.equal(frame - inset * 2, 720);
  }
});

test('frame policy responds to rotation and split-screen without retaining a previous breakpoint', () => {
  const sequence = [1280, 800, 320, 360, 1920, 320];
  assert.deepEqual(sequence.map(width => StoreLayout.frameMaxWidth(width)),
    [768, 768, 752, 768, 768, 752]);
  assert.equal(StoreLayout.frameMaxWidth(), 768, 'unknown startup width uses the safe regular inset');
});

test('full-viewport lists and centered headers share the same readable content gutters', () => {
  for (const [width, expected] of [[320, 16], [360, 24], [800, 40], [1280, 280], [1920, 600]]) {
    assert.equal(StoreLayout.contentInset(width), expected);
    assert.ok(width - expected * 2 <= StoreLayout.contentWidth);
  }
  for (const width of [0, -1, NaN, Infinity]) assert.equal(StoreLayout.contentInset(width), 24);
});

test('full-window lists and overlays share centered readable edges on wide screens', () => {
  for (const [viewport, expectedInset, readableWidth] of [
    [320, 16, 288], [360, 24, 312], [800, 40, 720],
    [1280, 280, 720], [1920, 600, 720]
  ]) {
    const inset = StoreLayout.contentInset(viewport);
    assert.equal(inset, expectedInset);
    const left = inset, right = viewport - inset;
    assert.equal(right - left, readableWidth);
    assert.equal((left + right) / 2, viewport / 2,
      'header, list body and floating controls must use the same horizontal center');
    assert.ok(inset >= StoreLayout.inset(viewport), 'phones must retain their existing edge clearance');
  }
});

test('content edges adapt across rotation and split-screen, including unknown startup geometry', () => {
  assert.deepEqual([1280, 800, 320, 360, 1920, 320].map(width => StoreLayout.contentInset(width)),
    [280, 40, 16, 24, 600, 16]);
  for (const width of [0, -1, NaN, Infinity]) {
    assert.equal(StoreLayout.contentInset(width), 24);
    assert.ok(Number.isFinite(StoreLayout.contentInset(width)));
  }
});

test('dialogs fit the live window height and leave room for both system insets', () => {
  for (const [height, top, bottom, expected] of [
    [800, 48, 20, 672], [1280, 48, 20, 1075.2],
    [240, 56, 24, 128], [800, 400, 80, 288], [200, 100, 100, 0],
    [800, -40, -10, 672]
  ]) {
    assert.ok(Math.abs(StoreLayout.sheetMaxHeight(height, top, bottom) - expected) < 0.000001);
  }
  for (const height of [0, -1, NaN]) assert.equal(StoreLayout.sheetMaxHeight(height), 640);
});

test('dialog limits shrink and recover with the current window rather than the original display height', () => {
  assert.deepEqual([800, 240, 1280, 200, 800].map(height => StoreLayout.sheetMaxHeight(height, 48, 20)),
    [672, 140, 1075.2, 100, 672]);
  assert.equal(StoreLayout.sheetMaxHeight(240, NaN, Infinity), 201.6,
    'an unavailable inset must not turn a usable dialog height into NaN');
  assert.equal(StoreLayout.sheetMaxHeight(Infinity, 48, 20), 640);
});
