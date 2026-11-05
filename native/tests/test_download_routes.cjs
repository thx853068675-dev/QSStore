const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
 '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/jobs/DownloadRoutes.ets'),'utf8');
function routes(connection={},clock={setTimeout,clearTimeout}) {
 const x={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
  {exports:x,require:()=>({connection}),...clock});return x.DownloadRoutes;
}
const origin='https://github.com/o/r/releases/download/v1/a.zip#qingqi-package=entry.hap';
const mirror='https://gh-proxy.com/'+origin;
test('VPN prioritizes the exact official URL and retains all mirror fallbacks and package selection',()=>{
 assert.deepEqual(Array.from(routes().order(mirror,[mirror,'http://bad',origin,'https://ghfast.top/'+origin],true)),
  [origin,mirror,'https://ghfast.top/'+origin]);
 assert.deepEqual(Array.from(routes().order(mirror,[origin],false)),[mirror,origin]);
 assert.deepEqual(Array.from(routes().order(mirror,['https://github.com.evil.example/a',origin],true)),
  [origin,mirror,'https://github.com.evil.example/a']);
});
test('an explicitly chosen GitHub mirror wins over VPN and retains package selection and default routes',()=>{
 const custom='https://mirror.example/proxy/';
 const extra='https://ghfast.top/'+origin;
 assert.deepEqual(Array.from(routes().order(mirror,[origin,extra,origin],true,custom)),
  [custom+origin,origin,mirror,extra]);
 assert.deepEqual(Array.from(routes().order(mirror,[origin,extra],false,custom)),
  [custom+origin,mirror,origin,extra]);
 assert.deepEqual(Array.from(routes().order(origin,[origin],false,'https://mirror.example')),
  ['https://mirror.example/'+origin,origin]);
});
test('a proxy-only legacy URL recovers an exact GitHub release without nesting proxies',()=>{
 const custom='https://mirror.example/';
 assert.deepEqual(Array.from(routes().order(mirror,[],false,custom)),[custom+origin,mirror,origin]);
 assert.deepEqual(Array.from(routes().order(custom+origin,[origin],false,custom)),[custom+origin,origin]);
});
test('custom mirrors do not rewrite Gitee, ordinary HTTPS assets, CDN URLs or lookalike domains',()=>{
 for(const unrelated of [
  'https://gitee.com/o/r/releases/download/v1/a.hap',
  'https://cdn.example/a.hap','https://release-assets.githubusercontent.com/a.hap',
  'https://github.com.evil.example/o/r/releases/download/v1/a.hap',
  'https://github.com/o/r/archive/refs/tags/v1.zip',
  'https://proxy.example/?url='+origin,
  'https://proxy.example/a.zip#'+origin,
  'https://proxy.example/https://github.com.evil.example/o/r/releases/download/v1/a.hap'
 ]) assert.deepEqual(Array.from(routes().order(unrelated,[],false,'https://custom.example/')),[unrelated]);
});
test('release queries never disclose URL credentials to a newly configured mirror',()=>{
 const custom='https://custom.example/';
 for(const query of ['?access_token=TEST_ONLY','?token=TEST_ONLY','?download=1']) {
  const direct=origin.replace('#qingqi-package=entry.hap','')+query+'#qingqi-package=entry.hap';
  const prior='https://gh-proxy.com/'+direct;
  assert.deepEqual(Array.from(routes().order(direct,[],false,custom)),[direct]);
  assert.deepEqual(Array.from(routes().order(prior,[direct],false,custom)),[prior,direct],
   'retain existing routes exactly, without forwarding queries to another mirror');
  assert.deepEqual(Array.from(routes().order(prior,[],false,custom)),[prior]);
 }
});
test('off or unusable custom prefixes leave the prior VPN and default ordering intact',()=>{
 for(const custom of ['', 'http://mirror.example/', 'https://user@mirror.example/',
  'https://mirror.example/?token=a','https://mirror.example/#x','https://mirror.example/{url}']) {
  assert.deepEqual(Array.from(routes().order(mirror,[origin],false,custom)),[mirror,origin]);
  assert.deepEqual(Array.from(routes().order(mirror,[origin],true,custom)),[origin,mirror]);
 }
});
test('normalized IPv6 and path prefixes are used verbatim instead of dropping a valid setting',()=>{
 assert.deepEqual(Array.from(routes().order(origin,[],false,'https://[2001:db8::1]:8443/proxy/')),
  ['https://[2001:db8::1]:8443/proxy/'+origin,origin]);
 assert.deepEqual(Array.from(routes().order(origin,[],false,'https://mirror.example/proxy//')),
  ['https://mirror.example/proxy//'+origin,origin]);
});
test('turning a mirror off retires only its recorded exact route and restores default fallbacks',()=>{
 const old='https://old.example/proxy/';
 assert.deepEqual(Array.from(routes().order(old+origin,[mirror,origin],false,'',old)),[mirror,origin]);
 assert.deepEqual(Array.from(routes().order(old+origin,[],false,'',old)),[origin],
  'a custom-only journal must retain its recovered original when switched off');
 assert.deepEqual(Array.from(routes().order(old+origin,[mirror,origin],true,'',old)),[origin,mirror]);
});
test('replacing a mirror does not retain an obsolete route or nest it inside the new prefix',()=>{
 const old='https://old.example/proxy/',next='https://new.example/';
 assert.deepEqual(Array.from(routes().order(old+origin,[mirror,origin,old+origin],false,next,old)),
  [next+origin,mirror,origin]);
});
test('legacy or mismatched provenance never deletes an unrelated saved URL',()=>{
 const old='https://old.example/';
 assert.deepEqual(Array.from(routes().order(old+origin,[mirror,origin],false)),[old+origin,mirror,origin]);
 for(const unrelated of [
  old+'https://github.com.evil.example/o/r/releases/download/v1/a.hap',
  old+'https://gitee.com/o/r/releases/download/v1/a.hap',
  'https://old.example.evil.example/'+origin
 ]) assert.deepEqual(Array.from(routes().order(unrelated,[],false,'',old)),[unrelated]);
});
test('VPN detection checks all active networks rather than assuming the default Wi-Fi is the tunnel',async()=>{
 const r=routes({getAllNets:async()=>[{netId:1},{netId:2}],NetBearType:{BEARER_VPN:4},
  getNetCapabilities:async n=>({bearerTypes:n.netId===1?[1]:[4]})});
 assert.equal(await r.vpnEnabled(),true);
});
test('a vanished network does not hide a VPN; permission errors retain the ordinary ordering',async()=>{
 const r=routes({getAllNets:async()=>[{netId:1},{netId:2}],NetBearType:{BEARER_VPN:4},
  getNetCapabilities:async n=>{if(n.netId===1)throw Error('vanished');return{bearerTypes:[4]};}});
 assert.equal(await r.vpnEnabled(),true);
 assert.equal(await routes({getAllNets:async()=>{throw Error('201');}}).vpnEnabled(),false);
});
test('an unresponsive network service has a bounded wait',async()=>{
 let finish;const r=routes({getAllNets:()=>new Promise(()=>{})},
  {setTimeout:(fn,delay)=>{assert.equal(delay,600);finish=fn;return 1;},clearTimeout:()=>{}});
 const result=r.vpnEnabled();finish();assert.equal(await result,false);
});
