const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-editor-'));
const cli = path.join(dir, 'reader');
before(() => execFileSync('c++', ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', path.join(root,'entry/src/main/cpp/hap_core'), path.join(root,'entry/src/main/cpp/hap_core/zip_reader.cpp'), path.join(root,'entry/src/main/cpp/hap_core/signing_block.cpp'), path.join(root,'tests/hap_inspect_cli.cpp'), '-lz','-o',cli]));
after(() => fs.rmSync(dir,{recursive:true,force:true}));
function load(file,mocks={},globals={}) {
  const box={exports:{},require:n=>mocks[n]||{},Uint8Array,ArrayBuffer,DataView,Map,Set,Date,console,...globals};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,'entry/src/main/ets',file+'.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,box);return box.exports;
}
const util={TextEncoder:class{encodeInto(s){return new TextEncoder().encode(s);}},TextDecoder:{create:(_,options)=>({decodeToString:b=>new TextDecoder('utf-8',options).decode(b)})}};
const bundleRefs=load('jobs/BundleReferences');
const resource=load('jobs/ResourceIndex',{'@kit.ArkTS':{util},'./BundleReferences':bundleRefs});
function indexV2(values,configs=1) {
  const header=Buffer.alloc(152);header.write('RestoolV2 6.1.0.003');header.writeUInt32LE(1,132);header.write('KEYS',140);
  const ids=Buffer.alloc(16+12+values.length*13);ids.write('IDSS');ids.writeUInt32LE(1,8);ids.writeUInt32LE(values.length,24);
  let at=header.length+ids.length;const records=[], strings=[];
  values.forEach(([id,text],n)=>{
    const record=Buffer.alloc(12+configs*8);record.writeUInt32LE(id);record.writeUInt32LE(configs,8);
    ids.writeUInt32LE(id,28+n*13);ids.writeUInt32LE(at,32+n*13);ids.writeUInt32LE(1,36+n*13);ids[40+n*13]=65+n;
    records.push(record);at+=record.length;
  });
  values.forEach(([id,text],n)=>{for(let c=0;c<configs;c++){const value=Buffer.from(text+'\0'), chunk=Buffer.alloc(2+value.length);chunk.writeUInt16LE(value.length);value.copy(chunk,2);records[n].writeUInt32LE(at,16+c*8);strings.push(chunk);at+=chunk.length;}});
  const out=Buffer.concat([header,ids,...records,...strings]);out.writeUInt32LE(out.length,128);out.writeUInt32LE(header.length+ids.length,136);return out;
}
function indexCompact(values) {
  const h=Buffer.alloc(156);h.write('Restool 6.0.0.002');h.writeUInt32LE(1,132);h.write('KEYS',136);h.writeUInt32LE(148,140);h.write('IDSS',148);h.writeUInt32LE(values.length,152);
  const table=Buffer.alloc(values.length*8);let at=h.length+table.length;
  const records=values.map(([id,text],n)=>{const value=Buffer.from(text+'\0'),name=Buffer.from('name'+n+'\0'),r=Buffer.alloc(16+value.length+name.length);r.writeUInt32LE(r.length-4);r.writeUInt32LE(id,8);r.writeUInt16LE(value.length,12);value.copy(r,14);r.writeUInt16LE(name.length,14+value.length);name.copy(r,16+value.length);table.writeUInt32LE(id,n*8);table.writeUInt32LE(at,n*8+4);at+=r.length;return r;});
  const out=Buffer.concat([h,table,...records]);out.writeUInt32LE(out.length,128);return out;
}
for(const [kind,make] of [['V2',indexV2],['compact',indexCompact]])test(kind+' edits preserve unrelated values and source bytes',()=>{
  const bytes=make([[16777216,'原名称'],[16777217,'entry/resources/base/media/icon.png']]);const original=Buffer.from(bytes);
  const index=new resource.ResourceIndex(bytes),edited=index.replace(new Map([[16777216,'新的中文名'],[16777217,'entry/resources/base/media/new.png']]));
  assert.deepEqual(bytes,original);const result=new resource.ResourceIndex(edited);assert.equal(result.value(16777216),'新的中文名');assert.equal(result.value(16777217),'entry/resources/base/media/new.png');
  assert.throws(()=>index.replace(new Map([[999,'missing']])));assert.throws(()=>index.replace(new Map([[16777216,'x\0y']])));
});
test('all language/configuration pointers are patched in V2',()=>{
  const bytes=indexV2([[16777216,'原名称']],3),edited=new resource.ResourceIndex(bytes).replace(new Map([[16777216,'批量中文']]));
  const view=new DataView(edited.buffer),record=bytes.readUInt32LE(184);
  for(let c=0;c<3;c++){const offset=view.getUint32(record+16+c*8,true),length=view.getUint16(offset,true);assert.equal(new TextDecoder().decode(edited.slice(offset+2,offset+2+length)),'批量中文');}
});
test('malformed resource lengths fail without changing input',()=>{
  const bad=indexV2([[16777216,'x']]);bad.writeUInt32LE(0xffffff,184);const old=Buffer.from(bad);
  assert.throws(()=>new resource.ResourceIndex(bad).replace(new Map([[16777216,'新']])));assert.deepEqual(bad,old);
});
const native={listProfileEntries:p=>execFileSync(cli,[p,'profiles'],{encoding:'utf8'}).trim().split('\n').filter(Boolean).map(x=>{const [size,name]=x.split('\t');return {size:Number(size),name};}),readModuleJson:p=>execFileSync(cli,[p],{encoding:'utf8'}),readPackInfo:p=>execFileSync(cli,[p,'pack'],{encoding:'utf8'}),readArchiveFile:(p,n)=>new Uint8Array(execFileSync(cli,[p,'read',n])),readHapIcon:(p,n)=>new Uint8Array(execFileSync(cli,[p,'icon',n])),readInstallPermissions:()=> '[]',
  listPackageEntries:p=>execFileSync(cli,[p,'list'],{encoding:'utf8'}).trim().split('\n').filter(Boolean).map(x=>{const [size,name]=x.split('\t');return {size:Number(size),name};}),extractPackageEntry:async(p,n,o)=>execFileSync(cli,[p,'extract',n,o]),rewriteArchive:async(p,o,names,files,previous,next)=>execFileSync(cli,[p,previous?'rename':'rewrite',o,...(previous?[previous,next]:[]),...names.flatMap((n,i)=>[n,files[i]])])};
const presentation=load('jobs/PackagePresentation',{'libhap_core.so':native,'./ResourceIndex':resource,'@kit.ArkTS':{util}});
const inspector=load('jobs/PackageInspector',{'libhap_core.so':native,'./PackagePresentation':presentation});
const io={accessSync:fs.existsSync,statSync:p=>typeof p==='number'?fs.fstatSync(p):fs.statSync(p),unlinkSync:fs.unlinkSync,renameSync:fs.renameSync,listFileSync:fs.readdirSync,mkdirSync:p=>fs.mkdirSync(p,{recursive:true}),OpenMode:{READ_ONLY:1,WRITE_ONLY:2,CREATE:4,TRUNC:8},openSync:(p,flags)=>({fd:fs.openSync(p,flags&2?(flags&4?'w':'r+'):'r')}),closeSync:f=>fs.closeSync(f.fd),writeSync:(fd,b)=>fs.writeSync(fd,new Uint8Array(b)),copyFile:async(from,to)=>{const b=fs.readFileSync(from);typeof to==='number'?fs.writeFileSync(to,b):fs.writeFileSync(to,b);}};
const storage={StorageBudget:{require:async()=>{}}};
const archive=load('jobs/PackageArchive',{'libhap_core.so':native,'@kit.CoreFileKit':{fileIo:io},'./StorageBudget':storage,'./PackageInspector':inspector,'./PackagePresentation':presentation});
let saveTargets=[];
const editor=load('jobs/PackageEditor',{'libhap_core.so':native,'@kit.CoreFileKit':{fileIo:io,picker:{DocumentViewPicker:class{async save(options){assert.equal(options.newFileNames.length,saveTargets.length||options.newFileNames.length);return saveTargets;}}}},'@kit.ArkTS':{util},'./ResourceIndex':resource,'./BundleReferences':bundleRefs,'./StorageBudget':storage,'./PackageArchive':archive,'./PackageInspector':inspector});
function fixture(stem,extension) {
  const sub=path.join(dir,stem);fs.mkdirSync(sub);fs.writeFileSync(path.join(sub,'index'),indexV2([[16777216,'原名称'],[16777217,'entry/resources/base/media/icon.png']]));
  execFileSync('python3',['-c',`import zipfile,json,sys,io,pathlib
p=pathlib.Path(sys.argv[1]);b=io.BytesIO()
with zipfile.ZipFile(b,'w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('module.json',json.dumps({'app':{'bundleName':'com.example.editor','versionCode':20,'versionName':'1.0','label':'$string:app_name','labelId':16777216,'iconId':16777217},'module':{'name':'entry','type':'entry','mainElement':'EntryAbility','abilities':[{'name':'EntryAbility','labelId':16777216,'iconId':16777217}]}}))
 z.writestr('pack.info',json.dumps({'summary':{'app':{'bundleName':'com.example.editor','version':{'code':20,'name':'1.0'}}}}))
 z.writestr('resources.index',(p/'index').read_bytes());z.writestr('payload.bin',b'unchanged'*2000);z.writestr('libs/arm64-v8a/library.so',b'ELF'+b'x'*40000,compress_type=zipfile.ZIP_STORED)
(p/'original.hap').write_bytes(b.getvalue())
with zipfile.ZipFile(p/'original.app','w') as z:z.writestr('entry.hap',b.getvalue());z.writestr('pack.info','{}')
`,sub]);return path.join(sub,'original'+extension);
}
for(const ext of ['.hap','.app'])test(ext+' rename and icon edit roundtrip; identity, payload and original preserved',async()=>{
  const p=fixture(ext.substring(1),ext),row=new editor.EditablePackage();row.path=p;row.filename=path.basename(p);row.identity=await archive.PackageArchive.inspect(p);
  const original=crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');const icon=path.join(path.dirname(p),'new.png');fs.writeFileSync(icon,Buffer.from('PNG-icon'));
  const edited=await editor.PackageEditor.edit(row,'修改后的中文应用',icon);const info=await archive.PackageArchive.inspect(edited);assert.equal(info.bundleName,row.identity.bundleName);assert.equal(info.versionCode,20);assert.equal(info.displayName,'修改后的中文应用');assert.equal(original,crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'));
  const [module]=await archive.PackageArchive.modulePaths(edited);const idx=new resource.ResourceIndex(native.readArchiveFile(module,'resources.index'));assert.equal(idx.value(16777216),'修改后的中文应用');assert.equal(idx.value(16777217),'entry/resources/base/media/qingqi_edited_icon.png');assert.deepEqual(Buffer.from(await archive.PackageArchive.icon(edited)),Buffer.from('PNG-icon'));
  execFileSync('python3',['-c',`import zipfile,struct,sys
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None
 assert z.read('payload.bin')==b'unchanged'*2000
 i=z.getinfo('libs/arm64-v8a/library.so');f=open(sys.argv[1],'rb');f.seek(i.header_offset+26);n,e=struct.unpack('<HH',f.read(4));assert (i.header_offset+30+n+e)%16384==0
`,module]);
  saveTargets=[];assert.equal(await editor.PackageEditor.saveMany({},[row]),0);assert.equal(row.status,'');
  const out=path.join(path.dirname(p),'export'+ext);fs.writeFileSync(out,'');saveTargets=[out];assert.equal(await editor.PackageEditor.saveMany({},[row]),1);assert.deepEqual(fs.readFileSync(out),fs.readFileSync(edited));
  archive.PackageArchive.release(edited);archive.PackageArchive.release(p);assert(!fs.readdirSync(path.dirname(p)).some(n=>n.endsWith('.part')||n.includes('.edit-')));
});
test('ZIP rewrite rejects traversal and leaves no partial output',async()=>{
  const p=fixture('unsafe','.hap'),replace=path.join(path.dirname(p),'new'),output=p+'.out';fs.writeFileSync(replace,'{}');
  await assert.rejects(native.rewriteArchive(p,output,['../module.json'],[replace]));assert.equal(fs.existsSync(output),false);
});

test('a failed re-edit cannot export the previous output; the original stays intact',async()=>{
  const p=fixture('retry','.hap'),row=new editor.EditablePackage();row.path=p;row.filename='retry.hap';row.identity=await archive.PackageArchive.inspect(p);
  const original=fs.readFileSync(p),previous=await editor.PackageEditor.edit(row,'第一次修改','');assert.equal(fs.existsSync(previous),true);
  await assert.rejects(editor.PackageEditor.edit(row,'x'.repeat(65),''));
  assert.equal(row.editedPath,'');assert.equal(fs.existsSync(previous),false);assert.deepEqual(fs.readFileSync(p),original);
  await assert.rejects(editor.PackageEditor.saveMany({},[row]));archive.PackageArchive.release(p);
});

const inspection=load('data/InstalledInspection',{}).InstalledInspection;
test('inspection groups scalar fields and preserves all nested metadata',()=>{
  const data={name:'com.example.app',versionCode:10,enabled:true,signatureInfo:{fingerprint:'ABC'},modules:[{name:'entry',permissions:['one','two']}]};
  const sections=inspection.sections(data);assert.equal(sections[0].name,'基本信息');
  const fields=sections.flatMap(s=>s.fields);assert.equal(fields.length,7);
  assert.equal(fields.find(f=>f.key==='modules.0.permissions.1').value,'two');
  assert.equal(fields.find(f=>f.key==='enabled').value,'是');
});

test('inspection hides empty values and empty groups, while retaining zero and false',()=>{
  const sections=inspection.sections({empty:'',blank:'  \n ',missing:null,unknown:undefined,list:[],object:{},allEmpty:{name:'',values:[],child:{missing:null}},mixed:{empty:'',items:['',null,[],{},0,false,'有效值']},zero:0,disabled:false});
  const fields=sections.flatMap(section=>section.fields);
  assert.deepEqual(Array.from(fields,field=>field.key).sort(),['disabled','mixed.items.4','mixed.items.5','mixed.items.6','zero']);
  assert.equal(fields.find(field=>field.key==='zero').value,'0');
  assert.equal(fields.find(field=>field.key==='disabled').value,'否');
  assert.equal(sections.some(section=>section.name==='allEmpty'),false);
});

test('inspection search matches full paths and values without altering the complete metadata',()=>{
  const sections=inspection.sections({bundleName:'com.example.App',signatureInfo:{fingerprint:'ABC123'},empty:[]});
  assert.equal(inspection.filter(sections,'  '),sections);
  const byKey=inspection.filter(sections,'SIGNATUREINFO.FINGERPRINT');assert.equal(byKey.length,1);assert.equal(byKey[0].fields[0].value,'ABC123');
  assert.equal(inspection.filter(sections,'abc123')[0].fields[0].key,'signatureInfo.fingerprint');
  assert.equal(inspection.filter(sections,'应用包名')[0].fields[0].value,'com.example.App');
  assert.equal(inspection.filter(sections,'no-such-field').length,0);
  assert.equal(sections.flatMap(section=>section.fields).length,2);
});

test('device inspection supplements the official metadata instead of dropping signature fields',async()=>{
  const stored=new Map(),bundle='com.example.app';
  const data=load('data/InstalledInspection',{'@kit.AbilityKit':{bundleManager:{BundleFlag:{},getBundleInfoSync:()=>({name:bundle,versionCode:10,signatureInfo:{fingerprint:'ABC123'}})}},'@kit.ArkData':{preferences:{getPreferences:async()=>({get:async(k,v)=>stored.get(k)??v,put:async(k,v)=>stored.set(k,v),delete:async k=>stored.delete(k),flush:async()=>{}})}},'../jobs/HdcDeviceBridge':{HdcDeviceBridge:class{async connected(){return true;}async installedDetails(){return {name:bundle,versionCode:10,displayName:'实际名称',applicationInfo:{enabled:true}};}}}});
  const result=await data.InstalledInspection.read({},bundle);assert.equal(result.signatureInfo.fingerprint,'ABC123');assert.equal(result.displayName,'实际名称');assert.equal(result.applicationInfo.enabled,true);
  assert.equal(JSON.parse(stored.get(bundle)).signatureInfo.fingerprint,'ABC123');
});

test('IME search waits for committed Chinese, cancels earlier timers, and clears immediately',()=>{
  let next=0;const pending=new Map(),applied=[];
  const clock={setTimeout:(callback,delay)=>{assert.equal(delay,200);const id=++next;pending.set(id,callback);return id;},clearTimeout:id=>pending.delete(id)};
  const Search=load('data/InspectionSearch',{},clock).InspectionSearch,search=new Search(query=>applied.push(query));
  const tick=()=>{const tasks=[...pending.values()];pending.clear();tasks.forEach(task=>task());};
  search.change('version');search.change('签ming','ming');tick();assert.deepEqual(applied,[]);
  search.change('签名','');tick();assert.deepEqual(applied,['签名']);
  search.change('bundle');search.change('bundleName');tick();assert.deepEqual(applied,['签名','bundleName']);
  search.change('签名pin','pin');tick();assert.deepEqual(applied,['签名','bundleName']);
  search.change('签名配置','');search.change('');assert.deepEqual(applied,['签名','bundleName','']);tick();assert.equal(applied.length,3);
  search.change('关闭后不执行');search.close();tick();search.change('新输入');assert.equal(applied.length,3);
});

test('installed selection uses the device name instead of a linked catalog title',()=>{
  const registry={'../jobs/InstalledAppRegistry':{InstalledAppRegistry:{displayName:()=> '设备真实名称'}}};
  const names=load('data/AppDisplayName',registry);
  const data=load('data/InstalledInspection',{...registry,'./AppDisplayName':names});
  const row=data.InstalledInspection.selection({bundleName:'com.example.app',sourceUrl:'local',versionName:'1.2',versionCode:12,id:'local',moduleName:'entry',mainAbility:'Main',updatedAt:2},'旧商店名称',3);
  assert.equal(row.title,'设备真实名称');assert.equal(row.bundleName,'com.example.app');assert.equal(row.appId,3);
});

for(const ext of ['.hap','.app'])test(ext+' bundle rename updates manifests and pack metadata without touching compiled bytes',async()=>{
  const p=fixture('bundle-'+ext.substring(1),ext),row=new editor.EditablePackage();row.path=p;row.filename=path.basename(p);row.identity=await archive.PackageArchive.inspect(p);
  const original=fs.readFileSync(p),result=await editor.PackageEditor.edit(row,'独立应用','', 'com.example.renamed');
  const actual=await archive.PackageArchive.inspect(result);assert.equal(actual.bundleName,'com.example.renamed');assert.equal(actual.versionCode,20);assert.equal(actual.displayName,'独立应用');
  for(const module of await archive.PackageArchive.modulePaths(result)){
    assert.equal(JSON.parse(native.readModuleJson(module)).app.bundleName,'com.example.renamed');
    assert.equal(JSON.parse(native.readPackInfo(module)).summary.app.bundleName,'com.example.renamed');
    assert.deepEqual(Buffer.from(native.readArchiveFile(module,'payload.bin')),Buffer.from('unchanged'.repeat(2000)));
  }
  assert.deepEqual(fs.readFileSync(p),original);archive.PackageArchive.release(result);archive.PackageArchive.release(p);
});

test('multi-module APP bundle rename updates the outer pack and explicit self dependencies only',async()=>{
  const p=fixture('multi-bundle','.app');
  execFileSync('python3',['-c',`import zipfile,json,io,sys
p=sys.argv[1]
with zipfile.ZipFile(p) as outer: old=outer.read('entry.hap')
modules=[]
for name,kind in [('entry','entry'),('feature','feature')]:
 b=io.BytesIO()
 with zipfile.ZipFile(io.BytesIO(old)) as original,zipfile.ZipFile(b,'w') as z:
  for info in original.infolist():
   data=original.read(info.filename)
   if info.filename=='module.json':
    obj=json.loads(data);obj['module']['name']=name;obj['module']['type']=kind;obj['module']['dependencies']=[{'bundleName':'com.example.editor'},{'bundleName':'com.other.library'}];obj['module']['metadata']=[{'name':'compiledReference','value':'com.example.editor'}];data=json.dumps(obj).encode()
   z.writestr(info,data)
 modules.append((name+'.hap',b.getvalue()))
with zipfile.ZipFile(p,'w') as outer:
 for name,data in modules: outer.writestr(name,data)
 outer.writestr('pack.info',json.dumps({'summary':{'app':{'bundleName':'com.example.editor','version':{'name':'1.0','code':20}}},'packages':[{'bundleName':'com.example.editor'},{'bundleName':'com.other.library'}]}))
`,p]);
  const row=new editor.EditablePackage();row.path=p;row.filename='multi.app';row.identity=await archive.PackageArchive.inspect(p);
  const result=await editor.PackageEditor.edit(row,'新名称','','com.example.newbundle');
  const pack=JSON.parse(native.readPackInfo(result));assert.equal(pack.summary.app.bundleName,'com.example.newbundle');assert.equal(pack.summary.app.label,'新名称');assert.equal(pack.packages[0].bundleName,'com.example.newbundle');assert.equal(pack.packages[1].bundleName,'com.other.library');
  const modules=await archive.PackageArchive.modulePaths(result);assert.equal(modules.length,2);
  for(const path of modules){const manifest=JSON.parse(native.readModuleJson(path));assert.equal(manifest.app.bundleName,'com.example.newbundle');assert.equal(manifest.module.dependencies[0].bundleName,'com.example.newbundle');assert.equal(manifest.module.dependencies[1].bundleName,'com.other.library');assert.equal(manifest.module.metadata[0].value,'com.example.newbundle');}
  archive.PackageArchive.release(result);archive.PackageArchive.release(p);
});

test('invalid bundle names fail before creating an output',async()=>{
  const p=fixture('invalid-bundle','.hap'),row=new editor.EditablePackage();row.path=p;row.identity=await archive.PackageArchive.inspect(p);const original=fs.readFileSync(p);
  for(const bundle of ['中文.应用','com..test','com.1test','a.b','com.'+'x'.repeat(125),'../com.test'])await assert.rejects(editor.PackageEditor.edit(row,'原名称','',bundle),/包名应为/);
  assert.deepEqual(fs.readFileSync(p),original);assert.equal(row.editedPath,'');assert(!fs.readdirSync(path.dirname(p)).some(name=>name.includes('.edited.')||name.endsWith('.part')));
});

// Small dynamic ABC with both instruction-index and object-literal string IDs.
// Padding/code includes unrelated bytes whose offsets must remain unchanged.
function adler32(bytes) { let a=1,b=0;for(const value of bytes){a=(a+value)%65521;b=(b+a)%65521;}return ((b<<16)|a)>>>0; }
function abcFixture() {
  const b=Buffer.alloc(512);b.write('PANDA');b[12]=24;b.writeUInt32LE(b.length,16);
  b.writeUInt32LE(0xffffffff,44);b.writeUInt32LE(0xffffffff,48);b.writeUInt32LE(1,52);b.writeUInt32LE(60,56);
  b.writeUInt32LE(128,60);b.writeUInt32LE(b.length,64);b.writeUInt32LE(4,76);b.writeUInt32LE(100,80);
  for(const [i,id] of [128,200,300,350].entries())b.writeUInt32LE(id,100+i*4);
  b.writeUInt32LE(6,128);
  for(const [i,id] of [160,200,300].entries()){b[132+i*5]=5;b.writeUInt32LE(id,133+i*5);}
  for(const [offset,text] of [[160,'bundleName'],[200,'com.example.editor'],[300,'com.external.library'],[350,'@bundle:com.example.editor/entry/pages/Main']]){b[offset]=(text.length*2)|1;b.write(text,offset+1);}
  b.write('CODE-UNCHANGED',450);b.writeUInt32LE(adler32(b.subarray(12)),8);return b;
}
function withAbc(p,bytes) {
  const abc=p+'.fixture.abc';fs.writeFileSync(abc,bytes);
  execFileSync('python3',['-c',`import zipfile,io,sys,pathlib
p=pathlib.Path(sys.argv[1]);abc=pathlib.Path(sys.argv[2]).read_bytes()
def hap(data):
 out=io.BytesIO()
 with zipfile.ZipFile(io.BytesIO(data)) as old,zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
  for item in old.infolist():z.writestr(item,old.read(item.filename))
  z.writestr('ets/modules.abc',abc);z.writestr('ets/widgets.abc',abc)
 return out.getvalue()
if p.suffix=='.hap':p.write_bytes(hap(p.read_bytes()))
else:
 out=io.BytesIO()
 with zipfile.ZipFile(p) as old,zipfile.ZipFile(out,'w') as z:
  for item in old.infolist():z.writestr(item,hap(old.read(item.filename)) if item.filename.endswith('.hap') else old.read(item.filename))
 p.write_bytes(out.getvalue())
`,p,abc]);fs.unlinkSync(abc);
}
function abcString(bytes,id) {let value=0,shift=0,at=id;do{const c=bytes[at++];value|=(c&127)<<shift;shift+=7;if(!(c&128))break;}while(shift<35);const end=bytes.indexOf(0,at);assert.equal(end-at,value>>>1);return bytes.subarray(at,end).toString();}
for(const ext of ['.hap','.app'])test(ext+' bundle editing relocates Ark page, resource and widget references for longer and shorter names',async()=>{
  const p=fixture('abc-'+ext.slice(1),ext),source=abcFixture();withAbc(p,source);
  const original=fs.readFileSync(p),row=new editor.EditablePackage();row.path=p;row.identity=await archive.PackageArchive.inspect(p);
  for(const bundle of ['com.example.extendedname','org.new.app']){
    const edited=await editor.PackageEditor.edit(row,'新名称','',bundle);
    for(const module of await archive.PackageArchive.modulePaths(edited))for(const entry of ['ets/modules.abc','ets/widgets.abc']){
      const b=execFileSync(cli,[module,'read',entry]);assert.equal(b.readUInt32LE(16),b.length);assert.equal(b.readUInt32LE(8),adler32(b.subarray(12)));
      assert.equal(b.readUInt32LE(64),b.length);assert.equal(abcString(b,b.readUInt32LE(104)),bundle);
      assert.equal(b.readUInt32LE(138),b.readUInt32LE(104));assert.equal(abcString(b,b.readUInt32LE(112)),'@bundle:'+bundle+'/entry/pages/Main');
      assert.equal(abcString(b,b.readUInt32LE(143)),'com.external.library');assert.deepEqual(b.subarray(450,512),source.subarray(450,512));
      assert.deepEqual(b.subarray(12,16),source.subarray(12,16));assert.equal(b.readUInt32LE(100),128);
    }
  }
  assert.deepEqual(fs.readFileSync(p),original);archive.PackageArchive.release(row.editedPath);archive.PackageArchive.release(p);
});
for(const kind of ['checksum','version','unclassified-pointer','record-name'])test('unsafe ABC '+kind+' rejects bundle rename without a partial export; label-only editing remains available',async()=>{
  const p=fixture('abc-reject-'+kind,'.hap'),bytes=abcFixture();
  if(kind==='checksum')bytes[460]^=1;
  else{
    if(kind==='version')bytes[12]=255;
    if(kind==='unclassified-pointer')bytes.writeUInt32LE(200,420);
    if(kind==='record-name'){bytes.writeUInt32LE(1,28);bytes.writeUInt32LE(116,32);bytes.writeUInt32LE(200,116);}
    bytes.writeUInt32LE(adler32(bytes.subarray(12)),8);
  }
  withAbc(p,bytes);const original=fs.readFileSync(p),row=new editor.EditablePackage();row.path=p;row.identity=await archive.PackageArchive.inspect(p);
  await assert.rejects(editor.PackageEditor.edit(row,'新名称','','com.example.renamed'),/Ark|字节码/);
  assert.equal(row.editedPath,'');assert.deepEqual(fs.readFileSync(p),original);assert(!fs.readdirSync(path.dirname(p)).some(name=>name.endsWith('.part')||name.endsWith('.edited.hap')));
  const result=await editor.PackageEditor.edit(row,'只改名称','');assert.equal((await archive.PackageArchive.inspect(result)).displayName,'只改名称');
  assert.deepEqual(Buffer.from(native.readArchiveFile(result,'ets/modules.abc')),bytes);archive.PackageArchive.release(result);archive.PackageArchive.release(p);
});

for(const extension of ['.hap','.app'])test('bundle rename synchronizes route profiles in '+extension+' without changing foreign bundles',async()=>{
  const p=fixture('profile-'+extension,extension);
  execFileSync('python3',['-c',`import zipfile,io,json,sys
p=sys.argv[1];ext=sys.argv[2]
def modify(data):
 out=io.BytesIO()
 with zipfile.ZipFile(io.BytesIO(data)) as src,zipfile.ZipFile(out,'w') as z:
  for info in src.infolist():z.writestr(info,src.read(info.filename))
  z.writestr('resources/base/profile/router.json',json.dumps({'routerMap':[{'bundleName':'com.example.editor'},{'bundleName':'com.thirdparty.service'}]}))
 return out.getvalue()
if ext=='.hap':data=modify(open(p,'rb').read());open(p,'wb').write(data)
else:
 out=io.BytesIO()
 with zipfile.ZipFile(p) as src,zipfile.ZipFile(out,'w') as z:
  for info in src.infolist():z.writestr(info,modify(src.read(info.filename)) if info.filename.endswith('.hap') else src.read(info.filename))
 open(p,'wb').write(out.getvalue())
`,p,extension]);
  const row=new editor.EditablePackage();row.path=p;row.identity=await archive.PackageArchive.inspect(p);
  const output=await editor.PackageEditor.edit(row,'新名称','','com.example.changed');
  for(const module of await archive.PackageArchive.modulePaths(output)){
    const profile=JSON.parse(new TextDecoder().decode(native.readArchiveFile(module,'resources/base/profile/router.json')));
    assert.equal(profile.routerMap[0].bundleName,'com.example.changed');assert.equal(profile.routerMap[1].bundleName,'com.thirdparty.service');
  }
  archive.PackageArchive.release(output);archive.PackageArchive.release(p);
});

for(const [kind,make] of [['V2',indexV2],['compact',indexCompact]])test(kind+' synchronizes self bundle resources while retaining foreign identities and labels',()=>{
  const bytes=make([[16777216,'com.example.editor'],[16777217,'com.thirdparty.editor'],[16777218,'@bundle:com.example.editor/entry/ets/pages/Index'],[16777219,'中文名称']]);
  const out=new resource.ResourceIndex(bytes).replace(new Map(),'com.example.editor','com.example.longername');
  const actual=new resource.ResourceIndex(out);
  assert.equal(actual.value(16777216),'com.example.longername');assert.equal(actual.value(16777217),'com.thirdparty.editor');
  assert.equal(actual.value(16777218),'@bundle:com.example.longername/entry/ets/pages/Index');assert.equal(actual.value(16777219),'中文名称');
  assert.equal(new resource.ResourceIndex(bytes).value(16777216),'com.example.editor');
});
test('bundle synchronization traverses arrays, metadata, actions and routing without replacing substrings',()=>{
  const data={bundleName:'com.example.editor',metadata:[{value:'com.example.editor'}],actions:['com.example.editor.ACTION','com.external.ACTION'],routes:['@bundle:com.example.editor/entry/ets/pages/Index'],text:'other com.example.editor text',foreign:'com.example.editorial'};
  bundleRefs.BundleReferences.object(data,'com.example.editor','com.example.clone');
  assert.equal(data.metadata[0].value,'com.example.clone');assert.equal(data.actions[0],'com.example.clone.ACTION');assert.equal(data.actions[1],'com.external.ACTION');
  assert.equal(data.routes[0],'@bundle:com.example.clone/entry/ets/pages/Index');assert.equal(data.text,'other com.example.editor text');assert.equal(data.foreign,'com.example.editorial');
});
