// Production update/variant decisions with journal proofs restored from real SQLite.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, setTimeout, require: name => mocks[name] || {} });
  return exports;
}
const jobs = load('jobs/InstallJob');
const release = load('data/ReleaseInfo');
const { ReleaseUpdate: Update } = load('jobs/ReleaseUpdate', {
  './InstallJob': jobs, '../data/ReleaseInfo': release, '../data/DisplayVersion': load('data/DisplayVersion')
});
const { CatalogInstallTarget: Target } = load('jobs/CatalogInstallTarget', {
  './InstallJob': jobs, './ReleaseUpdate': { ReleaseUpdate: Update },
  '../data/CatalogPackageVariant': load('data/CatalogPackageVariant')
});
const sha = letter => letter.repeat(64), bundle = 'com.miha.harmony', code = 1000150, raw = '1.1.5-OS', time = 1700000001000;
function fixture(t, legacy = false) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  const schema = fs.readFileSync(path.join(root, 'jobs/JobStore.ets'), 'utf8').match(/const JOB_SCHEMA = `([\s\S]*?)`;/)[1];
  if (legacy) db.exec(schema.replace(/^  (?:edited_source_sha256|edited_source_asset_name|package_source_sha256).*\n/gm, ''));
  const query = (sql, args = []) => {
    const statement = db.prepare(sql), rows = statement.all(...args), columns = statement.columns().map(item => item.name); let at = -1;
    return { goToNextRow: () => ++at < rows.length, getColumnIndex: name => columns.indexOf(name),
      getString: column => String(rows[at][columns[column]]), getLong: column => Number(rows[at][columns[column]]), close() {} };
  };
  const adapter = { executeSql: async (sql, args = []) => db.prepare(sql).run(...args),
    querySql: async (sql, args = []) => query(sql, args), querySqlSync: query,
    updateSync: (values, predicates) => {
      const fields = Object.keys(values);
      return db.prepare('UPDATE ' + predicates.table + ' SET ' + fields.map(key => key + ' = ?').join(', ') +
        ' WHERE ' + predicates.matches.map(([key]) => key + ' = ?').join(' AND '))
        .run(...fields.map(key => values[key]), ...predicates.matches.map(([, value]) => value)).changes;
    } };
  class RdbPredicates {
    constructor(table) { this.table = table; this.matches = []; }
    equalTo(key, value) { this.matches.push([key, value]); return this; }
  }
  const { JobStore } = load('jobs/JobStore', {
    './InstallJob': jobs, './RecoveryPlanner': load('jobs/RecoveryPlanner', { './InstallJob': jobs }),
    '@kit.ArkData': { relationalStore: { getRdbStore: async () => adapter, SecurityLevel: { S1: 1 }, RdbPredicates } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false } },
    './InstallTaskState': { InstallTaskState: { publish() {}, snapshot: () => [] } }, './JobCancellation': { JobCancellation: { isCancelled: () => false } }
  });
  const context = { filesDir: '/sandbox' };
  return { db, JobStore, context,
    async reopen(record) { const store = await JobStore.initialize(context); await store.save(record);
      return (await JobStore.initialize(context)).listAll(); } };
}
function asset(values = {}) {
  return Object.assign(new release.HapAsset(), { name: 'Miha-v1.1.5.hap', bundleName: bundle, versionCode: code,
    versionName: raw, releaseTag: 'v1.1.5', releaseName: '1.1.5-OS Final Update', sha256: sha('a'),
    url: 'https://github.com/o/r/releases/download/v1.1.5/Miha-v1.1.5.hap' }, values);
}
function edited(values = {}) {
  return Object.assign(jobs.InstallJob.create('local:edited', 0, 'User-modified.hap', 'local', sha('c')),
    { bundleName: bundle, versionCode: code, versionName: raw, editedSourceSha256: sha('a'),
      editedSourceAssetName: 'Miha-v1.1.5.hap', packageSourceSha256: sha('c'),
      releaseTag: 'v1.1.5', releaseName: '1.1.5-OS Final Update', stage: jobs.InstallStage.INSTALLED,
      installedUpdateTime: time, stageHistory: [{stage: jobs.InstallStage.INSTALLED, at: time}] }, values);
}
function catalog(choices, primary = choices[0]) { return { latestAssets: choices, latestAsset: primary }; }
function selected(choices, restored, primary=choices[0], updateTime=time, identity=bundle, installed=code) {
  return Target.choose(catalog(choices,primary),restored,installed,updateTime,identity);
}

for (const legacy of [false, true]) test('edited source identity persists through SQLite migration/restart and suppresses false OS-suffix updates; legacy='+legacy, async t => {
  const f=fixture(t,legacy),row=edited(),restored=await f.reopen(row),next=asset();
  const persisted=restored[0],view=jobs.InstallJob.displayCopy(persisted);
  for(const key of ['editedSourceSha256','editedSourceAssetName','packageSourceSha256']) {
    assert.equal(persisted[key],row[key]);assert.equal(view[key],row[key]);
  }
  assert.equal(Update.available(next,code,raw,restored,time),false);assert.equal(Update.older(next,code,raw,restored,time),false);
  assert.equal(Update.record(restored,bundle,code,time).id,row.id);
});
test('matching a locally proven original digest needs no invented release metadata',async t=>{
  const f=fixture(t),restored=await f.reopen(edited({releaseTag:'',releaseName:'',catalogSha256:''}));
  assert.equal(Update.available(asset(),code,raw,restored,time),false);
  assert.equal(restored[0].expectedSha256,sha('c'));assert.equal(restored[0].catalogSha256,'');
});
test('completed package cleanup removes file references while the edited original proof survives SQLite restart',async t=>{
  const f=fixture(t),store=await f.JobStore.initialize(f.context),row=edited({cachePath:'/sandbox/install-jobs/edit.hap',signedPath:'/sandbox/install-jobs/edit.signed.hap'});
  await store.save(row);await store.pruneCompleted(f.context);
  const restored=await (await f.JobStore.initialize(f.context)).listAll(),receipt=restored[0];
  assert.equal(receipt.cachePath,'');assert.equal(receipt.signedPath,'');
  assert.equal(receipt.editedSourceSha256,row.editedSourceSha256);assert.equal(receipt.editedSourceAssetName,row.editedSourceAssetName);
  assert.equal(receipt.packageSourceSha256,row.packageSourceSha256);assert.equal(receipt.expectedSha256,row.expectedSha256);
  assert.equal(Update.available(asset(),code,raw,restored,time),false);
});
test('a real same-code, same-tag changed asset remains an update and stops only after that original was installed',async t=>{
  const f=fixture(t),next=asset({sha256:sha('b')}),restored=await f.reopen(edited({catalogSha256:sha('a')}));
  assert.equal(Update.available(next,code,raw,restored,time),true);
  const current=await f.reopen(edited({expectedSha256:sha('d'),packageSourceSha256:sha('d'),editedSourceSha256:sha('b'),catalogSha256:sha('b')}));
  assert.equal(Update.available(next,code,raw,current,time),false);
});
test('higher build numbers update even when original bytes or release labels match; lower numbers remain blocked',async t=>{
  const f=fixture(t),restored=await f.reopen(edited());
  assert.equal(Update.available(asset({versionCode:code+1}),code,raw,restored,time),true);
  const lower=asset({versionCode:code-1,releaseTag:'v9.0.0'});
  assert.equal(Update.available(lower,code,raw,restored,time),false);assert.equal(Update.older(lower,code,raw,restored,time),true);
});
test('a genuinely newer release with reused internal numbering still updates edited old installations',async t=>{
  const f=fixture(t),restored=await f.reopen(edited());
  const next=asset({releaseTag:'v1.2.0',releaseName:'1.2.0',sha256:sha('b')});
  assert.equal(Update.available(next,code,raw,restored,time),true);
});
test('external reinstall time invalidates the old edit proof and variant instead of reviving it',async t=>{
  const f=fixture(t),restored=await f.reopen(edited()),next=asset();
  assert.equal(Update.record(restored,bundle,code,time+1),undefined);
  assert.equal(Update.available(next,code,raw,restored,time+1),true);
  const hap=asset({sha256:sha('b')}),app=asset({name:'Miha-v1.1.5.app',sha256:sha('a')});
  assert.equal(selected([hap,app],restored,hap,time+1),hap);
});
test('another bundle cannot borrow a matching digest or raw version from an edited receipt',async t=>{
  const f=fixture(t),restored=await f.reopen(edited()),next=asset({bundleName:'com.other.application'});
  assert.equal(Update.record(restored,next.bundleName,code,time),undefined);
  assert.equal(Update.available(next,code,raw,restored,time),true);
});
for(const stage of [jobs.InstallStage.PACKAGE_INSPECTED,jobs.InstallStage.INSTALLING,jobs.InstallStage.WAITING_DEVICE,
  jobs.InstallStage.RETRYABLE_ERROR,jobs.InstallStage.TERMINAL_ERROR])
test('unfinished edit proof does not suppress installed-app updates; stage='+stage,async t=>{
  const f=fixture(t),restored=await f.reopen(edited({stage}));
  assert.equal(Update.record(restored,bundle,code,time),undefined);
  assert.equal(Update.available(asset(),code,raw,restored,time),true);
});
test('a local filename rename still selects the uniquely matching original APP digest instead of the default HAP',async t=>{
  const f=fixture(t),restored=await f.reopen(edited({assetName:'User-modified.app',editedSourceAssetName:'Renamed-download.app'}));
  const hap=asset({sha256:sha('b')}),app=asset({name:'Miha-v1.1.5.app'});
  assert.equal(selected([hap,app],restored),app);assert.equal(Update.available(app,code,raw,restored,time),false);
});
test('a newer APP preserves its container family when the prior original digest no longer exists in catalog',async t=>{
  const f=fixture(t),restored=await f.reopen(edited({assetName:'User-modified.app',editedSourceAssetName:'Miha-v1.1.4.app'}));
  const hap=asset({name:'Miha-v1.2.0.hap',sha256:sha('b'),releaseTag:'v1.2.0'}),app=asset({name:'Miha-v1.2.0.app',sha256:sha('d'),releaseTag:'v1.2.0'});
  assert.equal(selected([hap,app],restored),app);assert.equal(Update.available(app,code,raw,restored,time),true);
});
test('duplicate original digests cannot override a recorded APP/HAP variant',async t=>{
  const f=fixture(t),restored=await f.reopen(edited({assetName:'User-modified.app',editedSourceAssetName:'Miha-v1.1.5.app'}));
  const hap=asset(),app=asset({name:'Miha-v1.1.5.app'});assert.equal(selected([hap,app],restored),app);
});
test('digest variant selection remains restricted to the verified bundle and build number',async t=>{
  const f=fixture(t),restored=await f.reopen(edited({editedSourceAssetName:'Renamed-download.app'}));
  const hap=asset({sha256:sha('b')}),foreign=asset({name:'foreign.app',bundleName:'com.other.application'}),higher=asset({name:'Miha-v1.1.5.app',versionCode:code+1});
  assert.equal(selected([hap,foreign,higher],restored),undefined);
});
test('a proven ZIP container does not turn into a separate HAP merely because its inner original digest matches',async t=>{
  const f=fixture(t),zipName='Miha-v1.1.5.zip / arm64/app.hap',restored=await f.reopen(edited({catalogSha256:sha('e'),editedSourceAssetName:zipName}));
  const hap=asset(),zip=asset({name:zipName,sha256:sha('e'),url:'https://github.com/o/r/releases/download/v1.1.5/Miha.zip#qingqi-package=arm64%2Fapp.hap'});
  const choice=selected([hap,zip],restored);assert.equal(choice,zip);
  assert.equal(Update.available(choice,code,raw,restored,time),false);assert.equal(restored[0].expectedSha256,sha('c'));
  assert.equal(restored[0].editedSourceSha256,sha('a'));assert.equal(restored[0].catalogSha256,sha('e'));
});
test('same-code ZIP replacement still updates the ZIP variant while its old inner HAP is independently unchanged',async t=>{
  const f=fixture(t),zipName='Miha-v1.1.5.zip / arm64/app.hap',restored=await f.reopen(edited({catalogSha256:sha('e'),editedSourceAssetName:zipName}));
  const hap=asset(),nextZip=asset({name:zipName,sha256:sha('f'),url:'https://github.com/o/r/releases/download/v1.1.5/Miha.zip#qingqi-package=arm64%2Fapp.hap'});
  const choice=selected([hap,nextZip],restored);assert.equal(choice,nextZip);
  assert.equal(Update.available(choice,code,raw,restored,time),true);
});
test('unknown legacy ZIP inner provenance cannot be fabricated by same bundle/code or claimed catalog digest',async t=>{
  const f=fixture(t),old=edited({editedSourceSha256:'',editedSourceAssetName:'',packageSourceSha256:'',catalogSha256:'',releaseTag:'',releaseName:''});
  const restored=await f.reopen(old);assert.equal(restored[0].editedSourceSha256,'');assert.equal(restored[0].packageSourceSha256,'');
  assert.equal(Update.available(asset(),code,raw,restored,time),true);
});
