const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { loadEts } = require('./load_ets.cjs');
const root = path.join(__dirname, '..'), temp = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-analysis-native-'));
const cli = temp + '/hap-reader', fixtures = temp + '/fixtures';
const checkoutKey = crypto.createHash('sha256').update(fs.realpathSync(root + '/tests/archive')).digest('hex').slice(0,12);
const archiveBuild = path.join(os.tmpdir(), 'qingqi-download-analysis-host-tests-' + checkoutKey);
const importer = path.join(archiveBuild, 'install_archive_cli');
const bundledCmake = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build-tools/cmake/bin/cmake';
const cmake = process.env.QINGQI_CMAKE || (fs.existsSync(bundledCmake) ? bundledCmake : 'cmake');
const digest = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
before(() => {
  execFileSync('c++', ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', root + '/entry/src/main/cpp/hap_core',
    root + '/entry/src/main/cpp/hap_core/zip_reader.cpp', root + '/entry/src/main/cpp/hap_core/signing_block.cpp',
    root + '/tests/hap_inspect_cli.cpp', '-lz', '-o', cli], { stdio: 'pipe' });
  execFileSync(cmake, ['-S', root + '/tests/archive', '-B', archiveBuild, '-DCMAKE_BUILD_TYPE=Release'], { stdio: 'pipe' });
  execFileSync(cmake, ['--build', archiveBuild, '--target', 'install_archive_cli', '-j', '4'], { stdio: 'pipe' });
  fs.mkdirSync(fixtures);
  execFileSync('python3', ['-c', String.raw`
import io,json,zipfile,struct,gzip,tarfile,sys,os
p=sys.argv[1]
def hap(bundle='com.example.first',label='甲应用',module='entry',signed=False):
 b=io.BytesIO()
 with zipfile.ZipFile(b,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('module.json',json.dumps({'app':{'bundleName':bundle,'label':label,'versionCode':999,'versionName':'0.1.0','minAPIVersion':24,'targetAPIVersion':26},'module':{'name':module,'type':'entry' if module=='entry' else 'feature','mainElement':'MainAbility' if module=='entry' else '', 'deviceTypes':['phone','tablet'], 'requestPermissions':[{'name':'ohos.permission.INTERNET'},{'name':'ohos.permission.GET_BUNDLE_INFO'}], 'unimportant':{'large':'do not display'}}}))
  z.writestr('pack.info',json.dumps({'summary':{'app':{'bundleName':bundle,'version':{'code':20,'name':'1.2.0'},'apiVersion':{'compatible':24,'target':26}}}}))
 data=b.getvalue()
 if signed:
  eocd=data.rfind(b'PK\x05\x06'); central=struct.unpack_from('<I',data,eocd+16)[0]
  block=struct.pack('<III',0x20000000,1,12)+b'x'+struct.pack('<IQQQI',1,45,0x676973207061683c,0x3e6b636f6c62206e,3)
  data=bytearray(data[:central]+block+data[central:]);struct.pack_into('<I',data,eocd+len(block)+16,central+len(block));data=bytes(data)
 return data
def archive(name,entries):
 b=io.BytesIO()
 with zipfile.ZipFile(b,'w',zipfile.ZIP_DEFLATED) as z:
  for n,data in entries:z.writestr(n,data)
 data=b.getvalue();open(p+'/'+name,'wb').write(data);return data
first=hap();open(p+'/one.hap','wb').write(first);open(p+'/signed.hap','wb').write(hap(signed=True))
second=archive('two.app',[('entry.hap',hap('com.example.second','乙应用')),('feature.hap',hap('com.example.second','乙应用','feature'))])
mixed=archive('mixed.app',[('entry.hap',first),('other.hap',hap('com.example.other','不同身份','feature'))])
archive('multiple.zip',[('apps/one.hap',first),('apps/two.app',second),('bad.hap',b'not a HAP'),('readme.txt',b'ignore')])
archive('many-apps.zip',[(str(i)+'.app',second) for i in range(4)])
archive('unsafe.zip',[('good.hap',first),('../outside.hap',first)])
open(p+'/one.hap.gz','wb').write(gzip.compress(first))
with tarfile.open(p+'/packages.tgz','w:gz') as t:
 e=tarfile.TarInfo('./apps/one.hap');e.size=len(first);t.addfile(e,io.BytesIO(first))
`, fixtures], { stdio: 'pipe' });
});
after(() => fs.rmSync(temp, { recursive: true, force: true }));

function fixture(t, name) {
  const base = fs.mkdtempSync(path.join(temp, 'case-')), context = { filesDir: base + '/files', cacheDir: base + '/cache' };
  const f = { base, context, opens: [], reads: [], extracts: [], releases: [], idleCalls: 0 };
  f.downloads = base + '/Download/轻启·安装器/download';
  for (const p of [context.filesDir + '/download-receipts', context.cacheDir, f.downloads]) fs.mkdirSync(p, { recursive: true });
  const stat = s => ({ size: s.size, mtime: s.mtimeMs, ctime: s.ctimeMs,
    isFile: () => s.isFile(), isDirectory: () => s.isDirectory(), isSymbolicLink: () => s.isSymbolicLink() });
  const io = {
    OpenMode: { READ_ONLY: 0, NOFOLLOW: 0o400000, CREATE: 1, TRUNC: 2, WRITE_ONLY: 4 },
    accessSync: fs.existsSync, lstatSync: p => stat(fs.lstatSync(p)), lstat: async p => stat(await fs.promises.lstat(p)),
    statSync: p => stat(typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p)),
    mkdirSync: (p, recursive) => fs.mkdirSync(p, { recursive: Boolean(recursive) }),
    rmdirSync: p => fs.rmSync(p, { recursive: true }),
    listFile: fs.promises.readdir, listFileSync: fs.readdirSync, readText: p => fs.promises.readFile(p, 'utf8'),
    unlinkSync: fs.unlinkSync, renameSync: fs.renameSync,
    openSync: (p, mode) => {
      f.opens.push([p, mode]);
      const flags = mode & io.OpenMode.WRITE_ONLY ? 'w' : fs.constants.O_RDONLY | (mode & io.OpenMode.NOFOLLOW ? fs.constants.O_NOFOLLOW : 0);
      return { fd: fs.openSync(p, flags) };
    }, closeSync: file => fs.closeSync(file.fd), writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)),
    copyFile: async (from, to) => {
      if (f.copyGate) await f.copyGate.promise;
      if (f.copyHook) await f.copyHook(from, to);
      fs.writeFileSync(to, fs.readFileSync(from));
    }
  };
  const core = { fileIo: io, hash: { hash: async p => { if (f.hashHook) await f.hashHook(p); return digest(p); } } };
  const run = (p, ...args) => { f.reads.push(p); return execFileSync(cli, [p, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); };
  const native = {
    readModuleJson: p => run(p), readPackInfo: p => run(p, 'pack'),
    readInstallPermissions: p => JSON.stringify(JSON.parse(run(p)).module.requestPermissions.map(row => row.name)),
    readArchiveFile: () => new Uint8Array(),
    hasSigningBlock: p => { try { run(p, 'block'); return true; } catch (_) { return false; } },
    listPackageEntries: p => run(p, 'list').trim().split('\n').filter(Boolean).map(line => {
      const [size, name] = line.split('\t'); return { size: Number(size), name };
    }),
    extractPackageEntry: async (p, name, output) => { f.extracts.push([p, name, output]); run(p, 'extract', name, output); },
    extractInstallArchive: async (p, prefix, original) => {
      if (f.importHook) return f.importHook(p, prefix, original);
      return execFileSync(importer, ['extract', p, prefix, original], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim().split('\n').map(line => {
        const [name, path, size] = line.split('\t'); return { name, path, size: Number(size) };
      });
    }, verifyHap: () => assert.fail('analysis must not cryptographically validate or re-sign packages'),
    signHap: () => assert.fail('analysis must not sign packages')
  };
  const presentation = loadEts('jobs/PackagePresentation', { 'libhap_core.so': native });
  const inspector = loadEts('jobs/PackageInspector', { 'libhap_core.so': native, './PackagePresentation': presentation });
  const storage = { StorageBudget: { require: async (p, bytes) => {
    assert.ok(p.startsWith(context.cacheDir)); assert.ok(bytes >= 0 && bytes <= 8 * 1024 ** 3);
    if (f.storageHook) await f.storageHook();
  } } };
  const archive = loadEts('jobs/PackageArchive', { '@kit.CoreFileKit': core, 'libhap_core.so': native,
    './StorageBudget': storage, './PackageInspector': inspector, './PackagePresentation': presentation });
  const realRelease = archive.PackageArchive.release;
  archive.PackageArchive.release = p => { f.releases.push(p); realRelease.call(archive.PackageArchive, p); };
  f.archive = archive.PackageArchive;
  const library = loadEts('jobs/DownloadLibrary', {
    '@kit.CoreFileKit': core, '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } },
    './PublicDownloadDirectory': { PublicDownloadDirectory: { ensure: async () => ({ path: f.downloads, knownPaths: [f.downloads] }) } }
  });
  f.library = library.DownloadLibrary;
  const actualVerify = f.library.verify;
  f.library.verify = async (...args) => {
    const value = await actualVerify.apply(f.library, args);
    if (f.afterVerify) await f.afterVerify(value);
    return value;
  };
  const data = loadEts('data/InstalledInspection');
  f.api = loadEts('jobs/DownloadAnalysis', { '@kit.CoreFileKit': core, 'libhap_core.so': native,
    '../data/InstalledInspection': data, './DownloadLibrary': library, './PackageArchive': archive,
    './PackageInspector': inspector, './StorageBudget': storage,
    './ForegroundIdle': { ForegroundIdle: { wait: async () => { f.idleCalls++; if (f.idleHook) await f.idleHook(f.idleCalls); } } }
  }).DownloadAnalysis;
  const id = digest(fixtures + '/' + name), source = f.downloads + '/' + id + path.extname(name);
  fs.copyFileSync(fixtures + '/' + name, source);
  f.row = Object.assign(new library.DownloadedPackage(), { id, sha256: id, path: source, name,
    title: '目录名称不能冒充包名', version: '9.9.9-release', bytes: 9999999, bundleName: 'com.catalog.wrong' });
  fs.writeFileSync(context.filesDir + '/download-receipts/' + id + '.json', JSON.stringify(f.row));
  f.clean = () => {
    assert.equal(f.library.inUse(context, id), false, 'real DownloadLibrary pin must be released');
    const work = context.cacheDir + '/download-analysis';
    assert.deepEqual(fs.existsSync(work) ? fs.readdirSync(work) : [], [], 'all private analysis work is removed');
    assert.equal(f.archive.prepared.size, 0, 'all prepared APP modules are released');
  };
  return f;
}
const values = section => Object.fromEntries(Array.from(section.fields, field => [field.key, field.value]));

test('real HAP facts use pack.info version, readable Chinese keys and important nonempty fields', async t => {
  const f = fixture(t, 'one.hap'), before = digest(f.row.path), [section] = await f.api.read(f.context, f.row);
  const fields = values(section);
  assert.equal(section.name, '甲应用'); assert.equal(fields['包名'], 'com.example.first');
  assert.equal(fields['包内版本'], '1.2.0'); assert.equal(fields['内部编号'], '20');
  assert.equal(fields['最低 API'], '24'); assert.equal(fields['目标 API'], '26');
  assert.equal(fields['设备类型'], 'phone、tablet'); assert.match(fields['权限'], /ohos.permission.INTERNET/);
  assert.equal(fields['签名块'], '未检出'); assert.equal(fields['SHA-256'], before);
  assert.equal(JSON.stringify(section).includes('do not display'), false);
  assert.equal(JSON.stringify(section).includes('9.9.9-release'), false);
  assert.ok(section.fields.every(field => field.key === field.label && typeof field.value === 'string' && field.value.trim()));
  assert.equal(digest(f.row.path), before); assert.ok(f.reads.every(p => p.startsWith(f.context.cacheDir + '/download-analysis/')));
  assert.equal(f.opens.find(([p]) => p === f.row.path)[1] & 0o400000, 0o400000); f.clean();
});

test('signed-block structure is reported explicitly as unverified, never as signature or authorization validity', async t => {
  const f = fixture(t, 'signed.hap'), [section] = await f.api.read(f.context, f.row);
  assert.equal(values(section)['签名块'], '已检出（未验签）'); f.clean();
});

test('real APP inspects every module only beside its private copy and releases its prepared cache', async t => {
  const f = fixture(t, 'two.app'), before = fs.readFileSync(f.row.path), [section] = await f.api.read(f.context, f.row);
  const fields = values(section);
  assert.equal(section.name, '乙应用'); assert.equal(fields['模块数'], '2'); assert.equal(fields['入口模块'], 'entry');
  assert.equal(fields['模块'], 'entry、feature'); assert.equal(fields['主入口'], 'MainAbility');
  assert.match(fields['签名块'], /外包: 未检出/); assert.match(fields['签名块'], /feature: 未检出/);
  assert.equal(fields['权限'].split('\n').length, 2, 'permissions are a real union across modules');
  assert.ok(f.extracts.length >= 2); assert.ok(f.extracts.every(row => row[2].startsWith(f.context.cacheDir + '/download-analysis/')));
  assert.deepEqual(fs.readFileSync(f.row.path), before); assert.deepEqual(fs.readdirSync(f.downloads), [path.basename(f.row.path)]); f.clean();
});

test('real ZIP returns all distinct applications and keeps a corrupt neighboring HAP as a parse error', async t => {
  const f = fixture(t, 'multiple.zip'), before = digest(f.row.path), sections = await f.api.read(f.context, f.row);
  assert.equal(sections.length, 4); assert.equal(sections[0].name, '压缩包');
  assert.equal(values(sections[0])['安装包数量'], '3');
  assert.equal(values(sections[1])['包名'], 'com.example.first'); assert.equal(values(sections[1])['文件名'], 'apps/one.hap');
  assert.equal(values(sections[2])['包名'], 'com.example.second'); assert.equal(values(sections[2])['模块数'], '2');
  assert.equal(sections[3].name, 'bad.hap'); assert.ok(values(sections[3])['解析错误']);
  assert.equal(digest(f.row.path), before); f.clean();
});

for (const name of ['one.hap.gz', 'packages.tgz']) test('existing native decompression reads original package facts from ' + name, async t => {
  const f = fixture(t, name), sections = await f.api.read(f.context, f.row);
  assert.equal(sections.length, 2); assert.equal(values(sections[1])['包名'], 'com.example.first');
  assert.equal(values(sections[1])['包内版本'], '1.2.0'); f.clean();
});

test('four APP archive members are parsed and released sequentially without exhausting the shared two-APP cache', async t => {
  const f = fixture(t, 'many-apps.zip'), sections = await f.api.read(f.context, f.row);
  assert.equal(sections.length, 5); assert.ok(sections.slice(1).every(section => values(section)['模块数'] === '2'));
  assert.equal(new Set(f.releases.filter(p => /member-\d+\.app$/.test(p))).size, 4); f.clean();
});

test('a real library pin blocks clear/delete throughout asynchronous copying and parsing', async t => {
  const f = fixture(t, 'two.app'); f.copyGate = deferred();
  const reading = f.api.read(f.context, f.row); await tick(); await tick();
  assert.equal(f.library.inUse(f.context, f.row.id), true);
  assert.equal(await f.library.remove(f.context, f.row.id), false); assert.equal(fs.existsSync(f.row.path), true);
  f.copyGate.resolve(); f.copyGate = undefined; await reading; f.clean();
});

test('an externally modified original is rejected by real verification before parsing', async t => {
  const f = fixture(t, 'one.hap'); fs.writeFileSync(f.row.path, 'changed');
  await assert.rejects(f.api.read(f.context, f.row), /下载文件已删除或已变化/);
  assert.equal(f.reads.length, 0); f.clean();
});

test('a replacement after verification cannot bypass NOFOLLOW or mutate source data', async t => {
  const f = fixture(t, 'one.hap'), other = f.base + '/other.hap'; fs.copyFileSync(f.row.path, other);
  f.storageHook = async () => { fs.unlinkSync(f.row.path); fs.symlinkSync(other, f.row.path); };
  await assert.rejects(f.api.read(f.context, f.row)); assert.equal(digest(other), f.row.id);
  assert.equal(f.reads.length, 0); f.clean();
});

test('a public-file write between verification and copying is rejected by the private snapshot SHA', async t => {
  const f = fixture(t, 'one.hap');
  f.copyHook = async () => fs.writeFileSync(f.row.path, Buffer.alloc(fs.statSync(f.row.path).size, 32));
  await assert.rejects(f.api.read(f.context, f.row), /安装包已变化/); assert.equal(f.reads.length, 0); f.clean();
});

test('a normal source modification after a verified copy invalidates the result before returning it', async t => {
  const f = fixture(t, 'one.hap');
  f.idleHook = async count => { if (count === 2) fs.appendFileSync(f.row.path, 'later external write'); };
  await assert.rejects(f.api.read(f.context, f.row), /安装包已变化/); f.clean();
});

test('storage failure, an invalid APP and unsafe archive extraction release pins and all partial work', async t => {
  const low = fixture(t, 'one.hap'); low.storageHook = async () => { throw Error('storage full'); };
  await assert.rejects(low.api.read(low.context, low.row), /storage full/); low.clean();
  for (const name of ['mixed.app', 'unsafe.zip']) {
    const f = fixture(t, name), before = digest(f.row.path);
    await assert.rejects(f.api.read(f.context, f.row)); assert.equal(digest(f.row.path), before); f.clean();
  }
});

test('an extracted path outside the owned work directory is never parsed or deleted', async t => {
  const f = fixture(t, 'multiple.zip'), outside = f.base + '/outside.hap'; fs.copyFileSync(fixtures + '/one.hap', outside);
  f.importHook = async () => [{ name: 'outside.hap', path: outside, size: fs.statSync(outside).size }];
  await assert.rejects(f.api.read(f.context, f.row), /路径无效/);
  assert.equal(digest(outside), digest(fixtures + '/one.hap')); assert.equal(f.reads.length, 0); f.clean();
});
