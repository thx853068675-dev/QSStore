const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function fixture() {
  const names = new Map(), official = new Set(), registry = {
    displayName: bundle => names.get(bundle) || '', isAppGallery: bundle => official.has(bundle)
  };
  const box = { exports: {}, require: () => ({ InstalledAppRegistry: registry }) };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data/AppDisplayName.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  return { names, official, resolver: box.exports.AppDisplayName };
}
test('verified device labels override catalog and repository names, including edited local labels', () => {
  const f = fixture(), app = { displayName: 'EnglishRepo', latestAsset: { bundleName: 'com.example.app' } };
  assert.equal(f.resolver.forCatalog(app), 'EnglishRepo');
  f.names.set('com.example.app', '我的中文名称');
  assert.equal(f.resolver.forCatalog(app), '我的中文名称');
  assert.equal(f.resolver.forBundle('com.example.app', 'EnglishRepo'), '我的中文名称');
  f.names.delete('com.example.app'); assert.equal(f.resolver.forCatalog(app), 'EnglishRepo');
});
test('empty preview reuses a unique bundle identity but multi-package listings never borrow another variant', () => {
  const f = fixture(); f.names.set('com.example.car', '车机音乐');
  const app = { displayName: 'Music', latestAssets: [{ bundleName: 'com.example.car' }], knownAssets: [] };
  assert.equal(f.resolver.forCatalog(app), '车机音乐');
  app.latestAssets.push({ bundleName: 'com.example.phone' });
  assert.equal(f.resolver.forCatalog(app), 'Music');
  app.latestAsset = { bundleName: 'com.example.phone' };
  assert.equal(f.resolver.forCatalog(app), 'Music');
});
test('Management and Detail use the same resolved installed title without device IPC in render', () => {
  const f = fixture(); f.names.set('com.example.app', '实际应用名称');
  function method(file, name) {
    const s = fs.readFileSync(path.join(root, file), 'utf8'), start = s.indexOf('  private ' + name + '(');
    return s.slice(start, s.indexOf('\n  }', start) + 4);
  }
  const box = { AppDisplayName: f.resolver };
  vm.runInNewContext(ts.transpileModule('class Page {' + method('pages/Index.ets', 'jobTitle') +
    method('pages/Detail.ets', 'appTitle') + '}; globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const page = new box.Page();
  page.app = { displayName: '旧目录名称', latestAsset: { bundleName: 'com.example.app' } };
  page.selectedAsset = { bundleName: 'com.example.app' };
  page.catalogForJob = () => { throw Error('resolved device title must win'); };
  assert.equal(page.jobTitle({ bundleName: 'com.example.app' }), '实际应用名称');
  assert.equal(page.appTitle(), '实际应用名称');
});

test('AppGallery Rock Kingdom cannot lend its installed label to a colliding launcher listing', () => {
  const f = fixture(), bundle = 'com.nrc.huawei';
  f.names.set(bundle, '洛克王国：世界'); f.official.add(bundle);
  const catalog = { displayName: '米哈游启动器', latestAsset: { bundleName: bundle } };
  assert.equal(f.resolver.forCatalog(catalog), '米哈游启动器');
  assert.equal(f.resolver.forCatalogBundle(bundle, '米哈游启动器'), '米哈游启动器');
  assert.equal(f.resolver.forBundle(bundle, '米哈游启动器'), '洛克王国：世界',
    'the actual device app still retains its real name in installed app information');
  f.official.delete(bundle);
  assert.equal(f.resolver.forCatalog(catalog), '洛克王国：世界',
    'a later verified debug sideload may use its actual edited application name');
});

test('AppGallery collision is guarded in empty preview and selected Detail variant names too', () => {
  const f = fixture(), bundle = 'com.nrc.huawei';
  f.names.set(bundle, '洛克王国：世界'); f.official.add(bundle);
  const catalog = { displayName: '米哈游启动器', latestAssets: [], knownAssets: [{ bundleName: bundle }] };
  assert.equal(f.resolver.forCatalog(catalog), '米哈游启动器');
  const detailSource = fs.readFileSync(path.join(root, 'pages/Detail.ets'), 'utf8');
  const start = detailSource.indexOf('  private appTitle(');
  assert(start >= 0);
  const method = detailSource.slice(start, detailSource.indexOf('\n  }', start) + 4);
  const box = { AppDisplayName: f.resolver };
  vm.runInNewContext(ts.transpileModule('class Page {' + method +
    '}; globalThis.Page=Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, box);
  const page = new box.Page(); page.app = catalog; page.selectedAsset = { bundleName: bundle };
  assert.equal(page.appTitle(), '米哈游启动器');
  f.official.delete(bundle); f.names.set(bundle, '用户修改的启动器名称');
  assert.equal(page.appTitle(), '用户修改的启动器名称');
});
