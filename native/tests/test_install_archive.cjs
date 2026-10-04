const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {execFileSync}=require('node:child_process');
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'qingqi-codecs-'));
const build=path.join(os.tmpdir(),'qingqi-archive-host-tests');
const bundled='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build-tools/cmake/bin/cmake';
const cmake=process.env.QINGQI_CMAKE||(fs.existsSync(bundled)?bundled:'cmake');
const cli=path.join(build,'install_archive_cli');
before(()=>{
  execFileSync(cmake,['-S',path.join(__dirname,'archive'),'-B',build,'-DCMAKE_BUILD_TYPE=Release'],{stdio:'pipe'});
  execFileSync(cmake,['--build',build,'--target','install_archive_cli','-j','4'],{stdio:'pipe'});
  execFileSync('python3',['-c',String.raw`
import io,os,sys,zipfile,tarfile,gzip,bz2,lzma,json,struct,zlib
p=sys.argv[1]
b=io.BytesIO()
with zipfile.ZipFile(b,'w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('module.json',json.dumps({'app':{'bundleName':'com.example.test','versionCode':1},'module':{'name':'entry'}}))
data=b.getvalue()
open(p+'/main.hap','wb').write(data)
for ext,compress in [('gz',gzip.compress),('bz2',bz2.compress),('xz',lzma.compress),('lzma',lambda b:lzma.compress(b,format=lzma.FORMAT_ALONE))]:
 open(p+'/main.hap.'+ext,'wb').write(compress(data))
for ext,mode in [('tar','w'),('tgz','w:gz'),('tbz2','w:bz2'),('txz','w:xz')]:
 with tarfile.open(p+'/packages.'+ext,mode) as t:
  e=tarfile.TarInfo('./dir/main.hap');e.size=len(data);t.addfile(e,io.BytesIO(data))
  e=tarfile.TarInfo('readme.txt');e.size=4;t.addfile(e,io.BytesIO(b'info'))
def zipfileout(name,entries):
 with zipfile.ZipFile(p+'/'+name,'w',zipfile.ZIP_DEFLATED) as z:
  for n,d in entries:z.writestr(n,d)
zipfileout('packages.zip',[('dir/main.hap',data),('readme.txt',b'info')])
zipfileout('unsafe.zip',[('good.hap',data),('../escape.hap',data)])
zipfileout('duplicate.zip',[('good.hap',data),('./good.hap',data)])
zipfileout('many.zip',[(str(i)+'.hap',data) for i in range(33)])
zipfileout('empty.zip',[('readme.txt',b'info')])
with tarfile.open(p+'/link.tar','w') as t:
 e=tarfile.TarInfo('link.hap');e.type=tarfile.SYMTYPE;e.linkname='/tmp/target.hap';t.addfile(e)
# Stored RAR4 fixture, with real per-header and file CRCs (no external rar tool).
def header(kind,flags,body):
 block=struct.pack('<BHH',kind,flags,len(body)+7)+body
 return struct.pack('<H',zlib.crc32(block)&65535)+block
name=b'main.hap'
body=struct.pack('<IIBIIBBHI',len(data),len(data),3,zlib.crc32(data),0,20,0x30,len(name),0o100644)+name
open(p+'/packages.rar','wb').write(b'Rar!\x1a\x07\x00'+header(0x73,0,b'\0'*6)+header(0x74,0x8000,body)+data+header(0x7b,0,b''))
`,dir],{stdio:'pipe'});
  execFileSync(cli,['7z',path.join(dir,'packages.7z'),path.join(dir,'main.hap'),'dir/main.hap']);
});
after(()=>fs.rmSync(dir,{recursive:true,force:true}));
function extract(file,suffix='out'){
 const output=execFileSync(cli,['extract',path.join(dir,file),path.join(dir,suffix),file],{encoding:'utf8',stdio:['ignore','pipe','pipe']});
 return output.trim().split('\n').map(line=>{const[name,p,size]=line.split('\t');return {name,path:p,size:Number(size)};});
}
for(const file of ['packages.zip','packages.7z','packages.rar','packages.tar','packages.tgz','packages.tbz2','packages.txz','main.hap.gz','main.hap.bz2','main.hap.xz','main.hap.lzma'])
 test('real '+file+' extracts identical HAP bytes',()=>{
  const [entry]=extract(file,file.replace(/[^a-z0-9]/g,'-'));
  assert.equal(entry.size,fs.statSync(path.join(dir,'main.hap')).size);
  assert.deepEqual(fs.readFileSync(entry.path),fs.readFileSync(path.join(dir,'main.hap')));
 });
for(const file of ['unsafe.zip','duplicate.zip','many.zip','empty.zip','link.tar'])
 test(file+' rejects and removes partial outputs',()=>{
  const prefix='fail-'+file;
  assert.throws(()=>extract(file,prefix));
  assert(!fs.readdirSync(dir).some(name=>name.startsWith(prefix+'-')));
  assert(!fs.existsSync(path.join(dir,'escape.hap')));
 });
test('an existing output is retained and never overwritten',()=>{
 const output=path.join(dir,'existing-0.hap');fs.writeFileSync(output,'keep');
 assert.throws(()=>extract('packages.zip','existing'));assert.equal(fs.readFileSync(output,'utf8'),'keep');
});
