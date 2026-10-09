const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { releaseUpdate } = require('./release_update_fixture.cjs');
const { InstallJob, InstallStage } = loadEts('jobs/InstallJob');
const { HapAsset } = loadEts('data/ReleaseInfo');
const Update = releaseUpdate();
function asset(tag='1.2.6', sha='b'.repeat(64), code=1000000) {
  const a=HapAsset.fromJson({name:'entry-default-unsigned.hap',bundle_name:'com.example.nga_oh',
    version_code:code,version_name:'1.0.0',sha256:sha,
    url:`https://github.com/o/r/releases/download/${tag}/entry-default-unsigned.hap`});
  return a;
}
function record(tag='1.2.5', sha='a'.repeat(64), at=2000) {
  return Object.assign(new InstallJob(), { id:tag,appId:26,bundleName:'com.example.nga_oh',
    sourceUrl:`https://gh-proxy.com/https://github.com/o/r/releases/download/${tag}/entry-default-unsigned.hap`,
    assetName:'entry-default-unsigned.hap',versionCode:1000000,versionName:'1.0.0',
    expectedSha256:sha,stage:InstallStage.INSTALLED,updatedAt:at,
    stageHistory:[{stage:InstallStage.INSTALLED,at}] });
}
test('LNGA advances by release when internal build numbers remain fixed, then stops offering the installed release',()=>{
  const latest=asset(),old=record();
  assert.equal(Update.available(latest,1000000,'1.0.0',[old]),true);
  const installed=record('1.2.6','b'.repeat(64),3000);
  assert.equal(Update.available(latest,1000000,'1.0.0',[installed,old]),false);
  assert.equal(Update.available(latest,1000000,'1.0.0',[record('1.2.7')]),false);
});
test('higher internal codes update even for the same release, and release tags never bypass the internal downgrade floor',()=>{
  assert.equal(Update.available(asset('1.2.5','b'.repeat(64),1000001),1000000,'1.0.0',[record()]),true);
  assert.equal(Update.available(asset('9.0.0','b'.repeat(64),999999),1000000,'1.0.0',[record()]),false);
});
test('same bytes suppress tag-only re-releases and same-tag changed bytes can update once',()=>{
  assert.equal(Update.available(asset('1.2.6','a'.repeat(64)),1000000,'1.0.0',[record()]),false);
  assert.equal(Update.available(asset(),1000000,'1.0.0',[record('1.2.6')]),true);
  const signed=record('1.2.6','c'.repeat(64));signed.catalogSha256='b'.repeat(64);
  assert.equal(Update.available(asset(),1000000,'1.0.0',[signed]),false);
  assert.equal(Update.available(asset('1.2.6',''),1000000,'1.0.0',[record('1.2.6')]),false);
});
test('comparison handles numeric segments, previews, stable promotions and build metadata',()=>{
  for(const [a,b,order] of [['1.2.10','1.2.9',1],['1.2.6','1.2.6-beta.2',1],
    ['1.2.6-beta.10','1.2.6-beta.2',1],['1.2.6-alpha','1.2.6-beta',-1],
    ['1.2.6+build.7','1.2.6+build.2',0],['1.2','1.2.0',0]])assert.equal(Update.compare(a,b),order);
  assert.equal(Update.compare('nightly','1.2.6'),undefined);
});
test('cleanup saves cannot make an old release newest, and external replacements invalidate old installation evidence',()=>{
  const old=record('1.2.5','a'.repeat(64),2000),latest=record('1.2.6','b'.repeat(64),3000);
  old.updatedAt=99999;
  assert.equal(Update.record([old,latest],latest.bundleName,1000000),latest);
  latest.installedUpdateTime=2800;
  assert.equal(Update.record([old,latest],latest.bundleName,1000000,4000),undefined);
  assert.equal(Update.record([old,latest],latest.bundleName,1000000,2800),latest);
});
test('offline installs without release history can update once, failed and other-bundle jobs cannot suppress it',()=>{
  assert.equal(Update.available(asset(),1000000,'1.0.0',[]),true);
  const failed=record('1.2.6','b'.repeat(64));failed.stage=InstallStage.RETRYABLE_ERROR;
  const other=record('1.2.6','b'.repeat(64));other.bundleName='com.example.other';
  assert.equal(Update.available(asset(),1000000,'1.0.0',[failed,other]),true);
  assert.equal(Update.available(asset(),0,'1.0.0',[]),false);
  assert.equal(Update.available(asset(),-1,'1.0.0',[]),false);
});
