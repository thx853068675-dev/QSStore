const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const {loadEts}=require('./load_ets.cjs');
const {AppReview}=loadEts('data/StoreActions');
const {ReviewPage}=loadEts('data/StoreClient',{'./StoreActions':{AppReview}});
test('only a verified boolean ownership flag enables deleting a review',()=>{
 for(const value of [undefined,false,0,'true','1'])assert.equal(AppReview.fromJson({can_delete:value}).canDelete,false);
 for(const value of [true,1])assert.equal(AppReview.fromJson({can_delete:value}).canDelete,true);
});
test('review mutation responses retain the server page and recomputed rating',()=>{
 const result=ReviewPage.fromJson({items:[{id:4,can_delete:true}],total:20,page:1,page_size:20,summary:{count:20,average:4.2}},2,20);
 assert.equal(result.page,1);assert.equal(result.total,20);assert.equal(result.ratingCount,20);assert.equal(result.ratingAverage,4.2);assert.equal(result.items[0].canDelete,true);
});
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Detail.ets'),'utf8');
function fixture(){
 const f={actor:{userId:'owner',teamId:'team'},deleted:[],toasts:[],refreshes:[],answer:1};
 const begin=source.indexOf('  private applyReviewPage('),end=source.indexOf('  private async loadReviews()',begin);
 const box={JSON,Error,I18n:{t:x=>x},Palette:{forMode:()=>({text:'#111111',danger:'#DD0000'})},
  CatalogApp:{copy:a=>({...a})},getContext:()=>({}),errorText:e=>e.message,
  AccountSession:{load:async()=>f.actor},promptAction:{showDialog:async()=>({index:f.answer}),showToast:x=>f.toasts.push(x.message)},
  StoreClient:class{async deleteReview(...args){f.deleted.push(args);if(f.failure)throw Error('offline');return {items:[],total:20,page:1,ratingCount:20,ratingAverage:4.2};}}};
 vm.runInNewContext(ts.transpileModule(`class Page {${source.slice(begin,end)}};globalThis.Page=Page;`,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
 f.box=box;f.page=Object.assign(new box.Page(),{reviewOwnerScope:JSON.stringify(['owner','team']),reviewPage:2,reviewDeleteBusy:false,reviewBusy:false,
  reviewDeletePromptOpen:false,disposed:false,app:{id:5,ratingCount:21},fetchReviewPage:async p=>f.refreshes.push(p)});
 f.review={id:7,canDelete:true,body:'my review'};return f;
}
test('cancelled and foreign review actions cannot send a delete request',async()=>{
 const f=fixture();f.answer=0;await f.page.removeOwnReview(f.review);assert.equal(f.deleted.length,0);
 f.answer=1;await f.page.removeOwnReview({...f.review,canDelete:false});assert.equal(f.deleted.length,0);assert.equal(f.page.reviewDeletePromptOpen,false);
});
test('an outgoing sidebar scene can scroll but cannot start deleting a review',async()=>{
 const f=fixture();f.page.embedded=true;f.page.embeddedVisible=false;
 await f.page.removeOwnReview(f.review);assert.equal(f.deleted.length,0);assert.equal(f.page.reviewDeletePromptOpen,false);
});
test('an account change during confirmation never deletes using stale ownership',async()=>{
 const f=fixture();f.actor={userId:'another',teamId:'team'};await f.page.removeOwnReview(f.review);
 assert.equal(f.deleted.length,0);assert.equal(f.refreshes.length,1);assert.match(f.toasts[0],/账号已变更/);
});
test('confirmed deletion updates counts, rating, and last-page navigation immediately',async()=>{
 const f=fixture();await f.page.removeOwnReview(f.review);assert.equal(f.deleted.length,1);
 assert.deepEqual(f.deleted[0].slice(0,3),[5,7,2]);assert.equal(f.page.reviewPage,1);assert.equal(f.page.reviewTotal,20);
 assert.equal(f.page.app.ratingCount,20);assert.equal(f.page.app.ratingAverage,4.2);assert.equal(f.page.reviewDeleteBusy,false);
});
test('an uncertain delete failure refreshes the listing rather than deleting again',async()=>{
 const f=fixture();f.failure=true;await f.page.removeOwnReview(f.review);
 assert.equal(f.deleted.length,1);assert.equal(f.refreshes.length,1);assert.equal(f.page.reviewDeleteBusy,false);
});
