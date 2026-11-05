const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

function fixture() {
  const state = new Map();
  const versions = new Map([['com.example.one', 10001]]);
  const jobs = [{ appId: 1, bundleName: 'com.example.one' }];
  const sent = [];
  const account = { userId: 'developer-one' };let currentAccount=account;const cloudCalls=[];let cloud=async()=>({configured:false});
  const store = {
    get: async (key, fallback) => state.has(key) ? state.get(key) : fallback,
    put: async (key, value) => { state.set(key, value); }, flush: async () => {}
  };
  class Item { constructor() { this.app_id = 0; this.bundle_name = ''; this.version_code = 0; } }
  class Client {
    async updatePushState(a,id){cloudCalls.push({account:a.userId,id});return cloud(a,id);}
    async updatePushWatchlist(_account, _clientId, items) {
      sent.push(JSON.parse(JSON.stringify(items)));
      return { watched_count: items.length };
    }
  }
  const sync = loadEts('data/UpdatePushSync', {
    '@kit.ArkData': { preferences: { getPreferences: async () => store } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '01234567-89ab-cdef-0123-456789abcdef' } },
    './FollowingRegistry': { FollowingRegistry:{sync:async()=>{}} },
    './UpdatePolicy': { UpdatePolicy:{restore:async()=>{},disabled:()=>false} },
    './DeveloperAccount': { AccountSession: { load: async () => currentAccount } },
    './StoreClient': { StoreClient: Client, UpdatePushWatchItem: Item },
    '../jobs/InstalledAppRegistry': { InstalledAppRegistry: {
      load: async () => {}, version: name => versions.get(name) ?? -1
    } },
    '../jobs/JobStore': { JobStore: { open: async () => ({ listAll: async () => jobs }) } },
    './PrivacyConsent': { PrivacyConsent: { isBusinessAllowed: () => true } }
  }).UpdatePushSync;
  return { sync, state, versions, jobs, sent, account,cloudCalls,setCloud:c=>cloud=c,setAccount:a=>currentAccount=a };
}

test('MeoW watchlist follows installation, update and removal without unchanged requests', async () => {
  const f = fixture(), context = {};
  await f.sync.setConfigured(context, f.account, true);
  await f.sync.sync(context);
  assert.deepEqual(f.sent[0], [{ app_id: 1, bundle_name: 'com.example.one', version_code: 10001 }]);
  await f.sync.sync(context);
  assert.equal(f.sent.length, 1);

  f.jobs.push({ appId: 2, bundleName: 'com.example.two' });
  f.versions.set('com.example.two', 1);
  await f.sync.sync(context);
  assert.equal(f.sent[1].length, 2);

  f.versions.set('com.example.one', 0);
  await f.sync.sync(context);
  assert.deepEqual(f.sent[2], [{ app_id: 2, bundle_name: 'com.example.two', version_code: 1 }]);

  f.versions.set('com.example.two', -1);
  await f.sync.sync(context);
  assert.equal(f.sent.length, 3, 'unknown device state must retain the last confirmed watchlist');
});

// Reinstall/new-device preferences are empty; restore only with verified server evidence.
test('a fresh client restores account MeoW configuration before syncing only its real inventory',async()=>{
 const f=fixture();f.setCloud(async()=>({configured:true,enabled:false,channel:'meow',nickname:'verified'}));
 await f.sync.sync({});assert.equal(f.cloudCalls.length,1);assert.equal(f.state.get('configured'),true);assert.equal(f.state.get('accountId'),f.account.userId);assert.equal(f.sent.length,1);
 assert.deepEqual(f.sent[0],[{app_id:1,bundle_name:'com.example.one',version_code:10001}]);
 await f.sync.sync({});assert.equal(f.cloudCalls.length,1);assert.equal(f.sent.length,1);
});
test('an account without verified server configuration is not auto-subscribed and probes are bounded',async()=>{
 const f=fixture();await f.sync.sync({});await f.sync.sync({});assert.equal(f.cloudCalls.length,1);assert.equal(f.sent.length,0);assert.equal(f.state.get('configured'),false);
});
test('explicit refresh can recover a newly bound account during the automatic probe cooldown',async()=>{
 const f=fixture();await f.sync.sync({});f.setCloud(async()=>({configured:true,channel:'meow'}));await f.sync.sync({},true);
 assert.equal(f.cloudCalls.length,2);assert.equal(f.sent.length,1);
});
test('a cloud response arriving after account switch does not save or register the old account',async()=>{
 const f=fixture();let finish;f.setCloud(()=>new Promise(done=>finish=done));const flight=f.sync.sync({});
 while(!finish)await new Promise(setImmediate);f.setAccount({userId:'developer-two'});finish({configured:true});await flight;
 assert.equal(f.sent.length,0);assert.equal(f.state.has('accountId'),false);
});
