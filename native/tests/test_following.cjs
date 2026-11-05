const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {loadEts}=require('./load_ets.cjs');
const {ManagementSort}=loadEts('data/ManagementSort');
const {CatalogApp}=loadEts('data/CatalogApp',{'./ReleaseInfo':loadEts('data/ReleaseInfo')});
const {FollowedApp,FollowChange}=loadEts('data/Following',{'./CatalogApp':{CatalogApp},'./DisplayVersion':loadEts('data/DisplayVersion'),'./ManagementSort':{ManagementSort}});
const tick=()=>new Promise(setImmediate);
function fixture(){
 const disk=new Map(),scopes=new Map(),changes=[],store={get:async(k,d)=>disk.has(k)?disk.get(k):d,put:async(k,v)=>{disk.set(k,v);},flush:async()=>{}};
 let account={userId:'a'},client=async(_a,rows)=>{changes.push(rows);return Array.from(scopes.get(account.userId)||[]);};
 let restore=async()=>{};const preview=new Set(),muted=new Set();
 const Registry=loadEts('data/FollowingRegistry',{
 '@kit.ArkData':{preferences:{getPreferences:async()=>store}},'./DeveloperAccount':{AccountSession:{load:async()=>account}},
 './Following':{FollowedApp,FollowChange},'./StoreClient':{StoreClient:class{following(...args){return client(...args);}}},
 './ReleaseChannelRegistry':{ReleaseChannelRegistry:{restore:()=>restore(),apply:a=>a,preview:id=>preview.has(id)}},'./UpdatePolicy':{UpdatePolicy:{restore:async()=>{},disabled:b=>muted.has(b)}}
 }).FollowingRegistry;
 return {Registry,disk,store,scopes,changes,preview,muted,setAccount:a=>account=a,setClient:c=>client=c,setRestore:r=>restore=r};
}
const app=id=>Object.assign(new CatalogApp(),{id,displayName:'应用 '+id,latestPublishedAt:'2026-10-21T00:00:00Z'});
test('management sort handles unknown times last, both directions, seconds and stable ties',()=>{
 assert.equal(ManagementSort.timestamp(0),0);assert.equal(ManagementSort.timestamp('0'),0);assert.equal(ManagementSort.timestamp(-1),0);
 assert.equal(ManagementSort.timestamp('bad'),0);assert.equal(ManagementSort.timestamp(1700000000),1700000000000);
 for(const direction of ['asc','desc'])assert.ok(ManagementSort.compare(0,10,direction,'a','b')>0);
 assert.ok(ManagementSort.compare(1,2,'asc','a','b')<0);assert.ok(ManagementSort.compare(1,2,'desc','a','b')>0);
 assert.ok(ManagementSort.compare(2,2,'desc','a','b')<0);
});
test('follow persists offline and scoped to the current account',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);assert.equal(R.has(1),true);assert.match(f.disk.get('account:a'),/应用 1/);
 f.setAccount({userId:'b'});await R.load({});assert.equal(R.entries().length,0);
 f.setAccount({userId:'a'});await R.load({});assert.equal(R.entries().length,1);assert.equal(R.has(1),true);
});
test('concurrent cache loads cannot wipe an immediate follow toggle',async()=>{
 const f=fixture();await Promise.all([f.Registry.load({}),f.Registry.load({}),f.Registry.set({},app(1),true)]);
 assert.equal(f.Registry.has(1),true);
});
test('unfollow while syncing cannot be resurrected by the stale response',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);
 let resolve;f.setClient(()=>new Promise(done=>resolve=done));const flight=R.sync({});await tick();await R.set({},app(1),false);
 resolve([FollowedApp.fromCatalog(app(1),false)]);await flight;assert.equal(R.has(1),false);
 f.setClient(async(_a,rows)=>{assert.equal(rows[0].enabled,false);return [];});await R.sync({});assert.equal(R.entries().length,0);
});
test('follow added during a sync is retained and sent next',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);let resolve;
 f.setClient(()=>new Promise(done=>resolve=done));const flight=R.sync({});await tick();await R.set({},app(2),true);
 resolve([FollowedApp.fromCatalog(app(1),false)]);await flight;assert.equal(R.has(2),true);
 f.setClient(async(_a,rows)=>{assert.equal(rows.length,1);assert.equal(rows[0].app_id,2);return R.entries();});await R.sync({});
});
test('failed disk write rolls back the visible toggle without erasing other follows',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);f.store.flush=async()=>{throw Error('disk full');};
 await assert.rejects(R.set({},app(2),true),/disk full/);assert.equal(R.has(1),true);assert.equal(R.has(2),false);
});
test('failed network sync preserves pending local follow',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);f.setClient(async()=>{throw Error('offline');});
 await assert.rejects(R.sync({}),/offline/);assert.equal(R.has(1),true);assert.match(f.disk.get('account:a'),/pending/);
});
test('an old account sync response never enters the new account',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);let resolve;f.setClient(()=>new Promise(done=>resolve=done));
 const flight=R.sync({});await tick();f.setAccount({userId:'b'});await R.load({});resolve([FollowedApp.fromCatalog(app(1),false)]);await flight;
 assert.equal(R.entries().length,0);
});
test('unchanged server response does not publish a list redraw',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);f.setClient(async()=>R.entries());let notifications=0;R.subscribe(()=>notifications++);
 await R.sync({});await R.sync({});assert.equal(notifications,0);
});
test('notification links reject unrelated schemes and unsafe IDs; preview remains explicit',()=>{
 const {NotificationTarget}=loadEts('jobs/NotificationOpen');
 assert.equal(NotificationTarget.parse('qingqi-installer://app/123?preview=1').preview,1);
 assert.equal(NotificationTarget.parse('qingqi-installer://following').section,'following');
 for(const uri of ['https://x','qingqi-installer://app/0','qingqi-installer://app/9007199254740992','qingqi-installer://app/1?preview=1&x=1','qingqi-installer://app/1/evil'])assert.equal(NotificationTarget.parse(uri),undefined);
});
test('empty follows have no management section; both swipe operations exist and sorting is plain',()=>{
 const index=fs.readFileSync(require('path').join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
 assert.match(index,/if\(this.followingCount>0\)\{/);assert.match(index,/new ManagementAction\('unfollow'/);assert.match(index,/new ManagementAction\('information'/);
 const control=fs.readFileSync(require('path').join(__dirname,'../entry/src/main/ets/components/ManagementSortControl.ets'),'utf8');
 assert.doesNotMatch(control,/StoreImmersiveAction|systemMaterialEffect/);
});

test('sort preferences remember independent directions and a slow restore cannot override a newer choice',async()=>{
 const disk=new Map(),published=new Map();let pause,gate;
 const store={get:async(k,d)=>{if(gate)await gate;return disk.has(k)?disk.get(k):d;},put:async(k,v)=>disk.set(k,v),flush:async()=>{}};
 const P=loadEts('data/ManagementSortPreferences',{'./ManagementSort':{ManagementSort},'@kit.ArkData':{preferences:{getPreferences:async()=>store}}},{AppStorage:{setOrCreate:(k,v)=>published.set(k,v)}}).ManagementSortPreferences;
 await P.save({},'installedKey','expiry');await P.save({},'installedDirection','asc');await P.save({},'followingDirection','desc');await P.load({});
 assert.equal(published.get('managementSort'),'expiry');assert.equal(published.get('managementDirection'),'asc');assert.equal(published.get('followingDirection'),'desc');
 gate=new Promise(done=>pause=done);const read=P.load({});await tick();published.set('managementSort','updated');await P.save({},'installedKey','updated');pause();await read;assert.equal(published.get('managementSort'),'updated');
});
test('notification routing waits for UI and processes a newer link received during an earlier navigation',async()=>{
 const routes=[],timers=[];let routeReady=false,finish;
 const N=loadEts('jobs/NotificationOpen',{'@kit.ArkUI':{router:{RouterMode:{Standard:0,Single:1}}},'../theme/StorePageMotion':{StorePageMotion:{pushUrl:options=>{routes.push(options);return routes.length===1?new Promise(done=>finish=done):Promise.resolve();}}}},
 {AppStorage:{setOrCreate:()=>{}},setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout:()=>{}}).NotificationOpen;
 N.receive({uri:'qingqi-installer://app/1?preview=0'});N.openPending();assert.equal(routes.length,0);
 N.configure({getRouter:()=>({getState:()=>routeReady?{path:'pages/Index'}:{}})});N.openPending();assert.equal(routes.length,0);
 routeReady=true;timers.shift()();assert.equal(routes.length,1);N.receive({uri:'qingqi-installer://app/2?preview=1'});N.openPending();finish();await tick();assert.equal(routes.length,2);assert.equal(routes[1].params.id,2);assert.equal(routes[1].params.notificationPreview,1);
});

test('account changed while channel preferences load cannot submit the new account changes with old credentials',async()=>{
 const f=fixture(),R=f.Registry;await R.set({},app(1),true);let unblock;
 f.setRestore(()=>new Promise(done=>unblock=done));const calls=[];f.setClient(async(a,rows)=>{calls.push([a.userId,rows]);return [];});
 const flight=R.sync({});await tick();f.setAccount({userId:'b'});await R.load({});await R.set({},app(2),true);unblock();await flight;
 assert.equal(calls.length,0);assert.equal(R.has(2),true);
});

test('first follow closes only the mounted tab, and an animation error never prevents saving',async()=>{
 const path=require('path'),vm=require('vm'),ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
 const methods=['closeFollowSwipe','toggleFollow'].map(name=>{const start=source.indexOf(name==='toggleFollow'?'  private async '+name+'(':'  private '+name+'(');return source.slice(start,source.indexOf('\n  }',start)+4);}).join('\n');
 const calls=[],box={Index:{TAB_MANAGE:2},FollowingRegistry:{has:()=>false,set:async()=>calls.push('save')},ForegroundIdle:{interaction:()=>{}},getContext:()=>({}),promptAction:{showToast:()=>{}}};
 vm.runInNewContext(ts.transpileModule('class Page{'+methods+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const page=Object.assign(new box.Page(),{currentTab:0,discoverScroller:{closeAllSwipeActions:()=>calls.push('discover-close')},managementScroller:{closeAllSwipeActions:()=>{throw Error('unbound');}},syncFollowing:()=>calls.push('network')});
 await page.toggleFollow(app(1));assert.deepEqual(calls,['discover-close','save','network']);
 calls.length=0;page.currentTab=2;await page.toggleFollow(app(1));assert.deepEqual(calls,['save','network']);
});
