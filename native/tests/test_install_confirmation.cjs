const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function fixture(official = false, name = '洛克王国：世界') {
  const registry = { isAppGallery: () => official, displayName: () => name };
  return loadEts('jobs/InstallConfirmation', {
    './InstalledAppRegistry': { InstalledAppRegistry: registry }
  }).InstallConfirmation;
}

test('official same-bundle conflicts name both applications and the app whose data will be removed', () => {
  const confirmation = fixture(true);
  assert.equal(confirmation.dataLossTitle(false, 'com.nrc.huawei'), '应用包名冲突');
  const text = confirmation.dataLossMessage(false, false, 'com.nrc.huawei', '米哈游启动器');
  assert.match(text, /已安装的「洛克王国：世界」来自华为应用市场/);
  assert.match(text, /准备安装的「米哈游启动器」使用相同包名（com.nrc.huawei），不能同时安装/);
  assert.match(text, /继续将卸载「洛克王国：世界」，再安装「米哈游启动器」/);
  assert.match(text, /「洛克王国：世界」的缓存、设置和登录状态都会清除/);
  assert.match(text, /取消将保留「洛克王国：世界」/);
  assert.doesNotMatch(text, /旧版|覆盖更新|新版/);
});

test('a missing official label falls back to its exact package name and accepts an attachment filename', () => {
  const confirmation = fixture(true, '');
  const text = confirmation.dataLossMessage(false, false, 'com.nrc.huawei', ' MiHoYoLauncher-3.2.0.hap ');
  assert.match(text, /卸载「com.nrc.huawei」/);
  assert.match(text, /再安装「MiHoYoLauncher-3.2.0.hap」/);
  assert.match(confirmation.dataLossMessage(false, false, 'com.nrc.huawei'), /「所选安装包」/);
});

test('ordinary, renewal and installer self-replacement explanations retain their original behavior', () => {
  const confirmation = fixture();
  assert.equal(confirmation.dataLossTitle(false), '需要卸载旧版');
  assert.equal(confirmation.dataLossTitle(true), '无法保留数据续签');
  assert.match(confirmation.dataLossMessage(false, false), /系统无法保留数据覆盖更新。继续会先卸载旧版，再安装新版/);
  assert.match(confirmation.dataLossMessage(true, false, 'com.sideload.app', '应用'), /续签后的同版本应用/);
  assert.match(confirmation.dataLossMessage(false, true, 'com.tonghongxiang.hapstore'), /先卸载轻启·安装器/);
  assert.match(confirmation.dataLossMessage(true, true), /签名身份会在卸载前备份/);
});

test('local signing page delegates to the same conflict chain as Discover and Detail',async()=>{
  const calls=[];
  const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/InstallPrompts.ets'),'utf8');
  const at=source.indexOf('  private async confirm(');
  const parsed=ts.createSourceFile('prompt.ts','class Page {\n'+source.slice(at),ts.ScriptTarget.ES2020,true);
  const method=parsed.statements[0].members[0];
  const context={filesDir:'/data'},box={getContext:()=>context,InstallConflictFlow:{present:async(...args)=>calls.push(args)}};
  vm.runInNewContext(ts.transpileModule('class Page { '+method.getText(parsed)+' };globalThis.Page=Page;',
   {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
  const page=new box.Page();page.confirmationId=5;await page.confirm('target-job');
  assert.deepEqual(calls,[[context,5,'target-job']]);
});
