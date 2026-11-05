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
    assert.equal(StoreLayout.navigationBarWidth(width,height),expected);
  }
  assert.deepEqual([[800,600],[440,667],[800,1200],[1280,800],[320,640]].map(([w,h])=>StoreLayout.navigationBarWidth(w,h)),
    [240,208,208,240,176], 'rotation never retains the previous wider blur capsule');
  assert.equal(StoreLayout.navigationBarWidth(0,0),208);
  assert.equal(StoreLayout.navigationBarWidth(NaN,Infinity),208);
});

test('the scaled sidebar install action stays level with and close to the centered native navigation', () => {
  assert.ok(Math.abs(StoreLayout.sidebarDetailScale / 0.7 - 1.2) < 1e-9);
  for (const [width,height] of [[320,640],[362,822],[440,667],[822,362],[1280,800],[1920,1080]]) {
    const frame = StoreLayout.sidebarFrameWidth(width);
    const frameRight = (width + frame) / 2;
    const right = StoreLayout.sidebarActionRight(width,height);
    const actionRight = frameRight - right;
    const actionLeft = actionRight - StoreLayout.navigationHeight;
    const barRight = width / 2 + StoreLayout.navigationBarWidth(width,height) / 2;
    assert.equal(actionLeft - barRight,StoreLayout.navigationActionGap);
    assert.ok(actionRight <= width - 8,'circle must remain inside the live window');
    const scale = StoreLayout.sidebarDetailScale;
    assert.equal((StoreLayout.navigationHeight / scale) * scale,StoreLayout.navigationHeight);
    assert.equal((StoreLayout.navigationBottomMargin / scale) * scale,StoreLayout.navigationBottomMargin);
    assert.equal((StoreLayout.sidebarRailWidth(width) - 48) / 2,
      StoreLayout.sidebarRailWidth(width) / 2 - 24,'device icons have equal rail gutters');
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
