const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function pageMethod(source, marker) {
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'missing ' + marker);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function compile(code, globals = {}) {
  const box = { ...globals };
  vm.runInNewContext(ts.transpileModule('class Page {' + code + '\n};globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return new box.Page();
}

test('native root material back returns to desktop from every root tab', async () => {
  const code = pageMethod(read('pages/Index.ets'), '  private materialBack(): void');
  const moved = [], state = { transitioning: false };
  const page = compile(code, { AppStorage: { get: () => state.transitioning },
    getContext: () => ({ moveAbilityToBackground: async () => { moved.push(page.currentTab); } }), console });
  Object.assign(page, { homeVisibility: { visible: true }, onBackPress: () => false });
  for (const tab of [0, 1, 2, 3]) { page.currentTab = tab; page.materialBack(); }
  await Promise.resolve();
  assert.deepEqual(moved, [0, 1, 2, 3]);
  page.onBackPress = () => true; page.materialBack();
  page.onBackPress = () => false; page.homeVisibility.visible = false; page.materialBack();
  page.homeVisibility.visible = true; state.transitioning = true; page.materialBack();
  await Promise.resolve();
  assert.equal(moved.length, 4, 'business overlays and route transitions must not return to desktop');
});

test('sort material back closes its real menu before forwarding a root back gesture', () => {
  const code = pageMethod(read('components/DiscoverSortControl.ets'), '  private materialBack(): void');
  const page = compile(code); let forwarded = 0;
  Object.assign(page, { active: true, foreground: true, routeTransitioning: false,
    menuOpen: true, backAction: () => { forwarded++; } });
  page.materialBack(); assert.equal(page.menuOpen, false); assert.equal(forwarded, 0);
  page.materialBack(); assert.equal(forwarded, 1);
  for (const flag of ['active', 'foreground', 'routeTransitioning']) {
    Object.assign(page, { active: true, foreground: true, routeTransitioning: false });
    page[flag] = flag === 'routeTransitioning'; page.materialBack();
  }
  assert.equal(forwarded, 1, 'inactive material must not steal detail or settings back gestures');
});

test('all permanent discovery material controls forward root back instead of swallowing it', () => {
  const header = read('components/DiscoverHeader.ets');
  const top = read('components/DiscoverTopAction.ets');
  const index = read('pages/Index.ets');
  assert.doesNotMatch(header, /onWillDismiss:\s*false/);
  assert.match(header, /DismissReason\.PRESS_BACK[\s\S]*?this\.backAction\(\)/);
  assert.match(header, /StoreImmersiveAction\(\{[\s\S]*?backAction:\s*this\.backAction/);
  assert.match(header, /DiscoverSortControl\(\{[\s\S]*?backAction:\s*this\.backAction/);
  assert.match(header, /controlId: 'discover-category-button'[\s\S]*?backAction:\s*this\.backAction/);
  assert.match(header, /controlId: 'discover-category-' \+ category, backAction:\s*this\.backAction/);
  assert.match(top, /DiscoverTopAction\(\{[\s\S]*?backAction:\s*this\.backAction/);
  assert.match(top, /DismissReason\.PRESS_BACK[\s\S]*?this\.backAction\(\)/);
  const headerStart = index.indexOf('DiscoverHeader({');
  const overlayStart = index.indexOf('DiscoverTopOverlay({', headerStart);
  const pageEnd = index.indexOf(".id('navigation-content-0')", overlayStart);
  assert.match(index.slice(headerStart, overlayStart), /backAction:\s*\(\) =>.*this\.materialBack\(\)/);
  assert.match(index.slice(overlayStart, pageEnd), /backAction:\s*\(\) =>.*this\.materialBack\(\)/);
  for (const control of ['management-refresh', 'mine-settings']) {
    const start = index.indexOf("controlId: '" + control + "'");
    assert.match(index.slice(start, start + 700), /backAction:\s*\(\) =>.*this\.materialBack\(\)/);
  }
});
