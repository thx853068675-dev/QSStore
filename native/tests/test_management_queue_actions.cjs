const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
const method = ['queueActions', 'showQueueActions'].map(name => {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}).join('\n');
const actionsExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/data/ManagementActions.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: actionsExports, require: () => ({
  InstallStage: { QUEUED: 'queued', TERMINAL_ERROR: 'terminal_error' }
}) });
function fixture(running = false) {
  const box = { ManagementActions: actionsExports.ManagementActions,
    InstallStage: { QUEUED: 'queued', TERMINAL_ERROR:'terminal_error' }, Index: { TAB_MINE: 3 }, AlertDialog: { show() {} } };
  vm.runInNewContext(ts.transpileModule('class Page { ' + method + ' }; globalThis.Page = Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const f = { canceled: [], continued: [], index: 0 };
  f.job = { id: 'job', stage: 'waiting_device' };
  f.ui = new box.Page(); Object.assign(f.ui, { pendingJobs: [f.job], signedIn: true, activeJobId: '', cancellingJobs: [],
    managementQueueJobs: () => f.ui.pendingJobs,
    jobRunning: () => running, jobTitle: () => 'app', colors: () => ({ text: '#111', danger: '#f00' }),
    showCardActionMenu: async (title, labels, destructiveIndex) => {
      f.options = { title, buttons: labels.map(text => ({ text })), destructiveIndex };
      if (f.wait) await f.wait; return f.index;
    }, cancelInstall: async job => f.canceled.push(job), continueInstall: async job => f.continued.push(job) });
  return f;
}
test('queue menu offers continue only for paused work, and cleanup remains available while running', async () => {
  const paused = fixture(); await paused.ui.showQueueActions(paused.job);
  assert.deepEqual(Array.from(paused.options.buttons, x => x.text), ['继续安装', '查看任务信息', '取消并清理']);
  assert.equal(paused.continued.length, 1);
  const running = fixture(true); running.index = 1; await running.ui.showQueueActions(running.job);
  assert.deepEqual(Array.from(running.options.buttons, x => x.text), ['查看任务信息', '取消并清理']);
  assert.equal(running.canceled.length, 1); assert.equal(running.continued.length, 0);
});
test('swipe uses the same guarded actions without opening a second menu, with two-character labels', async () => {
  const f = fixture(); const actions = f.ui.queueActions(f.job);
  assert.deepEqual(Array.from(actions, action => action.shortLabel), ['继续', '信息', '清理']);
  await f.ui.showQueueActions(f.job, 'continue'); assert.equal(f.continued.length, 1);
  assert.equal(f.options, undefined);
  await f.ui.showQueueActions(f.job, 'cleanup'); assert.equal(f.canceled.length, 1);
  f.ui.cancellingJobs = [f.job.id];
  await f.ui.showQueueActions(f.job, 'continue'); assert.equal(f.continued.length, 1);
  f.ui.cancellingJobs = []; f.ui.pendingJobs = [];
  await f.ui.showQueueActions(f.job, 'cleanup'); assert.equal(f.canceled.length, 1);
  assert.deepEqual(Array.from(actionsExports.ManagementActions.installed('手动续签'), action => action.shortLabel), ['续签', '卸载']);
});
test('a continue action cannot run after the queue starts that job while its menu is open', async () => {
  const f = fixture(); let release; f.wait = new Promise(resolve => { release = resolve; });
  const menu = f.ui.showQueueActions(f.job); await new Promise(setImmediate);
  f.ui.jobRunning = () => true; release(); await menu;
  assert.equal(f.continued.length, 0);
});
test('a task that completes while its menu is open is never canceled from the stale snapshot', async () => {
  const f = fixture(); let release; f.index = 2; f.wait = new Promise(resolve => { release = resolve; });
  const menu = f.ui.showQueueActions(f.job); await new Promise(setImmediate);
  f.ui.pendingJobs = []; release(); await menu;
  assert.equal(f.canceled.length, 0); assert.equal(f.continued.length, 0);
});
test('signed-out paused tasks offer login, while dismissing the menu does not touch work', async () => {
  const f = fixture(); f.ui.signedIn = false; await f.ui.showQueueActions(f.job);
  assert.equal(f.options.buttons[0].text, '前往登录'); assert.equal(f.ui.currentTab, 3);
  assert.equal(f.continued.length, 0);
  f.index = -1; await f.ui.showQueueActions(f.job); assert.equal(f.canceled.length, 0);
});
test('a terminal renewal remains manageable and offers a new renewal instead of continuing a dead runner', async () => {
  const f=fixture();Object.assign(f.job,{stage:'terminal_error',renewalRequestedAt:1});
  let renewed=0;f.ui.renewInstalled=()=>renewed++;
  await f.ui.showQueueActions(f.job);
  assert.deepEqual(Array.from(f.options.buttons,b=>b.text),['重新续签','查看任务信息','清理记录']);
  assert.equal(renewed,1);assert.equal(f.continued.length,0);
  f.index=2;await f.ui.showQueueActions(f.job);assert.equal(f.canceled.length,1);
});
test('long press reads the live task stage instead of the card snapshot captured while queued', async () => {
  const f=fixture();const captured={id:f.job.id,stage:'queued'};
  Object.assign(f.job,{stage:'terminal_error',renewalRequestedAt:1});
  let renewed=0;f.ui.renewInstalled=()=>renewed++;
  await f.ui.showQueueActions(captured);
  assert.equal(f.options.buttons[0].text,'重新续签');assert.equal(renewed,1);
  f.ui.pendingJobs=[];f.options=undefined;
  await f.ui.showQueueActions(captured);assert.equal(f.options,undefined);
});
test('failed tasks stay visible until cleanup or a newer attempt supersedes them', () => {
  const start=source.indexOf('  private managementQueueJobs(');
  const code=source.slice(start,source.indexOf('\n  }',start)+4);
  const box={InstallStage:{TERMINAL_ERROR:'terminal_error'}};
  vm.runInNewContext(ts.transpileModule('class Page { '+code+' };globalThis.Page=Page;',{
    compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page=new box.Page(),failed={id:'failed',stage:'terminal_error',bundleName:'com.app',updatedAt:10};
  Object.assign(page,{pendingJobs:[],installTasks:[{job:failed}]});
  assert.equal(page.managementQueueJobs()[0],failed);
  const renewed={id:'done',stage:'installed',bundleName:'com.app',updatedAt:20};
  page.installTasks.push({job:renewed});assert.equal(page.managementQueueJobs().length,0);
  // Saving an older success during file cleanup must not hide the newer failed renewal.
  Object.assign(failed,{renewalRequestedAt:10,stageHistory:[{at:10}]});
  Object.assign(renewed,{updatedAt:100,renewalRequestedAt:0,stageHistory:[{at:5}]});
  assert.equal(page.managementQueueJobs()[0],failed);
  renewed.renewalRequestedAt=20;assert.equal(page.managementQueueJobs().length,0);
});

test('the themed card menu settles once on selection, replacement and dismissal', async () => {
  const methods = ['showCardActionMenu', 'dismissCardActions'].map(name => {
    const begin = source.indexOf('  private ' + name + '(');
    return source.slice(begin, source.indexOf('\n  }', begin) + 4);
  }).join('\n');
  const box = {};
  vm.runInNewContext(ts.transpileModule('class Page { ' + methods + ' };globalThis.Page=Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const page = new box.Page(); page.animateOverlay = fn => fn();
  const first = page.showCardActionMenu('应用', ['继续安装', '查看任务信息', '取消并清理'], 2);
  assert.equal(page.showCardActions, true); assert.equal(page.cardDestructiveIndex, 2);
  const replacement = page.showCardActionMenu('另一应用', ['手动续签', '卸载'], 1);
  assert.equal(await first, -1, 'a replaced menu must not leave a pending action');
  page.dismissCardActions(0); assert.equal(await replacement, 0); assert.equal(page.showCardActions, false);
  page.dismissCardActions(1); assert.equal(page.cardActionResolver, undefined);
  const dismissed = page.showCardActionMenu('应用', ['清理记录'], 0);
  page.dismissCardActions(-1); assert.equal(await dismissed, -1);
});
