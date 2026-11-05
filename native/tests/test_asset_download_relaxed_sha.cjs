const { publicConsentModule } = require('./load_ets.cjs');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function loadAssetDownload(mocks, globals = {}) {
  const cancellation = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/JobCancellation.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports: cancellation });
  const routes = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/jobs/DownloadRoutes.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports: routes, require: name => mocks[name] || publicConsentModule(name), setTimeout, clearTimeout });
  const file = path.join(__dirname, '../entry/src/main/ets/jobs/AssetDownload.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: name => mocks[name] ||
    (name === './DownloadLibrary' ? { DownloadLibrary: { directory: () => '/sandbox/downloads' } } : undefined) ||
    (name === '../data/GitHubMirrorPreferences' ? { GitHubMirrorPreferences: {
      load: async () => ({ enabled: false, address: '' })
    } } : undefined) ||
    (name === './JobCancellation' ? cancellation : name === './DownloadRoutes' ? routes : publicConsentModule(name)),
    console: { info: () => {} },
    setTimeout, clearTimeout, ...globals });
  return exports.AssetDownload;
}

test('public directory authorization finishes before planning install paths', async () => {
  let resolve, ready = false;
  const created = [], gate = new Promise(done => resolve = done);
  const AssetDownload = loadAssetDownload({
    './DownloadLibrary': { DownloadLibrary: { directory: async () => { await gate; ready = true; return '/Download/轻启·安装器'; } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, mkdirSync: name => {
      assert.equal(ready, true); created.push(name);
    } } }
  });
  const job = { appId: 7, assetName: 'app.hap', expectedSha256: 'a'.repeat(64), cachePath: '' };
  const task = new AssetDownload({ filesDir: '/sandbox' }, {}).planPaths(job);
  assert.equal(job.cachePath, ''); assert.deepEqual(created, []);
  resolve(); await task; assert.deepEqual(created, ['/sandbox/install-jobs']);
  assert.match(job.cachePath, /^\/sandbox\/install-jobs\//);
});

test('catalog identity still rejects a different application or version', () => {
  const file = path.join(__dirname, '../entry/src/main/ets/jobs/PackageInspector.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: () => ({}) });
  const actual = { bundleName: 'com.example.app', versionCode: 42 };
  exports.checkCatalogIdentity('com.example.app', 42, actual);
  assert.throws(() => exports.checkCatalogIdentity('com.example.other', 42, actual), /包名/);
  assert.throws(() => exports.checkCatalogIdentity('com.example.app', 43, actual), /版本/);
});

test('cancelling while download-directory authorization is pending cannot revive install paths', async () => {
  let resolve, cancelled = false;
  const created = [], gate = new Promise(done => resolve = done);
  const AssetDownload = loadAssetDownload({
    './DownloadLibrary': { DownloadLibrary: { directory: async () => { await gate; return '/Download/轻启·安装器'; } } },
    './JobCancellation': { JobCancellation: { assertActive: () => { if (cancelled) throw Error('cancelled'); } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, mkdirSync: name => created.push(name) } }
  });
  const job = { id: 'cancelled-job', appId: 7, assetName: 'app.hap', expectedSha256: '', cachePath: '' };
  const task = new AssetDownload({ filesDir: '/sandbox' }, {}).planPaths(job);
  cancelled = true; resolve(); await assert.rejects(task, /cancelled/);
  assert.equal(job.cachePath, ''); assert.deepEqual(created, []);
});

test('a completed HTTPS HAP installs despite a stale catalog SHA-256', async () => {
  const partPath = '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.hap.part';
  const files = new Set();
  const states = { initialized: 0, completed: 1 };
  let started = false;
  let removed = false;
  const request = { agent: {
    Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 }, State: {
      INITIALIZED: states.initialized, COMPLETED: states.completed
    },
    create: async () => ({ tid: 'transfer-1', start: async () => {
      started = true;
      files.add(partPath);
    } }),
    show: async () => ({ progress: { state: started ? states.completed : states.initialized,
      processed: 100, sizes: [100] } }),
    remove: async () => { removed = true; }
  } };
  const fileIo = {
    accessSync: name => files.has(name),
    renameSync: (oldName, newName) => { files.delete(oldName); files.add(newName); },
    unlinkSync: name => files.delete(name),
    mkdirSync: () => {}
  };
  const AssetDownload = loadAssetDownload({
    '@kit.BasicServicesKit': { request, BusinessError: class {} },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async () => 'b'.repeat(64) } },
    './InstallTaskState': { InstallTaskState: { downloadProgress: () => {} } }
  });
  const job = { id: '7:app.hap:' + 'a'.repeat(64), appId: 7,
    sourceUrl: 'https://example.org/app.hap', mirrorUrls: [],
    expectedSha256: 'a'.repeat(64),
    cachePath: '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.hap',
    signedPath: '/sandbox/install-jobs/7-' + 'a'.repeat(64) + '.signed.hap',
    transferTaskId: '' };
  const store = { save: async () => {} };
  const downloader = new AssetDownload({ filesDir: '/sandbox' }, store);
  await downloader.downloadAndVerify(job);
  assert.equal(job.expectedSha256, 'b'.repeat(64));
  assert.equal(await downloader.verifiedFileExists(job), true);
  assert.equal(files.has(job.cachePath), true);
  assert.equal(removed, true);
});

test('a release without SHA-256 downloads into a persistent cache path', async () => {
  const files = new Set();
  let saveas = '';
  let started = false;
  const request = { agent: {
    Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 }, State: {
      INITIALIZED: 0, COMPLETED: 1
    },
    create: async (_context, config) => {
      saveas = config.saveas;
      return { tid: 'transfer-2', start: async () => {
        started = true;
        files.add(saveas);
      } };
    },
    show: async () => ({ progress: { state: started ? 1 : 0,
      processed: 100, sizes: [100] } }),
    remove: async () => {}
  } };
  const fileIo = { accessSync: name => files.has(name), mkdirSync: () => {},
    unlinkSync: name => files.delete(name),
    renameSync: (oldName, newName) => { files.delete(oldName); files.add(newName); } };
  const AssetDownload = loadAssetDownload({
    '@kit.BasicServicesKit': { request, BusinessError: class {} },
    '@kit.CoreFileKit': { fileIo, hash: { hash: async () => 'c'.repeat(64) } },
    './InstallTaskState': { InstallTaskState: { downloadProgress: () => {} } }
  });
  const job = { id: '7:app.hap:https://example.org/app.hap', appId: 7, assetName: 'app.hap',
    sourceUrl: 'https://example.org/app.hap', mirrorUrls: [],
    expectedSha256: '', cachePath: '', signedPath: '', transferTaskId: '' };
  const saves = [];
  const downloader = new AssetDownload({ filesDir: '/sandbox' }, {
    save: async value => saves.push({ cachePath: value.cachePath, digest: value.expectedSha256 })
  });
  await downloader.downloadAndVerify(job);
  assert.match(job.cachePath, /\/7-download-[^/]+\.hap$/);
  assert.equal(job.expectedSha256, 'c'.repeat(64));
  assert.equal(files.has(job.cachePath), true);
  assert.ok(saves.some(row => row.cachePath === job.cachePath && row.digest === ''));
  assert.ok(saves.some(row => row.cachePath === job.cachePath && row.digest === 'c'.repeat(64)));
});

function suspendedDownload({ completedOnReturn = false, stillStalled = false } = {}) {
  let now = 0, started = false, reads = 0, polls = 0, removed = 0, created = 0;
  const files = new Set(), destination = '/sandbox/app.hap';
  const states = { INITIALIZED: 0, RUNNING: 1, COMPLETED: 2, FAILED: 3, REMOVED: 4 };
  const request = { agent: {
    Action: { DOWNLOAD: 1 }, Mode: { BACKGROUND: 1 }, State: states,
    create: async (_ctx, config) => {
      created++;
      assert.equal(config.mode, 1);
      assert.equal(config.gauge, true);
      return { tid: 'surviving-transfer', start: async () => { started = true; files.add(destination + '.part'); } };
    },
    show: async () => {
      if (!started) return { progress: { state: 0, processed: 0, sizes: [100] } };
      reads++;
      const done = completedOnReturn ? polls >= 1 : !stillStalled && polls >= 2;
      return { progress: { state: done ? 2 : 1, processed: done ? 100 : 0, sizes: [100] } };
    },
    getTask: async () => ({ pause: async () => {} }),
    remove: async () => { removed++; }
  } };
  const AssetDownload = loadAssetDownload({
    '@kit.BasicServicesKit': { request },
    '@kit.CoreFileKit': { fileIo: {
      accessSync: name => files.has(name), unlinkSync: name => files.delete(name),
      renameSync: (from, to) => { files.delete(from); files.add(to); }
    }, hash: { hash: async () => 'd'.repeat(64) } },
    './InstallTaskState': { InstallTaskState: { downloadProgress: () => {} } }
  }, {
    Date: { now: () => now },
    setTimeout: (callback, delay) => {
      polls++;
      // The first polling callback returns after a five-minute process freeze.
      now += polls === 1 ? 300000 : delay;
      callback(); return polls;
    }
  });
  const job = { id: 'background', appId: 1, assetName: 'app.hap', sourceUrl: 'https://example.org/a.hap',
    mirrorUrls: [], expectedSha256: '', cachePath: destination, signedPath: destination + '.signed', transferTaskId: '' };
  return { downloader: new AssetDownload({ filesDir: '/sandbox' }, { save: async () => {} }), job,
    evidence: () => ({ files, reads, created, removed, polls }) };
}

test('returning after suspension uses the completed system transfer without restarting it', async () => {
  const f = suspendedDownload({ completedOnReturn: true });
  await f.downloader.downloadAndVerify(f.job);
  const e = f.evidence();
  assert.equal(e.created, 1); assert.equal(e.removed, 1);
  assert.equal(e.files.has(f.job.cachePath), true);
  assert.equal(f.job.transferTaskId, '');
});

test('a surviving incomplete transfer gets a fresh stall budget after suspension', async () => {
  const f = suspendedDownload();
  await f.downloader.downloadAndVerify(f.job);
  assert.equal(f.evidence().created, 1);
  assert.equal(f.evidence().files.has(f.job.cachePath), true);
});

test('an actually stalled connection still fails after a full resumed stall budget', async () => {
  const f = suspendedDownload({ stillStalled: true });
  await assert.rejects(f.downloader.downloadAndVerify(f.job), /下载连接停滞/);
  assert.equal(f.evidence().removed, 1);
  assert.ok(f.evidence().polls >= 60);
});

test('an HTTP 200 invalid package is discarded and the next mirror is validated', async () => {
  const files = new Set(), started = [], validated = [];
  const Download = loadAssetDownload({
    '@kit.CoreFileKit': { fileIo: { accessSync: path => files.has(path),
      unlinkSync: path => files.delete(path) } }
  });
  const job = { id: 'mirror', cachePath: '/sandbox/pkg.hap', sourceUrl: 'https://first/pkg.hap',
    mirrorUrls: ['https://second/pkg.hap'], transferTaskId: '', expectedSha256: '' };
  const downloader = new Download({}, { save: async () => {} });
  downloader.downloadCurrentSource = async () => { started.push(job.sourceUrl); files.add(job.cachePath); job.expectedSha256 = 'a'.repeat(64); };
  downloader.discardTransfer = async () => {};
  await downloader.downloadAndVerify(job, undefined, async () => {
    validated.push(job.sourceUrl);
    if (job.sourceUrl.includes('first')) throw new Error('错误应用身份');
  });
  assert.deepEqual(started, ['https://first/pkg.hap', 'https://second/pkg.hap']);
  assert.deepEqual(validated, started); assert.equal(files.has(job.cachePath), true);
});
test('final network interruption retains the partial transfer for restart', async () => {
  const files = new Set(['/sandbox/pkg.hap.part']);
  const Download = loadAssetDownload({ '@kit.CoreFileKit': { fileIo: {
    accessSync: p => files.has(p), unlinkSync: p => files.delete(p) } } });
  const job = { id: 'network', cachePath: '/sandbox/pkg.hap', sourceUrl: 'https://first/pkg.hap',
    mirrorUrls: [], transferTaskId: 'live-agent', expectedSha256: '' };
  const downloader = new Download({}, { save: async () => {} });
  downloader.downloadCurrentSource = async () => { throw new Error('网络中断'); };
  downloader.discardTransfer = async () => { job.transferTaskId = ''; };
  await assert.rejects(downloader.downloadAndVerify(job), /网络中断/);
  assert.equal(files.has(job.cachePath + '.part'), true); assert.equal(job.transferTaskId, 'live-agent');
});

function routeFixture({ vpn=false, resumed=false, slow=true, noBytes=false, only=false,
 rate=512, total=1024*1024, mirrorSetting={enabled:false,address:''}, customFails=false,
 previousCustomPrefix='', failure={all:false} }={}) {
 let now=0, taskNo=0, preferenceReads=0;const created=[],removed=[],files=new Set();
 const tasks=new Map();
 const origin='https://github.com/o/r/releases/download/v1/app.hap',mirror='https://gh-proxy.com/'+origin;
 const job={id:'adaptive',appId:1,assetName:'app.hap',cachePath:'/sandbox/app.hap',signedPath:'',expectedSha256:'',
  sourceUrl:previousCustomPrefix?previousCustomPrefix+origin:mirror,
  mirrorUrls:only?[]:previousCustomPrefix?[mirror,origin]:[origin],
  customMirrorPrefix:previousCustomPrefix,transferTaskId:resumed?'resume':''};
 const initial={tid:'resume',config:{url:job.sourceUrl,saveas:job.cachePath+'.part'},started:true,at:0};tasks.set('resume',initial);
 if(resumed)files.add(job.cachePath+'.part');
 const State={INITIALIZED:0,RUNNING:1,COMPLETED:2,FAILED:3,REMOVED:4,RETRYING:5};
 const pause=async()=>{};
 const Download=loadAssetDownload({
  '../data/GitHubMirrorPreferences':{GitHubMirrorPreferences:{load:async()=>{
    preferenceReads++;return{...mirrorSetting};
  }}},
  '@kit.NetworkKit':{connection:{getAllNets:async()=>[{netId:1}],NetBearType:{BEARER_VPN:4},
    getNetCapabilities:async()=>({bearerTypes:vpn?[4]:[1]})}},
  '@kit.BasicServicesKit':{request:{agent:{State,Action:{DOWNLOAD:1},Mode:{BACKGROUND:1},
   create:async(_ctx,config)=>{assert.equal(config.metered,true);
    assert.equal(files.has(config.saveas),false,'a new source cannot append a previous source partial file');
    const t={tid:'task'+(++taskNo),config,started:false,at:now,
    start:async()=>{t.started=true;t.at=now;files.add(config.saveas);},pause};tasks.set(t.tid,t);created.push(config.url);return t;},
   getTask:async (_ctx,id)=>({...tasks.get(id),pause}),
   show:async id=>{const t=tasks.get(id);const elapsed=now-t.at;
    const custom=t.config.url!==origin&&t.config.url!==mirror;
    if(failure.all||custom&&customFails)return{reason:'mirror offline',progress:{state:t.started?3:0,processed:0,sizes:[total]}};
    const processed=t.config.url===origin||custom?total:noBytes?0:resumed&&elapsed>=180000?total:slow?Math.floor(elapsed/1000)*rate:total;
    return{progress:{state:!t.started?0:processed>=total?2:noBytes?5:1,processed,sizes:[total]}};},
   remove:async id=>removed.push(id)}}},
  '@kit.CoreFileKit':{fileIo:{accessSync:p=>files.has(p),unlinkSync:p=>files.delete(p),
   renameSync:(a,b)=>{files.delete(a);files.add(b);}},hash:{hash:async()=> 'e'.repeat(64)}},
  './InstallTaskState':{InstallTaskState:{downloadProgress:()=>{}}}
 },{Date:{now:()=>now},setTimeout:(cb,delay)=>{now+=delay;cb();return now;}});
 return{job,created,removed,files,download:new Download({}, {save:async()=>{}}),time:()=>now,
  preferenceReads:()=>preferenceReads};
}
test('a new VPN download bypasses the mirror and goes directly to GitHub',async()=>{
 const f=routeFixture({vpn:true});await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,['https://github.com/o/r/releases/download/v1/app.hap']);
});
test('a trickling first mirror switches after the bounded early speed window',async()=>{
 const f=routeFixture();await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,2);assert.equal(f.time(),15000);assert.equal(f.removed.length,2);
});
test('connection retries with no bytes switch after twelve seconds rather than one minute',async()=>{
 const f=routeFixture({noBytes:true});await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,2);assert.equal(f.time(),12000);
});
test('a resumed slow download keeps its original URL and partial file even when VPN is now on',async()=>{
 const f=routeFixture({vpn:true,resumed:true});await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,0);assert.equal(f.time(),180000);assert.equal(f.files.has(f.job.cachePath),true);
});
test('the last available source is not discarded merely because it is slow',async()=>{
 const f=routeFixture({only:true});await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,1);assert.ok(f.time()>15000);
});
test('a large package trickling at the measured VPN speed also tries another source',async()=>{
 const f=routeFixture({rate:16*1024,total:13*1024*1024});await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,2);assert.equal(f.time(),15000);
});
test('a small package already a quarter downloaded is allowed to finish on its current source',async()=>{
 const f=routeFixture({rate:16*1024,total:512*1024});await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,1);assert.equal(f.time(),32000);
});

test('a selected custom mirror takes precedence for a new VPN agent',async()=>{
 const f=routeFixture({vpn:true,mirrorSetting:{enabled:true,address:'https://custom.example/proxy/'}});
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,['https://custom.example/proxy/https://github.com/o/r/releases/download/v1/app.hap']);
 assert.equal(f.preferenceReads(),1);assert.equal(f.files.has(f.job.cachePath),true);
});
test('a saved mirror address has no effect until the user explicitly enables it',async()=>{
 const f=routeFixture({vpn:true,mirrorSetting:{enabled:false,address:'https://custom.example/'}});
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,['https://github.com/o/r/releases/download/v1/app.hap']);
 assert.equal(f.preferenceReads(),1);
});
test('a failed custom mirror falls back to the default server route and clears its partial first',async()=>{
 const f=routeFixture({slow:false,customFails:true,mirrorSetting:{enabled:true,address:'https://custom.example/'}});
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,[
  'https://custom.example/https://github.com/o/r/releases/download/v1/app.hap',
  'https://gh-proxy.com/https://github.com/o/r/releases/download/v1/app.hap'
 ]);
 assert.equal(f.removed.length,2);assert.equal(f.files.has(f.job.cachePath),true);
});
test('a proxy-only saved route still has a direct fallback when custom and default mirrors fail',async()=>{
 const f=routeFixture({only:true,noBytes:true,customFails:true,
  mirrorSetting:{enabled:true,address:'https://custom.example/'}});
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,[
  'https://custom.example/https://github.com/o/r/releases/download/v1/app.hap',
  'https://gh-proxy.com/https://github.com/o/r/releases/download/v1/app.hap',
  'https://github.com/o/r/releases/download/v1/app.hap'
 ]);
 assert.equal(f.time(),12000);assert.equal(f.files.has(f.job.cachePath),true);
});
test('changing mirror settings never reloads or reorders an already resumed system agent',async()=>{
 const setting={enabled:true,address:'https://changed.example/'};
 const f=routeFixture({vpn:true,resumed:true,mirrorSetting:setting});
 await f.download.downloadAndVerify(f.job);
 assert.equal(f.preferenceReads(),0);assert.equal(f.created.length,0);
 assert.equal(f.time(),180000);assert.equal(f.files.has(f.job.cachePath),true);
 assert.equal(f.job.sourceUrl,'https://gh-proxy.com/https://github.com/o/r/releases/download/v1/app.hap');
});
test('a verified local package does not read mirror preferences or create a replacement agent',async()=>{
 const f=routeFixture({mirrorSetting:{enabled:true,address:'https://custom.example/'}});
 f.files.add(f.job.cachePath);f.job.expectedSha256='e'.repeat(64);
 await f.download.downloadAndVerify(f.job);
 assert.equal(f.preferenceReads(),0);assert.equal(f.created.length,0);
});
test('turning off a previously selected mirror restores default routing for the next fresh transfer',async()=>{
 const f=routeFixture({slow:false,previousCustomPrefix:'https://old.example/proxy/',
  mirrorSetting:{enabled:false,address:'https://old.example/proxy/'}});
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,['https://gh-proxy.com/https://github.com/o/r/releases/download/v1/app.hap']);
 assert.equal(f.job.customMirrorPrefix,'');
 assert.ok(!f.job.mirrorUrls.some(url=>url.startsWith('https://old.example/')));
});
test('changing the setting after a successful transfer replaces its recorded prefix without nesting',async()=>{
 const setting={enabled:true,address:'https://first.example/'};
 const f=routeFixture({mirrorSetting:setting});
 await f.download.downloadAndVerify(f.job);
 assert.equal(f.job.customMirrorPrefix,setting.address);
 f.files.delete(f.job.cachePath);f.job.expectedSha256='';
 setting.address='https://second.example/path/';
 await f.download.downloadAndVerify(f.job);
 assert.deepEqual(f.created,[
  'https://first.example/https://github.com/o/r/releases/download/v1/app.hap',
  'https://second.example/path/https://github.com/o/r/releases/download/v1/app.hap'
 ]);
 assert.equal(f.job.customMirrorPrefix,setting.address);
 assert.ok(!f.job.mirrorUrls.some(url=>url.startsWith('https://first.example/')));
});
test('turning a failed mirror off after its agent is gone does not revive the obsolete URL on retry',async()=>{
 const setting={enabled:true,address:'https://first.example/'},failure={all:true};
 const f=routeFixture({mirrorSetting:setting,failure,slow:false});
 await assert.rejects(f.download.downloadAndVerify(f.job),/附件下载失败/);
 assert.equal(f.job.customMirrorPrefix,setting.address);
 await f.download.discardTransfer(f.job);
 setting.enabled=false;failure.all=false;
 const before=f.created.length;
 await f.download.downloadAndVerify(f.job);
 assert.equal(f.created.length,before+1);
 assert.equal(f.created[before],'https://github.com/o/r/releases/download/v1/app.hap');
 assert.equal(f.job.customMirrorPrefix,'');
 assert.ok(!f.job.mirrorUrls.some(url=>url.startsWith('https://first.example/')));
});
test('a live custom agent retains its recorded prefix even when the setting has been disabled',async()=>{
 const f=routeFixture({resumed:true,vpn:true,previousCustomPrefix:'https://old.example/path/',
  mirrorSetting:{enabled:false,address:'https://different.example/'}});
 await f.download.downloadAndVerify(f.job);
 assert.equal(f.preferenceReads(),0);assert.equal(f.created.length,0);
 assert.equal(f.job.sourceUrl,'https://old.example/path/https://github.com/o/r/releases/download/v1/app.hap');
 assert.equal(f.job.customMirrorPrefix,'https://old.example/path/');
});

test('retained identical package is validated and installed without creating a network transfer', async () => {
  const files=new Set();let validations=0,restores=0;
  const Download=loadAssetDownload({
    './DownloadLibrary':{DownloadLibrary:{restore:async (_ctx,job)=>{restores++;files.add(job.cachePath);return 'c'.repeat(64);}}},
    '@kit.CoreFileKit':{fileIo:{accessSync:p=>files.has(p)},hash:{hash:async ()=>'c'.repeat(64)}},
    '@kit.BasicServicesKit':{request:{agent:{create:()=>assert.fail('must reuse retained package')}}}
  });
  const job={id:'retained-reinstall',cachePath:'/sandbox/install-jobs/pkg.hap',signedPath:'/sandbox/install-jobs/pkg.signed.hap',
    sourceUrl:'https://example.com/pkg.hap',catalogSha256:'c'.repeat(64),expectedSha256:'',transferTaskId:''};
  await new Download({filesDir:'/sandbox'},{save:async ()=>{}}).downloadAndVerify(job,undefined,async ()=>{validations++;});
  assert.equal(restores,1);assert.equal(validations,1);assert.equal(job.expectedSha256,'c'.repeat(64));
});
