const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const s=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8'),start=s.indexOf('  onBackPress(): boolean');
const code=s.slice(start,s.indexOf('\n  }',start)+4);
function fixture(){const cleared=[],box={InstallReconnect:{clear:id=>cleared.push(id)}};
 vm.runInNewContext(ts.transpileModule('class Page {'+code+'};globalThis.Page=Page;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const page=new box.Page();Object.assign(page,{animateOverlay:fn=>fn(),dismissCardActions:index=>{page.dismissedAction=index;page.showCardActions=false;},configSourceGeneration:1,removingId:0,submitGeneration:1,submitDraft:{inspectionStatus:'ready'},resumeJobId:'job',completeRefreshConnection:ok=>page.connected=ok});
 return {page,cleared};}
test('Back closes the uppermost overlay without exiting or dismissing lower ones',()=>{
 const {page,cleared}=fixture();Object.assign(page,{showLocalProfiles:true,showCardActions:true,showCertSheet:true,showReconnect:true,showRenewal:true,showSubmit:true,showAppConfig:true});
 for(const flag of ['showLocalProfiles','showCardActions','showCertSheet','showReconnect','showRenewal','showSubmit','showAppConfig']){
  assert.equal(page.onBackPress(),true);assert.equal(page[flag],false);
 }
 assert.equal(page.onBackPress(),false);assert.deepEqual(cleared,['job']);assert.equal(page.connected,false);
});
test('closing a source inspection invalidates its response; saving or unlisting consumes Back while busy',()=>{
 const {page}=fixture();Object.assign(page,{showAppConfig:true,configBusy:true,configSourceChecking:true});
 assert.equal(page.onBackPress(),true);assert.equal(page.showAppConfig,false);assert.equal(page.configSourceGeneration,2);
 Object.assign(page,{showAppConfig:true,configBusy:true,configSourceChecking:false});
 assert.equal(page.onBackPress(),true);assert.equal(page.showAppConfig,true);
 Object.assign(page,{configBusy:false,removingId:42});assert.equal(page.onBackPress(),true);assert.equal(page.showAppConfig,true);
});
test('a live reconnect or final submission cannot accidentally exit the application',()=>{
 const {page}=fixture();Object.assign(page,{showReconnect:true,reconnectBusy:true});
 assert.equal(page.onBackPress(),true);assert.equal(page.showReconnect,true);
 Object.assign(page,{showReconnect:false,showSubmit:true,submitBusy:true});
 assert.equal(page.onBackPress(),true);assert.equal(page.showSubmit,true);
 page.submitDraft.inspectionStatus='pending';assert.equal(page.onBackPress(),true);assert.equal(page.showSubmit,false);
});
