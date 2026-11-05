const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');

function fixture() {
  const modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const exports = {}; modules.set(name, exports);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
    }).outputText;
    vm.runInNewContext(code, { exports, setInterval: () => 1, clearInterval: () => {},
      require: dep => dep.startsWith('.') ? load(path.posix.join(path.posix.dirname(name), dep)) : {} });
    return exports;
  }
  const { InstallJob, InstallStage } = load('jobs/InstallJob');
  const { InstallTaskState: state } = load('jobs/InstallTaskState');
  const { QueueTaskPresentation: presentation } = load('jobs/QueueTaskPresentation');
  const { ListDataSource } = load('data/ListDataSource');
  const job = InstallJob.create('app-1', 1, 'app-1.hap', 'https://example.org/app.hap', '');
  job.stageHistory = [{ stage: InstallStage.QUEUED, at: 100 }];
  return { load, state, presentation, InstallJob, InstallStage, job, ListDataSource };
}

test('one queue card key survives every persisted stage and reads live metadata instead of its captured seed', () => {
  const f = fixture(), events = [];
  const page = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const begin = page.indexOf('  private queueRows:'), end = page.indexOf('\n  private onlineInstalledRows:', begin);
  assert(begin >= 0 && end > begin);
  const initializer = page.slice(begin, end).replace('private queueRows:', 'const queueRows:');
  const box = { ListDataSource: f.ListDataSource, DeviceInstallGroup:f.load('jobs/DeviceInstallGroup').DeviceInstallGroup };
  vm.runInNewContext(ts.transpileModule(initializer + '\nglobalThis.data=queueRows;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const data = box.data;
  data.registerDataChangeListener({ onDataAdd: () => events.push('add'), onDataChange: () => events.push('change'),
    onDataReloaded: () => events.push('reload') });
  f.state.publish(f.job); data.update([f.state.snapshot()[0].job]);
  const seed = data.getData(0), key = data.key(seed); events.length = 0;
  for (const stage of [f.InstallStage.DOWNLOADING, f.InstallStage.VERIFIED, f.InstallStage.PACKAGE_INSPECTED,
    f.InstallStage.PROFILE_READY, f.InstallStage.SIGNED, f.InstallStage.SIGNATURE_VERIFIED, f.InstallStage.INSTALLING]) {
    f.job.stage = stage; f.job.updatedAt++;
    f.job.bundleName = 'example.real.app'; f.job.versionName = '2.4.1';
    f.state.publish(f.job); data.update([f.state.snapshot()[0].job]);
    assert.equal(data.key(data.getData(0)), key);
    const view = f.presentation.present(f.state.snapshot(), f.job.id, seed);
    assert.equal(view.job.stage, stage); assert.equal(view.job.bundleName, 'example.real.app');
    assert.equal(view.job.versionName, '2.4.1');
  }
  assert.equal(seed.stage, f.InstallStage.QUEUED, 'retained LazyForEach seed intentionally does not carry progress');
  assert.equal(events.length, 0, 'persisted stages do not recreate the queue row');
  data.update([]); assert.equal(data.totalCount(), 0, 'completed or canceled work still removes its card');
});

test('download, signing, transfer and system installation share the same live ring semantics', () => {
  const f = fixture(); f.job.stage = f.InstallStage.DOWNLOADING; f.state.publish(f.job);
  f.state.setRunning(f.job.id, true); f.state.downloadProgress(f.job.id, 34, 100);
  let view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '下载'); assert.equal(view.percent, 34); assert.equal(view.determinate, true);
  f.job.stage = f.InstallStage.PROFILE_READY; f.state.publish(f.job);
  view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '签名'); assert.equal(view.detail, '签名中'); assert.equal(view.determinate, false);
  f.job.stage = f.InstallStage.INSTALLING; f.state.publish(f.job);
  f.state.installProgress(f.job.id, 'transfer', 57, 100);
  view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '传包'); assert.equal(view.percent, 57); assert.equal(view.determinate, true);
  f.state.installProgress(f.job.id, 'installing', 0, 0);
  view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '安装'); assert.equal(view.determinate, false); assert.equal(view.warning, true);
  f.state.setRunning(f.job.id, false);
  view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '确认'); assert.equal(view.warning, false); assert.equal(view.running, false);
});

test('other tasks do not repaint a mounted card, but original FIFO position changes are visible', () => {
  const f = fixture(), older = f.InstallJob.create('older', 2, 'older.hap', '', '');
  older.stageHistory = [{ stage: f.InstallStage.QUEUED, at: 50 }];
  older.updatedAt = 100000; f.state.publish(older); f.state.publish(f.job);
  let first = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(first.detail, '排队中 · 第 2 个');
  older.stage = f.InstallStage.DOWNLOADING; f.state.publish(older); f.state.setRunning(older.id, true);
  const moved = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(moved.detail, '排队中 · 第 1 个');
  assert.equal(f.presentation.unchanged(first, moved), false);
  f.state.downloadProgress(older.id, 42, 100);
  first = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(f.presentation.unchanged(moved, first), true);
});

test('a paused failure updates summary and recovering it clears the stale error', () => {
  const f = fixture();
  f.job.stage = f.InstallStage.RETRYABLE_ERROR; f.job.lastError = '连接失败，点击继续安装'; f.state.publish(f.job);
  let view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.label, '暂停'); assert.equal(view.error, true); assert.match(view.detail, /左滑卡片继续安装/);
  f.job.stage = f.InstallStage.PROFILE_READY; f.job.lastError = ''; f.state.publish(f.job); f.state.setRunning(f.job.id, true);
  view = f.presentation.present(f.state.snapshot(), f.job.id, f.job);
  assert.equal(view.error, false); assert.equal(view.label, '签名'); assert.equal(view.detail, '签名中');
});

test('card lifecycle unsubscribes and its ring and summary nodes remain mounted across phases', () => {
  const f = fixture(), source = fs.readFileSync(path.join(root, 'components/QueueTaskCard.ets'), 'utf8');
  const methods = ['aboutToAppear', 'aboutToDisappear'].map(name => {
    const start = source.indexOf('  ' + name + '(');
    assert.notEqual(start, -1);
    return source.slice(start, source.indexOf('\n  }', start) + 4);
  });
  const box = { InstallTaskState:f.state, QueueTaskPresentation:f.presentation, DeviceInstallGroup:f.load('jobs/DeviceInstallGroup').DeviceInstallGroup, InstallStage:f.InstallStage, console };
  vm.runInNewContext(ts.transpileModule('class Card {' + methods.join('\n') + '} globalThis.Card=Card;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const card = new box.Card();
  Object.assign(card, { members:[], jobId: f.job.id, fallback: f.job,
    view: new (f.load('jobs/QueueTaskPresentation').QueueTaskView)(), subscription: -1 });
  card.aboutToAppear(); f.state.publish(f.job);
  assert.equal(card.view.job.id, f.job.id);
  f.job.stage = f.InstallStage.PROFILE_READY; f.state.publish(f.job);
  const beforeRemoval = card.view;
  f.state.remove(f.job.id);
  assert.equal(card.view, beforeRemoval, 'membership removal does not flash the original queued seed');
  card.aboutToDisappear(); const saved = card.view;
  f.job.stage = f.InstallStage.DOWNLOADING; f.state.publish(f.job);
  assert.equal(card.subscription, -1); assert.equal(card.view, saved);
  assert.equal((source.match(/\bProgress\(\{/g) || []).length, 1);
  assert.match(source, /maxLines\(2\)\.width\('100%'\)\.height\(30\)/);
});

test('each device progress child follows persisted phases and measured bytes without a stale ForEach seed',()=>{
  const f=fixture(),source=fs.readFileSync(path.join(root,'components/DeviceInstallProgress.ets'),'utf8');
  const start=source.indexOf('  aboutToAppear()'),end=source.indexOf('  private colors()',start);
  const box={InstallTaskState:f.state};
  vm.runInNewContext(ts.transpileModule('class Row {'+source.slice(start,end)+'};globalThis.Row=Row;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  f.state.publish(f.job);const seed=f.state.snapshot()[0],child=new box.Row();
  Object.assign(child,{jobId:f.job.id,initial:seed,row:seed,subscription:-1});child.aboutToAppear();
  f.job.stage=f.InstallStage.DOWNLOADING;f.state.publish(f.job);f.state.setRunning(f.job.id,true);f.state.downloadProgress(f.job.id,42,100);
  assert.equal(child.row.percent,42);assert.equal(child.row.running,true);assert.equal(seed.job.stage,f.InstallStage.QUEUED);
  f.job.stage=f.InstallStage.INSTALLED;f.state.publish(f.job);assert.equal(child.row.job.stage,f.InstallStage.INSTALLED);
  child.aboutToDisappear();const previous=child.row;f.job.stage=f.InstallStage.QUEUED;f.state.publish(f.job);
  assert.equal(child.row,previous);assert.equal(child.subscription,-1);
});
