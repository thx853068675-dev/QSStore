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
