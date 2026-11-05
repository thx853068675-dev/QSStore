const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root=path.join(__dirname,'../entry/src/main/ets/components');
const {DeviceSpatialLayout}=require('./load_ets.cjs').loadEts('components/DeviceSpatialLayout');
const {DeviceDiscoveryIndex:DiscoveryIndex}=require('./load_ets.cjs').loadEts('data/DeviceDiscoveryIndex');
function methods(file,names,globals={}){
 const source=fs.readFileSync(path.join(root,file+'.ets'),'utf8');
 const body=names.map(name=>{const start=source.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert(start>=0,name);
  let open=source.indexOf('{',start),depth=1,end=open+1;for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;if(source[end]==='}')depth--;}
  return source.slice(start,end);
 }).join('\n');
 const box={...globals};vm.runInNewContext(ts.transpileModule('class Subject{'+body+'};globalThis.Subject=Subject;',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);const subject=new box.Subject();subject.modalChanged=()=>{};Object.assign(subject,{index:new DiscoveryIndex(),lanHosts:[],alive:true,active:true,moving:false,discoveryPage:0,listVisible:false,linePaintKey:'',flushTimer:-1,pendingDiscovery:false,reportedHeight:-1});return subject;
}
test('orb touch drag uses stable screen coordinates, crosses the threshold once, and ends once',()=>{
 const TouchType={Down:0,Move:1,Up:2,Cancel:3},events=[];
 const row=methods('DeviceGlassCircle',['dragTouch'],{TouchType});Object.assign(row,{dragEnabled:true,touchMoved:false,
  dragStart:()=>events.push('start'),dragUpdate:(x,y)=>events.push([x,y]),dragEnd:()=>events.push('end')});
 const send=(type,x,y)=>row.dragTouch({type,touches:[{screenX:x,screenY:y}],changedTouches:[],stopPropagation(){}});
 send(0,310,500);send(1,307,498);assert.equal(events.length,0);send(1,280,480);send(1,100,450);send(2,100,450);
 assert.deepEqual(events,['start',[-30,-20],[-210,-50],'end']);assert.equal(row.touchMoved,true);
 send(0,100,450);assert.equal(row.touchMoved,false,'the next tap opens normally after a drag');
});
test('ordinary spatial nodes leave vertical scrolling gestures alone',()=>{
 const row=methods('DeviceGlassCircle',['dragTouch'],{TouchType:{Down:0}});row.dragEnabled=false;
 row.dragTouch({type:0,stopPropagation(){assert.fail('must not consume a list scroll');}});
});
test('spatial connections are drawn from the local hub with rounded, theme-aware strokes',()=>{
 const row=methods('DeviceDiscoveryContent',['nodes','pageCapacity','connectionDevices','layout','drawLines'],{DeviceSpatialLayout});let paths=[],current;
 const ctx={width:306,height:400,clearRect(){},beginPath(){current=[];paths.push(current);},moveTo(x,y){current.push([x,y]);},
  lineTo(x,y){current.push([x,y]);},quadraticCurveTo(a,b,x,y){current.push([x,y]);},stroke(){}};
 Object.assign(row,{spatialPage:0,canvasReady:true,lineContext:ctx,diagramWidth:306,darkMode:false,networkAvailable:true,
  devices:Array.from({length:4},()=>({name:'',debugDetected:true})),localName:()=> 'HUAWEI Pura 70 Pro',selected:()=>false,colors:()=>({accent:'#2563EB',textSecondary:'#667085'})});
 for(const width of [236,306,500]){
  paths=[];row.diagramWidth=width;ctx.width=width;row.drawLines();const layout=row.layout();
  assert.equal(paths.length,4);
  paths.forEach((points,index)=>{
   const start=points[0],end=points.at(-1);
   if(index<2)assert(Math.abs(Math.hypot(start[0]-layout.centerX(),start[1]-layout.centerY())-40)<1e-8);
   else assert(start[1]>layout.localBottom(),'lower links leave below local model and port');
   assert(Math.abs(Math.hypot(end[0]-layout.x(index,4)-layout.nameWidth/2,end[1]-layout.y(index)-32)-36)<1e-8);
  });
 }
 assert.equal(ctx.lineCap,'round');assert.equal(ctx.lineJoin,'round');assert.equal(ctx.globalAlpha,1);assert.equal(ctx.lineWidth,1);
 row.selected=()=>true;row.drawLines();assert.equal(ctx.strokeStyle,'#2563EB');assert.equal(ctx.lineWidth,1.4);
});
test('the narrow strip stays inside either edge and the open panel stays in safe areas',()=>{
 const row=methods('DeviceTargetOrb',['top','orbBottom','orbWidth','orbHeight','x','y','panelWidth','panelLimit','panelHeight','surfaceX','surfaceY'],{
  StoreLayout:{contentInset:width=>Math.max(width<360?16:24,(width-720)/2)}
 });
 for(const [width,height] of [[320,480],[420,948],[1280,720]])for(const right of [true,false])for(const ratio of [0,.64,1]){
  Object.assign(row,{windowWidth:width,windowHeight:height,topInset:32,bottomInset:24,right,yRatio:ratio,dragging:false,docked:true,requestedHeight:360,expanded:false});
  const x=row.x();assert.equal(x,right?width-7:3);
  assert.equal(row.orbWidth(),4);assert.equal(row.orbHeight(),32);
  assert(x>=3&&x+row.orbWidth()<=width-3);
  assert(row.y()>=72);assert(row.y()+52<=height-24);
  row.expanded=true;assert(row.surfaceX()>=12);assert(row.surfaceX()+row.panelWidth()<=width-12);
  assert(row.surfaceY()>=40);assert(row.surfaceY()+row.panelHeight()<=height-24-12);
 }
});
test('rapid open-close-open only schedules reveal, never inactivity docking',()=>{
 let next=0;const pending=new Map(),animations=[];
 const row=methods('DeviceTargetOrb',['clearReveal','onOpenedChanged','aboutToDisappear'],{
  setTimeout:(fn,ms)=>{pending.set(++next,{fn,ms});return next;},clearTimeout:id=>pending.delete(id),
  curves:{springMotion:()=>({})},Curve:{EaseOut:'ease'},MultiDeviceTargets:{unsubscribe(){}},DeviceOrbGestureGuard:{release(){}}
 });
 Object.assign(row,{revealTimer:-1,dockTimer:-1,dockRevision:0,alive:true,opened:true,foreground:true,dragging:false,docked:false,contentShown:false,shown:()=>true,
  morph:()=>{row.moving=false;},cancelMotion:()=>{},
  getUIContext:()=>({animateTo:(options,fn)=>{animations.push(options);fn();}})});
 row.onOpenedChanged();assert.equal(row.expanded,true);assert.deepEqual([...pending.values()].map(x=>x.ms),[90]);
 row.opened=false;row.onOpenedChanged();assert.equal(row.expanded,false);assert.equal(row.docked,false);assert.equal(row.contentShown,false);assert.deepEqual([...pending.values()].map(x=>x.ms),[]);
 row.opened=true;row.onOpenedChanged();assert.deepEqual([...pending.values()].map(x=>x.ms),[90]);const reveal=[...pending.values()][0].fn;pending.clear();reveal();assert.equal(row.contentShown,true);
 row.onOpenedChanged();assert.equal(pending.size,1);row.aboutToDisappear();assert.equal(pending.size,0);assert.equal(row.alive,false);
});
test('global overlay updates outer hit behavior in place and releases its content exactly once',()=>{
 const {loadEts}=require('./load_ets.cjs'),added=[],removed=[],disposed=[],orders=[],updates=[];
 const {DeviceOrbHost}=loadEts('components/DeviceOrbHost',{
  '@kit.ArkUI':{ComponentContent:class{constructor(ui,builder,options){this.options=options;}update(options){updates.push(options.modal);}dispose(){disposed.push(this);}}},
  '@ohos.promptAction':{LevelOrder:{clamp:n=>{orders.push(n);return {order:n};}}},
  './DeviceTargetOrb':{DeviceOrbOptions:class{constructor(){this.modal=false;}},deviceOrbBuilder(){}},
 },{AppStorage:{setOrCreate(){}},wrapBuilder:fn=>fn});
 const ui={runScopedTask:fn=>fn(),getOverlayManager:()=>({addComponentContentWithOrder:(...args)=>added.push(args),removeComponentContent:x=>removed.push(x)})};
 DeviceOrbHost.install(ui,{});DeviceOrbHost.install(ui,{});assert.equal(added.length,1);assert.deepEqual(orders,[100000]);
 const opts=added[0][0].options;opts.modalChanged(true);opts.modalChanged(true);opts.modalChanged(false);assert.deepEqual(updates,[true,false]);assert.equal(added.length,1);
 DeviceOrbHost.dispose();DeviceOrbHost.dispose();assert.equal(removed[0],added[0][0]);assert.equal(disposed.length,1);
});
test('device position writes stay ordered and a failed write does not block the next drag',async()=>{
 const {loadEts}=require('./load_ets.cjs'),values=new Map(),saved=[];let fail=false;
 const {DeviceOrbPreferences}=loadEts('data/DeviceOrbPreferences',{'@kit.ArkData':{preferences:{getPreferences:async()=>({
  put:async(k,v)=>{if(fail){fail=false;throw Error('busy');}values.set(k,v);},
  get:async(k,v)=>values.get(k)??v,flush:async()=>saved.push(Object.fromEntries(values))
 })}}});
 await Promise.all([DeviceOrbPreferences.save({},false,.2),DeviceOrbPreferences.save({},true,.8)]);
 assert.deepEqual(saved,[{right:false,ratio:.2},{right:true,ratio:.8}]);
 fail=true;await assert.rejects(DeviceOrbPreferences.save({},false,.3));await DeviceOrbPreferences.save({},false,5);
 const result=await DeviceOrbPreferences.load({});assert.equal(result.right,false);assert.equal(result.ratio,1);
});


function docking(){
 let next=0;const timers=new Map();
 const row=methods('DeviceTargetOrb',['dock','handleScroll','onForegroundChanged','orbWidth','orbHeight','restX','x','endDrag','y','top','orbBottom'],{
  setTimeout:(fn,ms)=>{timers.set(++next,{fn,ms});return next;},clearTimeout:id=>timers.delete(id),curves:{springMotion:()=>({})},uiObserver:{ScrollEventType:{SCROLL_START:0,SCROLL_STOP:1}},DeviceOrbGestureGuard:{release(){}}
 });
 Object.assign(row,{dockTimer:-1,dockRevision:0,alive:true,opened:false,foreground:true,dragging:false,docked:false,shown:()=>true,
  morph:()=>{row.moving=false;},cancelMotion:()=>{row.moving=false;},targetFrame:()=>row.paint,
  collapseForScroll:()=>{row.opened=false;},
  right:true,restingX:100,windowWidth:420,windowHeight:900,topInset:32,bottomInset:24,yRatio:.6,getUIContext:()=>({animateTo:(_options,fn)=>fn()})});
 return {row,timers};
}
test('a resting circle does not schedule an inactivity timer',()=>{
 const {row,timers}=docking();row.foreground=true;row.onForegroundChanged();
 assert.equal(row.docked,false);assert.equal(timers.size,0);
});
test('page scroll folds a resting circle immediately but neither panel scrolling nor dragging folds it',()=>{
 const {row,timers}=docking();row.handleScroll({scrollEvent:1});assert.equal(row.docked,false);assert.equal(timers.size,0);
 row.handleScroll({scrollEvent:0});assert.equal(row.docked,true);assert.equal(timers.size,0);
 row.docked=false;row.handleScroll({scrollEvent:0,id:'device-orb-scroll'});assert.equal(row.docked,false,'late picker scroll events must not fold the newly closed circle');
 row.docked=false;row.opened=true;row.handleScroll({scrollEvent:0});assert.equal(row.docked,false);
 row.opened=false;row.dragging=true;row.handleScroll({scrollEvent:0});assert.equal(row.docked,false);
});
test('releasing a dragged ball leaves the full circle near the drop point instead of immediately docking',()=>{
 const {row,timers}=docking();row.dragging=true;row.freeX=180;row.endDrag();
 assert.equal(row.dragging,false);assert.equal(row.docked,false);assert.equal(row.orbWidth(),52);assert.equal(row.orbHeight(),52);
 assert.equal(row.x()+26,206);assert.equal(timers.size,0);
});
test('background cancels motion without creating an inactivity timer on return',()=>{
 const {row,timers}=docking();row.foreground=false;row.onForegroundChanged();assert.equal(timers.size,0);
 row.foreground=true;row.onForegroundChanged();assert.equal(timers.size,0);assert.equal(row.docked,false);
});

test('handle, full circle and fitting panel keep the same vertical center',()=>{
 const row=methods('DeviceTargetOrb',['top','orbBottom','orbHeight','y','panelWidth','panelLimit','panelHeight','surfaceY'],{
  StoreLayout:{contentInset:width=>Math.max(width<360?16:24,(width-720)/2)}
 });
 for(const [width,height] of [[360,800],[1280,900]])for(const ratio of [.3,.5,.6]){
  Object.assign(row,{windowWidth:width,windowHeight:height,topInset:32,bottomInset:24,yRatio:ratio,dragging:false,docked:true,expanded:false,requestedHeight:360});
  const center=row.surfaceY()+row.orbHeight()/2;
  row.docked=false;assert.equal(row.surfaceY()+row.orbHeight()/2,center);
  row.expanded=true;assert.equal(row.surfaceY()+row.panelHeight()/2,center);
 }
});

test('all morph samples keep their shared center and valid radius, including spring overshoot',()=>{
 const {loadEts}=require('./load_ets.cjs');const {DeviceOrbFrame:Frame}=loadEts('components/DeviceOrbFrame');
 const states=[new Frame(12,282,304,236,28,0),new Frame(138,374,52,52,26,1),new Frame(138,374,52,52,26,1,1)];
 for(let stage=0;stage<2;stage++)for(const progress of [-.02,0,.2,.5,.9,1,1.02]){
  const frame=Frame.between(states[stage],states[stage+1],progress);
  assert.equal(frame.y+frame.height/2,400);assert.equal(frame.x+frame.width/2,164);
  assert(frame.radius>=2&&frame.radius<=Math.min(frame.width,frame.height)/2);assert(frame.iconOpacity>=0&&frame.iconOpacity<=1);
  assert(frame.edgeProgress>=0&&frame.edgeProgress<=1);
 }
});

test('native morphs commit one goal per transition and ignore stale completion callbacks',()=>{
 const {DeviceOrbFrame:Frame}=require('./load_ets.cjs').loadEts('components/DeviceOrbFrame');
 const animations=[];let docked=0,writes=0,paint=new Frame(138,374,52,52,26,1);
 const row=methods('DeviceTargetOrb',['cancelMotion','morph','followDrag'],{curves:{interpolatingSpring:(...args)=>args}});
 let target=new Frame(12,282,304,236,28,0);
 Object.assign(row,{motionGeneration:0,alive:true,dragging:false,opened:true,expanded:true,shown:()=>true,foreground:true,
  targetFrame:()=>target,dock:()=>{assert.equal(row.paint.width,52);docked++;},getUIContext:()=>({animateTo:(options,fn)=>{
   assert.equal(options.duration,460);assert.deepEqual(Array.from(options.curve),[0,1,300,28]);animations.push(options);fn();
  }})});
 Object.defineProperty(row,'paint',{get:()=>paint,set:value=>{paint=value;writes++;}});
 row.morph();assert.equal(writes,1);assert.equal(row.paint,target);assert.equal(row.moving,true);
 const opening=animations[0];
 target=new Frame(138,374,52,52,26,1);row.opened=false;row.expanded=false;row.morph();
 assert.equal(writes,2);assert.equal(row.paint,target);
 opening.onFinish();assert.equal(row.moving,true,'stale open completion cannot finish the closing animation');
 row.pendingDock=true;animations[1].onFinish();assert.equal(docked,1);assert.equal(row.pendingDock,false);
 assert.equal(writes,2,'there are no UI-side per-frame or finish-time geometry rewrites');
 row.morph();row.alive=false;animations[2].onFinish();assert.equal(row.moving,true);
 const source=fs.readFileSync(path.join(root,'DeviceTargetOrb.ets'),'utf8');
 assert(!source.includes('createAnimator('));assert(!source.includes('motion.onFrame'));
});

test('a scroll during panel collapse waits for the circle before docking',()=>{
 const {row,timers}=docking();row.moving=true;row.dock();assert.equal(row.pendingDock,true);assert.equal(row.docked,false);assert.equal(timers.size,0);
});

test('the first outside scroll closes the panel; only a subsequent page scroll requests docking',()=>{
 let closes=0;
 const row=methods('DeviceTargetOrb',['handleScroll','collapseForScroll','dock'],{
  uiObserver:{ScrollEventType:{SCROLL_START:0,SCROLL_STOP:1}}
 });
 Object.assign(row,{alive:true,foreground:true,opened:true,dragging:false,docked:false,moving:false,pendingDock:false,
  shown:()=>true,close:()=>{closes++;row.opened=false;row.moving=true;}});
 row.handleScroll({scrollEvent:0,id:'device-orb-scroll'});assert.equal(closes,0,'device list stays scrollable');
 row.handleScroll({scrollEvent:0,id:'device-orb-ip-list'});row.handleScroll({scrollEvent:0,id:'device-orb-pages'});assert.equal(closes,0,'the IP list and horizontal pager must not collapse the overlay');
 row.handleScroll({scrollEvent:1,id:'catalog'});assert.equal(closes,0);
 row.handleScroll({scrollEvent:0,id:'catalog'});assert.equal(closes,1);assert.equal(row.docked,false);assert.equal(row.pendingDock,false);
 row.handleScroll({scrollEvent:0,id:'catalog'});assert.equal(row.pendingDock,true);assert.equal(closes,1);
 assert.equal(row.docked,false,'a rapid second swipe waits for the circle morph to finish');
});

test('background gestures cannot collapse an inactive, unavailable or dragged device panel',()=>{
 let closes=0;const row=methods('DeviceTargetOrb',['collapseForScroll']);
 Object.assign(row,{alive:true,foreground:true,opened:true,dragging:false,shown:()=>true,close:()=>closes++});
 row.dragging=true;row.collapseForScroll();row.dragging=false;row.foreground=false;row.collapseForScroll();
 row.foreground=true;row.shown=()=>false;row.collapseForScroll();assert.equal(closes,0);
 row.shown=()=>true;row.collapseForScroll();assert.equal(closes,1);
});

test('a single decorative material modifier survives every geometry sample until appearance changes',()=>{
 const created=[];
 const row=methods('DeviceTargetOrb',['surfaceMaterial'],{DeviceOrbMaterial:class{constructor(...args){created.push(args);}}});
 Object.assign(row,{materialKey:'',materialMode:'adaptive',dark:false,expanded:false,panelMaterial:false,docked:false,dragging:false});
 const initial=row.surfaceMaterial();
 for(const width of [52,96,194,304,188,52]){row.paint={width};assert.equal(row.surfaceMaterial(),initial);}
 assert.equal(created.length,1);row.expanded=true;row.panelMaterial=true;const panel=row.surfaceMaterial();assert.equal(panel,initial);
 row.materialMode='strong';assert.notEqual(row.surfaceMaterial(),panel);assert.equal(created.length,2);
 row.expanded=false;row.panelMaterial=false;row.docked=true;const handle=row.surfaceMaterial();assert.deepEqual(created.at(-1),['strong',false]);
 row.dragging=true;assert.equal(row.surfaceMaterial(),handle,'docking only fades the shared material; it never swaps in a blue handle');
});
test('a closing native morph keeps one material until the matching completion',()=>{
 const {DeviceOrbFrame:Frame}=require('./load_ets.cjs').loadEts('components/DeviceOrbFrame');
 const animations=[],styles=[];
 const row=methods('DeviceTargetOrb',['clearReveal','onOpenedChanged','cancelMotion','morph','followDrag','surfaceMaterial'],{
  curves:{interpolatingSpring:()=>({})},DeviceOrbMaterial:class{constructor(...args){styles.push(args);}},clearTimeout(){},Curve:{EaseOut:'ease'}
 });
 const circle=new Frame(12,400,52,52,26,1);
 Object.assign(row,{paint:new Frame(12,246,350,300,28,0),expanded:true,panelMaterial:true,opened:false,alive:true,foreground:true,
  materialMode:'adaptive',dark:false,dragging:false,docked:false,materialKey:'',motionGeneration:0,revealTimer:-1,
  shown:()=>true,targetFrame:()=>circle,getUIContext:()=>({animateTo:(options,fn)=>{animations.push(options);fn();}})});
 const panel=row.surfaceMaterial();row.onOpenedChanged();assert.equal(row.expanded,false);assert.equal(row.panelMaterial,true);
 assert.equal(row.paint,circle);assert.equal(row.surfaceMaterial(),panel);assert.equal(styles.length,1);
 animations[0].onFinish();assert.equal(row.panelMaterial,false);assert.equal(row.surfaceMaterial(),panel);assert.equal(styles.length,1);
});

test('only a pointer starting in the docked handle rectangle acquires the side-return guard',()=>{
 let held=false;const row=methods('DeviceTargetOrb',['rootTouch','modalHitMode'],{TouchType:{Down:0},HitTestMode:{Transparent:2,Default:0},
  DeviceOrbGestureGuard:{begin:()=>{held=true;},release:()=>{held=false;}}});
 Object.assign(row,{hitLeft:316,hitTop:384,hitWidth:44,hitHeight:64,docked:true,opened:false,shown:()=>true});
 const send=(x,y,type=0)=>row.rootTouch({type,touches:[{screenX:x,screenY:y}],changedTouches:[]});
 assert.equal(send(350,416),2);assert.equal(held,true);send(200,416,1);assert.equal(held,true,'moving out of the region must not lose the current drag');
 send(350,200);assert.equal(held,false);row.hitLeft=0;send(10,416);assert.equal(held,true);
 row.docked=false;send(10,416);assert.equal(held,false);
});

test('expanded panels block page hits and closing releases them independently of animation completion',()=>{
 const row=methods('DeviceTargetOrb',['modalHitMode'],{HitTestMode:{Transparent:2,Default:0}});
 Object.assign(row,{shown:()=>true,opened:true,moving:false,panelMaterial:true});assert.equal(row.modalHitMode(),0);
 row.opened=false;row.moving=true;assert.equal(row.modalHitMode(),2);
 row.moving=false;row.panelMaterial=false;assert.equal(row.modalHitMode(),2);
 row.opened=true;row.shown=()=>false;assert.equal(row.modalHitMode(),2);
 const s=fs.readFileSync(path.join(root,'DeviceTargetOrb.ets'),'utf8');
 assert(s.slice(s.indexOf('@Builder export function deviceOrbBuilder')).includes('options.modal?HitTestMode.Default:HitTestMode.Transparent'),'the outer common hit node must switch with the inner root');
});
