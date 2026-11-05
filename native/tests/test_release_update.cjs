const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { releaseUpdate } = require('./release_update_fixture.cjs');
const { InstallJob, InstallStage } = loadEts('jobs/InstallJob');
const { HapAsset } = loadEts('data/ReleaseInfo');
const Update = releaseUpdate();

test('a fixed preview tag with a new actual build upgrades once and preserves the tag identity', () => {
  const next=Object.assign(new HapAsset(), {bundleName:'com.tonghongxiang.quietstart',versionCode:120391,
    versionName:'1.2.2-beta',releaseTag:'v1.2.2-beta-120375',releaseName:'轻启 1.2.2-beta（120391）',
    sha256:'b'.repeat(64)});
  assert.equal(Update.version(next),'1.2.2-beta-120391');
  assert.equal(Update.available(next,120375,'1.2.2-beta',[]),true);
  assert.equal(Update.available(next,120391,'1.2.2-beta',[]),false);
  assert.equal(Update.available(next,120392,'1.2.2-beta',[]),false);
  assert.equal(next.releaseTag,'v1.2.2-beta-120375');
  const completed=Object.assign(new InstallJob(),{bundleName:next.bundleName,versionCode:next.versionCode,
    versionName:next.versionName,releaseTag:next.releaseTag,releaseName:next.releaseName,
    expectedSha256:next.sha256,stage:InstallStage.INSTALLED,updatedAt:4000});
  assert.equal(Update.available(next,120391,'1.2.2-beta',[completed]),false);
});

test('120391 stays current after a tag rename even with incomplete or unavailable first-install receipts', () => {
  const next=Object.assign(new HapAsset(),{bundleName:'com.tonghongxiang.quietstart',versionCode:120391,
    versionName:'1.2.2-beta',releaseTag:'v1.2.2-beta-120391',releaseName:'轻启 1.2.2-beta（120391）',
    sha256:'b'.repeat(64)});
  const legacy=Object.assign(new InstallJob(),{bundleName:next.bundleName,versionCode:120391,
    versionName:'1.2.2-beta',releaseTag:'v1.2.2-beta-120375',releaseName:'轻启 1.2.2-beta（120375）',
    stage:InstallStage.INSTALLED,updatedAt:4000});
  for(const [jobs,time,name] of [[[],0,'1.2.2-beta'],[[legacy],0,'1.2.2-beta'],
    [[legacy],0,''],[[{...legacy,installedUpdateTime:3000}],5000,'1.2.2-beta']]) {
    assert.equal(Update.available(next,120391,name,jobs,time),false);
    assert.equal(Update.older(next,120391,name,jobs,time),false);
  }
  // Same-number changed bytes remain eligible when a confirmed receipt proves the change.
  const changed={...legacy,expectedSha256:'a'.repeat(64)};
  assert.equal(Update.available(next,120391,'1.2.2-beta',[changed]),true);
  changed.catalogSha256=next.sha256;
  assert.equal(Update.available(next,120391,'1.2.2-beta',[changed]),false);
  assert.equal(Update.available(next,120390,'1.2.2-beta',[legacy]),true);
  assert.equal(Update.available(next,120392,'1.2.2-beta',[legacy]),false);
});
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
