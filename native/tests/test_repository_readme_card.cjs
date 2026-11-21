const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
function fixture(){
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/components/RepositoryReadmeCard.ets'),'utf8');
 const start=source.indexOf('export struct RepositoryReadmeCard {'),end=source.indexOf('  build()',start);
 const code=source.slice(start,end).replace('export struct','class').replace(/@(StorageProp|Watch)\([^)]*\)\s*|@(Prop|State)\s*/g,'');
 const requests=[],box={exports:{},getContext:()=>({}),RepositoryReadme:class{found=false;html='';},
  AppBackground:class{containerOpacity=100;},
  webview:{WebviewController:class{}},errorText:e=>e.message,
  StoreClient:class{repositoryReadme(id,force,language){const gate=deferred();requests.push({id,language,gate});return gate.promise;}}};
 vm.runInNewContext(ts.transpileModule(code+'}\nexports.Card=RepositoryReadmeCard;',{
  compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}
 }).outputText,box);
 const card=new box.exports.Card();card.appId=3;card.expanded=true;
 return {card,requests};
}
test('switching UI language reloads an expanded README and discards the old language response',async()=>{
 const f=fixture(),c=f.card;c.appLanguage='en';const old=c.load();
 c.appLanguage='zh';c.onLanguageChanged();assert.deepEqual(f.requests.map(r=>r.language),['en','zh']);
 f.requests[1].gate.resolve({found:true,html:'中文'});await new Promise(setImmediate);
 assert.equal(c.document.html,'中文');assert(!c.busy);
 f.requests[0].gate.resolve({found:true,html:'English'});await old;
 assert.equal(c.document.html,'中文');
});
test('a folded README updates its language without loading until expanded',()=>{
 const f=fixture();f.card.expanded=false;f.card.fetched=true;f.card.onLanguageChanged();
 assert(!f.card.fetched);assert.equal(f.requests.length,0);
});
