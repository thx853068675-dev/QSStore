const {test}=require('node:test'), assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
function method(marker){const at=source.indexOf(marker);return source.slice(at,source.indexOf('\n  }',at)+4);}
function fixture(){let finish, calls=0;
 const box={getContext:()=>({}),SubmitDraft:class{inspectionStatus='ready';},Index:{SUBMIT_STATE_NEW:'new',TAB_MINE:3},
 StoreClient:class{async myApps(){return [];} prepareSubmit(){calls++;return new Promise(resolve=>{finish=resolve;});}},errorText:String};
 vm.runInNewContext(ts.transpileModule('class Page {'+method('  private openSubmitSheet(): void')+method('  private async prepareSubmit(): Promise<void>')+'};globalThis.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const page=new box.Page();Object.assign(page,{signedIn:true,showSubmit:true,submitGeneration:1,submitBusy:false,submitUrl:'https://gitee.com/o/r',animateOverlay:fn=>fn(),classifySubmitRepo:()=>{}});
 return {page,resolve:value=>finish(value),calls:()=>calls};}
test('reopening a canceled repository check releases busy and ignores the late response',async()=>{
 const f=fixture(),old=f.page.prepareSubmit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.calls(),1);assert.equal(f.page.submitBusy,true);
 f.page.openSubmitSheet();assert.equal(f.page.submitBusy,false);assert.equal(f.page.submitMessage,'');
 const fresh=f.page.submitDraft;
 f.resolve({inspectionStatus:'ready',choices:[{name:'stale.hap'}]});await old;
 assert.equal(f.page.submitDraft,fresh);assert.equal(f.page.submitBusy,false);
 const next=f.page.prepareSubmit();await new Promise(resolve=>setImmediate(resolve));assert.equal(f.calls(),2);
 f.resolve({inspectionStatus:'ready',choices:[{name:'new.app'}],categories:['工具'],suggestedCategory:'工具'});await next;
 assert.equal(f.page.submitAssets[0],'new.app');assert.equal(f.page.submitBusy,false);
});
