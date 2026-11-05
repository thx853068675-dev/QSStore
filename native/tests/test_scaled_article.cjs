const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root=path.join(__dirname,'../entry/src/main/ets');
function componentMethods(file,start,end){const text=fs.readFileSync(path.join(root,file),'utf8');return text.slice(text.indexOf(start),text.indexOf(end,text.indexOf(start)));}
function article(){
 const methods=componentMethods('components/ScaledArticle.ets','  onMeasureSize(','\n  build()');const box={};
 vm.runInNewContext(ts.transpileModule('class Article {'+methods+'};globalThis.Article=Article;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 return Object.assign(new box.Article(),{sceneScale:.84});
}
test('first measurement and every rotation preserve the entire article viewport without scaling the dock',()=>{
 const page=article();const calls=[];const child={measure:c=>{calls.push(c);return{width:c.maxWidth,height:c.maxHeight};}};
 for(const [width,height] of [[298,822],[726,362],[298,822],[1184,800]]){
  const result=page.onMeasureSize({width,height},[child],{maxWidth:width,maxHeight:height});
  const c=calls.at(-1);assert.equal(result.width,width);assert.equal(result.height,height);
  assert.ok(Math.abs(c.minWidth*.84-width)<1e-8);assert.equal(c.minWidth,c.maxWidth);
  assert.ok(Math.abs(c.minHeight*.84-height)<1e-8);assert.equal(c.minHeight,c.maxHeight);
 }
 const positions=[];page.onPlaceChildren({},[{layout:p=>positions.push(p)}],{});
 assert.deepEqual(JSON.parse(JSON.stringify(positions)),[{x:0,y:0}]);
});
test('ordinary detail uses the unchanged unscaled viewport',()=>{
 const page=article();page.sceneScale=1;let measured;
 const result=page.onMeasureSize({width:360,height:800},[{measure:c=>{measured=c;}}],{maxWidth:360,maxHeight:800});
 assert.equal(result.width,360);assert.equal(measured.minWidth,360);assert.equal(measured.minHeight,800);
});
function action(){
 const methods=componentMethods('pages/Detail.ets','  private performInstallAction(): void {','\n  private sidebarActionSize');
 const box={isPending:stage=>stage==='paused'};
 vm.runInNewContext(ts.transpileModule('class Detail {'+methods+'};globalThis.Detail=Detail;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 const calls=[];const page=Object.assign(new box.Detail(),{disposed:false,embedded:true,embeddedVisible:true,
  downloadBusy:false,installTargetCount:1,installTargetName:'',currentInstallTask:()=>undefined,
  installButtonEnabled:()=>true,installedForApp:()=>({bundleName:'a.b'}),updateAvailable:()=>false,
  openInstalled:app=>calls.push(['open',app.bundleName]),downloadSelected:()=>calls.push(['download']),
  resumeInstall:id=>calls.push(['resume',id])});return{page,calls};
}
test('the same action handles a first tap and a post-rotation tap while stale scenes cannot act',()=>{
 const {page,calls}=action();page.windowWidth=362;page.performInstallAction();
 page.windowWidth=822;page.performInstallAction();assert.deepEqual(calls,[['open','a.b'],['open','a.b']]);
 page.embeddedVisible=false;page.performInstallAction();assert.equal(calls.length,2);
 page.embeddedVisible=true;page.disposed=true;page.performInstallAction();assert.equal(calls.length,2);
});
test('pending work resumes once and a disabled or busy action never starts a new download',()=>{
 const {page,calls}=action();page.currentInstallTask=()=>({job:{id:'one',stage:'paused'}});page.performInstallAction();
 assert.deepEqual(calls,[['resume','one']]);page.currentInstallTask=()=>undefined;page.installButtonEnabled=()=>false;
 page.performInstallAction();assert.equal(calls.length,1);page.installButtonEnabled=()=>true;page.downloadBusy=true;
 page.performInstallAction();assert.equal(calls.length,1);
});
