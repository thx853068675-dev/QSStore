const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { loadEts } = require('./load_ets.cjs');
const { ListDataSource } = loadEts('data/ListDataSource');
const ts = require(process.env.QINGQI_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main');
const source = fs.readFileSync(path.join(root, 'ets/pages/Downloads.ets'), 'utf8');
const methods = source.slice(source.indexOf('struct Downloads {') + 'struct Downloads {'.length,
  source.indexOf('  @Builder private tools()')).replace(/@StorageProp\([^)]*\)|@State/g, '');
const code = ts.transpileModule('class Downloads {' + methods + '\n}; globalThis.Page=Downloads;', {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;
const row = { id: 'a'.repeat(64), title: '应用', name: 'app.hap', version: '1.2.6', bytes: 2048 };
function fixture() {
  const f = { lists: [], removed: [], cleared: 0, count: 1, files: [row], toasts: [],
    frames: [], timers: [], order: [], prunes: 0, prefWrites: [], autoEnabled: false, iconReads: [], decodes: 0, iconReleased: 0,
    analyses: [], sections: [], copied: [], abilityStarts: [],
    location: { path: '/storage/Users/currentUser/Download/轻启·安装器/download',
      uri: 'file://docs/storage/Users/currentUser/Download/%E8%BD%BB%E5%90%AF%C2%B7%E5%AE%89%E8%A3%85%E5%99%A8/download',
      displayPath: '下载/轻启·安装器/download' } };
  f.context = { filesDir: '/sandbox', startAbility: async want => {
    f.abilityStarts.push(want); if (f.abilityWait) await f.abilityWait;
    if (f.abilityError) throw Error('系统文件管理器不可用');
    if (f.hideOnLaunch) f.ui.onPageHide();
  } };
  const box = { ListDataSource, getContext: () => f.context, errorText: error => error.message,
    InspectionSection: class { name = ''; fields = []; },
    DownloadAnalysis: { read: async (_ctx, value) => {
      f.analyses.push(value); if (f.analysisRead) return f.analysisRead(value);
      if (f.analysisError) throw Error('无法读取安装包'); return f.sections;
    } },
    pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (type, value) => ({ type, value }),
      getSystemPasteboard: () => ({ setData: async data => {
        if (f.copyWait) await f.copyWait; if (f.copyError) throw Error('clipboard unavailable'); f.copied.push(data);
      } }) },
    DownloadIconCache: { key: value => value.id + ':' + (value.bundleName || ''), load: async (_ctx, value) => {
      f.iconReads.push(value); if (f.iconReadWait) await f.iconReadWait; return f.iconBytes;
    } },
    image: { createImageSource: () => ({ getImageInfo: async () => ({ size: { width: 96, height: 96 } }),
      createPixelMap: async () => { f.decodes++; if (f.iconDecodeWait) await f.iconDecodeWait;
        return { release: () => f.iconReleased++ }; }, release() {} }) },
    DownloadLibrary: { getLocation: async () => { const location = f.location; f.order.push('location');
      if (f.locationWait) await f.locationWait; if (f.locationError) throw Error('公共目录未授权'); return location; },
      list: async () => { const list = f.list || (async () => f.files); f.order.push('list'); f.lists.push(true); return list(); },
      remove: async (_ctx, id) => { f.removed.push(id); if (f.removeError) throw Error('正在使用');
        if (f.removeWait) await f.removeWait; if (f.removeFalse) return false; f.files = []; return true; },
      clear: async () => { f.cleared++; f.files = f.remaining || []; return f.count; } },
    JobStore: { open: async () => { f.order.push('store'); if (f.storeWait) await f.storeWait;
      return { pruneCompleted: async () => { f.order.push('prune'); f.prunes++;
        if (f.pruneError) throw Error('保存下载包失败'); if (f.recovered) f.files = f.recovered; } }; } },
    DownloadShare: class { async open(_ctx, id) { f.shareId = id;
      if (f.shareError) throw Error('原始下载包已变化'); if (f.shareWait) await f.shareWait; }
      cancel() { f.shareCanceled = true; f.cancelShare?.(); } },
    DownloadPreferences: { load: async () => { if (f.preferenceReadWait) await f.preferenceReadWait; return f.autoEnabled; },
      save: async (_ctx, enabled) => { f.prefWrites.push(enabled); if (f.preferenceWriteWait) await f.preferenceWriteWait;
        if (f.preferenceWriteError) throw Error('disk full'); f.autoEnabled = enabled; } },
    promptAction: { showToast: option => f.toasts.push(option.message) },
    StorePageMotion: { dismissFrame: async () => { f.frames.push(f.ui.headerVisible);
      if (f.dismissWait) await f.dismissWait; }, prepare() {} },
    router: { back: () => { f.back = true; } },
    AlertDialog: { show: option => { if (f.dialogError) throw Error('弹窗不可用'); f.dialog = option; } }, setTimeout: task => { f.timers.push(task); return 1; },
    clearTimeout() {}, Palette: { forMode: () => ({}) }
  };
  box.DownloadDirectoryOpen = loadEts('jobs/DownloadDirectoryOpen', {
    './DownloadLibrary': { DownloadLibrary: box.DownloadLibrary }
  }).DownloadDirectoryOpen;
  vm.runInNewContext(code, box); f.ui = new box.Page(); f.ui.loading = false; f.ui.rows = [row];
  return f;
}
test('every page show re-reads the library so an externally removed download disappears', async () => {
  const f = fixture(); f.ui.onPageShow(); await new Promise(setImmediate);
  assert.equal(f.ui.rows.length, 1); f.ui.onPageHide(); f.files = [];
  f.ui.onPageShow(); await new Promise(setImmediate); assert.equal(f.ui.rows.length, 0);
  assert.equal(f.lists.length, 2);
});
test('late reads cannot overwrite the newest list or revive a disposed page', async () => {
  const f = fixture(); let release; f.list = () => new Promise(done => release = done);
  const old = f.ui.load(); await new Promise(setImmediate); f.list = async () => []; await f.ui.load();
  release([row]); await old; assert.equal(f.ui.rows.length, 0);
  let finish; f.list = () => new Promise(done => finish = done);
  const final = f.ui.load(); await new Promise(setImmediate); f.ui.aboutToDisappear(); finish([row]); await final;
  assert.equal(f.ui.rows.length, 0); assert.equal(f.ui.headerVisible, false);
});
test('hidden-page reads are invalidated and resume obtains a new real file listing', async () => {
  const f = fixture(); let release; f.list = () => new Promise(done => release = done);
  const old = f.ui.load(); await new Promise(setImmediate); f.ui.onPageHide(); release([]); await old;
  assert.equal(f.ui.rows.length, 1); f.list = async () => []; f.ui.onPageShow();
  await new Promise(setImmediate); assert.equal(f.ui.rows.length, 0); assert.equal(f.ui.loading, false);
});
test('unchanged downloaded packages preserve lazy card identity while a removed file leaves the data source', async () => {
  const f = fixture(); await f.ui.load();
  const key = f.ui.listRows.key(row); await f.ui.load();
  assert.equal(f.ui.listRows.key(row), key); assert.equal(f.ui.listRows.totalCount(), 1);
  f.files = []; await f.ui.load(); assert.equal(f.ui.listRows.totalCount(), 0);
});
test('a late directory authorization cannot prune or publish over the newest listing', async () => {
  const f = fixture(); let finish; f.locationWait = new Promise(done => finish = done);
  const old = f.ui.load(); await new Promise(setImmediate);
  f.locationWait = undefined; f.files = [];
  await f.ui.load(); finish(); await old;
  assert.equal(f.ui.rows.length, 0);
  assert.equal(f.prunes, 1); assert.equal(f.lists.length, 1);
  assert.deepEqual(f.order, ['location', 'location', 'store', 'prune', 'list']);
});
test('unavailable public storage still lists and manages old originals without pruning', async () => {
  const f = fixture(); f.locationError = true;
  await f.ui.load(); assert.equal(f.ui.rows.length, 1); assert.equal(f.ui.listRows.totalCount(), 1);
  assert.match(f.ui.notice, /下载位置暂不可用.*未授权/);
  assert.equal(f.prunes, 0);
  await f.ui.share(row); assert.equal(f.shareId, row.id);
});
test('a restored public directory retries completed archives before listing without restarting the app', async () => {
  const f = fixture(); f.files = []; f.recovered = [row]; await f.ui.load();
  assert.deepEqual(f.order, ['location', 'store', 'prune', 'list']);
  assert.equal(f.ui.rows.length, 1); assert.equal(f.prunes, 1);
});
test('a controlled archive retry failure does not hide already retained library files', async () => {
  const f = fixture(); f.pruneError = true; await f.ui.load();
  assert.equal(f.ui.rows.length, 1); assert.equal(f.ui.listRows.totalCount(), 1);
  assert.equal(f.ui.loading, false); assert.match(f.ui.notice, /归档暂未完成.*保存下载包失败/);
});
test('leaving while the archive store opens prevents stale pruning and list publication', async () => {
  const f = fixture(); let finish; f.storeWait = new Promise(done => finish = done);
  const reading = f.ui.load(); await new Promise(setImmediate); f.ui.aboutToDisappear();
  finish(); await reading; assert.equal(f.prunes, 0); assert.equal(f.lists.length, 0);
});
test('single delete bypasses confirmation but re-reads after actual removal', async () => {
  const f = fixture(); await f.ui.remove(row);
  assert.deepEqual(f.removed, [row.id]); assert.equal(f.dialog, undefined);
  assert.equal(f.ui.rows.length, 0); assert.equal(f.ui.working, false); assert.match(f.toasts[0], /已删除/);
});
test('a reserved or already removed file keeps the refreshed list and reports a retry', async () => {
  const f = fixture(); f.removeFalse = true; await f.ui.remove(row);
  assert.equal(f.ui.rows.length, 1); assert.match(f.toasts[0], /正在使用或已移除/);
  assert.equal(f.ui.working, false);
});
test('deletion failure restores controls even when it invalidates an older loading read', async () => {
  const f = fixture(); f.ui.loading = true; f.removeError = true; await f.ui.remove(row);
  assert.equal(f.ui.working, false); assert.equal(f.ui.loading, false); assert.match(f.ui.notice, /正在使用/);
});
test('overlapping deletes cannot start another cleanup operation', async () => {
  const f = fixture(); let release; f.removeWait = new Promise(done => release = done);
  const first = f.ui.remove(row); await f.ui.remove(row); await f.ui.clear();
  assert.equal(f.removed.length, 1); assert.equal(f.cleared, 0); release(); await first;
});
test('clear requires one explicit confirmation; empty and busy lists cannot request it', async () => {
  const f = fixture(); await f.ui.requestClear(); assert.equal(f.cleared, 0);
  assert.deepEqual(f.frames, [false]); assert.equal(f.ui.headerVisible, false);
  f.dialog.primaryButton.action(); assert.equal(f.ui.headerVisible, true); assert.equal(f.cleared, 0);
  const empty = fixture(); empty.ui.rows = []; await empty.ui.requestClear(); assert.equal(empty.dialog, undefined);
  const busy = fixture(); busy.ui.working = true; await busy.ui.requestClear(); assert.equal(busy.dialog, undefined);
  const failing = fixture(); failing.dialogError = true; await failing.ui.requestClear();
  assert.equal(failing.ui.headerVisible, true); assert.equal(failing.ui.showingClear, false);
  assert.equal(failing.cleared, 0); assert.match(failing.ui.notice, /弹窗不可用/);
});
test('bulk cleanup reports retained reserved files and refreshes the library', async () => {
  const f = fixture(); f.remaining = [row]; f.count = 0; await f.ui.requestClear();
  f.dialog.secondaryButton.action(); await new Promise(setImmediate);
  assert.equal(f.cleared, 1); assert.equal(f.ui.rows.length, 1);
  assert.match(f.toasts[0], /已删除 0 个.*未删除文件已保留/); assert.equal(f.ui.working, false);
});
test('file sharing hides native material until completion, then re-reads files without creating an export flow', async () => {
  const f = fixture(); let finish; f.shareWait = new Promise(done => finish = done);
  const sharing = f.ui.share(row); await new Promise(setImmediate);
  assert.equal(f.shareId, row.id); assert.deepEqual(f.frames, [false]); assert.equal(f.ui.headerVisible, false);
  await f.ui.remove(row); assert.equal(f.removed.length, 0);
  f.ui.onPageShow(); await new Promise(setImmediate); assert.equal(f.ui.headerVisible, false);
  finish(); await sharing; assert.equal(f.ui.headerVisible, true); assert.equal(f.ui.working, false);
});
test('failed or disposed sharing cannot recreate header material and leaves a changed-file error readable', async () => {
  const error = fixture(); error.shareError = true; await error.ui.share(row);
  assert.match(error.ui.notice, /已变化/); assert.equal(error.ui.headerVisible, true); assert.equal(error.ui.working, false);
  const disposed = fixture(); disposed.shareWait = new Promise(done => disposed.cancelShare = done);
  const sharing = disposed.ui.share(row); await new Promise(setImmediate); disposed.ui.aboutToDisappear();
  await sharing; assert.equal(disposed.shareCanceled, true); assert.equal(disposed.ui.headerVisible, false);
});
test('download settings hides material before opening, restores persisted default-off choice and closes on back', async () => {
  const f = fixture(); await f.ui.openSettings(); assert.deepEqual(f.frames, [false]);
  assert.equal(f.ui.showSettings, true); assert.equal(f.ui.autoClean, false); assert.equal(f.ui.headerVisible, false);
  assert.equal(f.ui.onBackPress(), true); assert.equal(f.ui.showSettings, false); assert.equal(f.ui.headerVisible, true);
  assert.equal(f.timers.length, 0, 'back first dismisses settings instead of leaving the downloads page');
  assert.equal(f.removed.length, 0); assert.equal(f.cleared, 0); assert.equal(f.prunes, 0);
});
test('rapid cleanup toggles serialize their writes and persist the latest choice without deleting history', async () => {
  const f = fixture(); await f.ui.openSettings(); let finish;
  f.preferenceWriteWait = new Promise(done => finish = done);
  f.ui.changeAutoClean(true); f.ui.changeAutoClean(false); f.ui.changeAutoClean(true);
  assert.equal(f.ui.autoClean, true);
  await new Promise(setImmediate); assert.deepEqual(f.prefWrites, [true]);
  finish(); await f.ui.settingsWrites;
  assert.deepEqual(f.prefWrites, [true, false, true]); assert.equal(f.autoEnabled, true);
  assert.equal(f.lists.length, 0); assert.equal(f.prunes, 0);
  assert.equal(f.removed.length, 0); assert.equal(f.cleared, 0);
});
test('reopening during pending saves waits for the latest durable choice instead of reviving an old load', async () => {
  const f = fixture(); await f.ui.openSettings(); let finish;
  f.preferenceWriteWait = new Promise(done => finish = done);
  f.ui.changeAutoClean(true); f.ui.closeSettings(); const reopen = f.ui.openSettings();
  await new Promise(setImmediate); assert.equal(f.ui.settingsReading, true);
  finish(); await reopen; assert.equal(f.ui.autoClean, true); assert.equal(f.ui.settingsReading, false);
});
test('save failure restores the prior setting and keeps a readable error without touching downloads', async () => {
  const f = fixture(); await f.ui.openSettings(); f.preferenceWriteError = true;
  f.ui.changeAutoClean(true); await f.ui.settingsWrites;
  assert.equal(f.ui.autoClean, false);
  assert.match(f.ui.settingsNotice, /保存失败.*disk full/); assert.equal(f.cleared, 0);
});
test('late preference loading cannot reopen a dismissed settings dialog or overwrite a disposed page', async () => {
  const f = fixture(); let finish; f.autoEnabled = true;
  f.preferenceReadWait = new Promise(done => finish = done);
  const opening = f.ui.openSettings(); await new Promise(setImmediate); f.ui.closeSettings();
  finish(); await opening; assert.equal(f.ui.showSettings, false); assert.equal(f.ui.autoClean, false);
  const disposed = fixture(); let done; disposed.preferenceReadWait = new Promise(resolve => done = resolve);
  const waiting = disposed.ui.openSettings(); await new Promise(setImmediate); disposed.ui.aboutToDisappear();
  done(); await waiting; assert.equal(disposed.ui.headerVisible, false); assert.equal(disposed.ui.showSettings, false);
});
test('download route and management entry reuse material, responsive frames and swipe-only delete', () => {
  const profile = JSON.parse(fs.readFileSync(path.join(root, 'resources/base/profile/main_pages.json'), 'utf8'));
  assert.ok(profile.src.includes('pages/Downloads'));
  const index = fs.readFileSync(path.join(root, 'ets/pages/Index.ets'), 'utf8');
  assert.match(index, /HomeIconButton\(\{[\s\S]*?controlId: 'management-downloads'[\s\S]*?url: 'pages\/Downloads'/);
  assert.match(source, /StorePageHeader\(\{ title: (?:I18n\.t\()?'下载'/);
  assert.match(source, /StoreLayout\.frameMaxWidth\(this\.windowWidth\)/);
  assert.match(source, /CatalogAppTitle\(\{ title: row\.title \|\| row\.name, titleSize: 15, titleLines: 2/);
  assert.match(source, /LazyForEach\(this\.listRows/);
  assert.match(source, /swipeAction\(/); assert.doesNotMatch(source, /LongPressGesture|\.onLongPress/);
  assert.match(source, /backgroundColor\(this\.colors\(\)\.danger\)/);
  assert.match(source, /Text\((?:I18n\.t\()?'分享'\)/); assert.match(source, /actionAreaDistance: 216/);
  const clear = source.indexOf("controlId: 'downloads-clear'");
  const settings = source.indexOf("controlId: 'downloads-settings'");
  const directory = source.indexOf("controlId: 'downloads-directory'");
  assert.ok(clear < settings && settings < directory, 'header controls are delete, settings, then folder');
  assert.match(source, /StoreImmersiveIconButton\(\{ symbol: \$r\('sys\.symbol\.folder'\), label: (?:I18n\.t\()?'打开下载目录'/);
  assert.match(source, /StoreIconButton\(\{ action: \(\) => this\.closeSettings\(\)/);
  assert.match(source, /scrim\)\.onClick\(\(\) => this\.closeSettings\(\)/);
});
test('folder opens the exact system-authorized public URI even for an empty download list', async () => {
  const f = fixture(); f.ui.rows = []; f.ui.loading = true;
  await f.ui.openDirectory();
  assert.deepEqual(JSON.parse(JSON.stringify(f.abilityStarts)), [{
    bundleName: 'com.huawei.hmos.filemanager', abilityName: 'MainAbility',
    parameters: { fileUri: f.location.uri }
  }]);
  assert.deepEqual(f.frames, []); assert.equal(f.ui.working, false);
  assert.equal(f.ui.headerVisible, true); assert.deepEqual(f.toasts, []);
});
test('directory errors are readable and do not block a subsequent successful open', async () => {
  const f = fixture(); f.locationError = true;
  await f.ui.openDirectory(); assert.equal(f.abilityStarts.length, 0);
  assert.match(f.ui.notice, /无法打开下载目录.*未授权/); assert.equal(f.ui.headerVisible, true);
  assert.equal(f.ui.working, false); assert.equal(f.toasts.length, 1);
  f.locationError = false; f.abilityError = true; await f.ui.openDirectory();
  assert.match(f.ui.notice, /系统文件管理器不可用/); assert.equal(f.ui.working, false);
  f.abilityError = false; await f.ui.openDirectory();
  assert.equal(f.abilityStarts.length, 2); assert.equal(f.ui.notice, '');
});
test('duplicate directory clicks and competing file operations cannot launch concurrent panels', async () => {
  const f = fixture(); let finish; f.locationWait = new Promise(done => finish = done);
  const opening = f.ui.openDirectory(); await new Promise(setImmediate);
  await f.ui.openDirectory(); await f.ui.remove(row); await f.ui.share(row); await f.ui.openSettings();
  assert.equal(f.order.filter(value => value === 'location').length, 1);
  assert.equal(f.removed.length, 0); assert.equal(f.shareId, undefined); assert.equal(f.ui.showSettings, false);
  finish(); await opening; assert.equal(f.abilityStarts.length, 1); assert.equal(f.ui.working, false);
});
test('leaving during directory preparation prevents a delayed system launch even after returning', async () => {
  for (const lifecycle of ['onPageHide', 'aboutToDisappear', 'back']) {
    const f = fixture(); let finish; f.locationWait = new Promise(done => finish = done);
    const opening = f.ui.openDirectory(); await new Promise(setImmediate);
    f.ui[lifecycle]();
    if (lifecycle === 'onPageHide') { f.ui.onPageShow(); }
    finish(); await opening;
    assert.equal(f.abilityStarts.length, 0, lifecycle);
    assert.equal(f.toasts.length, 0, lifecycle);
    if (lifecycle !== 'onPageHide') assert.equal(f.ui.headerVisible, false, lifecycle);
  }
});
test('directory launch resolution before page hide preserves the existing header without popup recreation', async () => {
  const f = fixture(); let finish; f.abilityWait = new Promise(done => finish = done);
  const opening = f.ui.openDirectory(); await new Promise(setImmediate);
  assert.equal(f.ui.headerVisible, true); assert.equal(f.ui.working, true); assert.deepEqual(f.frames, []);
  finish(); await opening; assert.equal(f.ui.headerVisible, true); assert.equal(f.ui.working, false);
  f.ui.onPageHide(); assert.equal(f.ui.headerVisible, false);
  f.ui.onPageShow(); await new Promise(setImmediate); assert.equal(f.ui.headerVisible, true);
});
test('returning from the file manager restores controls and reflects externally deleted files', async () => {
  const f = fixture(); f.hideOnLaunch = true;
  await f.ui.openDirectory(); assert.equal(f.ui.headerVisible, false); assert.equal(f.ui.working, false);
  f.files = []; f.ui.onPageShow(); await new Promise(setImmediate);
  assert.equal(f.ui.headerVisible, true); assert.equal(f.ui.rows.length, 0);
  await f.ui.openDirectory(); assert.equal(f.abilityStarts.length, 2);
});
test('an old directory launch failure cannot show a toast on a hidden or disposed page', async () => {
  for (const lifecycle of ['onPageHide', 'aboutToDisappear']) {
    const f = fixture(); let finish; f.abilityError = true;
    f.abilityWait = new Promise(done => finish = done);
    const opening = f.ui.openDirectory(); await new Promise(setImmediate);
    f.ui[lifecycle](); finish(); await opening;
    assert.equal(f.toasts.length, 0); assert.equal(f.ui.headerVisible, false); assert.equal(f.ui.notice, '');
  }
});
test('real package icons fill existing lazy cards without changing their key and survive page hide/show or sharing', async () => {
  const f = fixture(); f.iconBytes = new ArrayBuffer(4);
  await f.ui.load(); const key = f.ui.listRows.key(row); await new Promise(setImmediate);
  const icon = f.ui.downloadIcon(row); assert.ok(icon); assert.equal(f.decodes, 1);
  assert.equal(f.ui.listRows.key(row), key);
  f.ui.onPageHide(); f.ui.onPageShow(); await new Promise(setImmediate);
  assert.equal(f.ui.downloadIcon(row), icon); assert.equal(f.decodes, 1);
  await f.ui.share(row); await new Promise(setImmediate);
  assert.equal(f.ui.downloadIcon(row), icon); assert.equal(f.ui.listRows.key(row), key);
});
test('a late icon cannot resurrect an externally deleted row or a disposed page', async () => {
  const f = fixture(); f.iconBytes = new ArrayBuffer(4); let finish;
  f.iconReadWait = new Promise(done => finish = done); await f.ui.load();
  f.files = []; await f.ui.load(); finish(); await new Promise(setImmediate);
  assert.equal(f.ui.rows.length, 0); assert.equal(f.ui.icons.size, 0); assert.equal(f.decodes, 0);
  const disposed = fixture(); disposed.iconBytes = new ArrayBuffer(4); let decoded;
  disposed.iconDecodeWait = new Promise(done => decoded = done);
  await disposed.ui.load(); await new Promise(setImmediate); disposed.ui.aboutToDisappear();
  decoded(); await new Promise(setImmediate); assert.equal(disposed.ui.icons.size, 0); assert.equal(disposed.iconReleased, 1);
});
test('the same ZIP SHA with a different selected bundle never reuses the previous application icon', async () => {
  const f = fixture(); f.iconBytes = new ArrayBuffer(4);
  const a = { ...row, bundleName: 'com.example.a', name: 'multi.zip' }, b = { ...a, bundleName: 'com.example.b' };
  f.files = [a]; await f.ui.load(); await new Promise(setImmediate); const previous = f.ui.downloadIcon(a); assert.ok(previous);
  f.files = [b]; await f.ui.load(); await new Promise(setImmediate);
  assert.equal(f.ui.downloadIcon(a), undefined); assert.notEqual(f.ui.downloadIcon(b), previous);
  assert.equal(f.decodes, 2); assert.equal(f.iconReleased, 1);
});
test('analysis opens immediately and reads in the background while all competing file operations are blocked', async () => {
  const f = fixture(); let finish;
  f.analysisRead = () => new Promise(done => finish = done);
  const reading = f.ui.analyze(row);
  assert.equal(f.ui.showAnalysis, true); assert.equal(f.ui.analysisLoading, true);
  assert.equal(f.ui.analysisRow, row); assert.equal(f.ui.headerVisible, false);
  await new Promise(setImmediate);
  assert.equal(f.analyses.length, 1); assert.deepEqual(f.frames, [false]);
  await f.ui.analyze(row); await f.ui.remove(row); await f.ui.share(row); await f.ui.clear();
  await f.ui.requestClear(); await f.ui.openSettings();
  assert.equal(f.analyses.length, 1); assert.equal(f.removed.length, 0); assert.equal(f.shareId, undefined);
  assert.equal(f.cleared, 0); assert.equal(f.dialog, undefined); assert.equal(f.ui.showSettings, false);
  finish([{ name: '应用', fields: [{ key: '包名', value: 'com.example.app' }] }]); await reading;
  assert.equal(f.ui.analysisLoading, false); assert.equal(f.ui.analysisSections.length, 1);
  f.ui.closeAnalysis(); assert.equal(f.ui.headerVisible, true); assert.equal(f.ui.showAnalysis, false);
  await f.ui.share(row); assert.equal(f.shareId, row.id, 'closing makes the next operation available');
});
test('closing and starting another analysis prevents old results or failures from replacing the current application', async () => {
  const f = fixture(); let finish, fail;
  f.analysisRead = () => new Promise((done, reject) => { finish = done; fail = reject; });
  const old = f.ui.analyze(row); await new Promise(setImmediate); f.ui.closeAnalysis();
  const next = { ...row, id: 'b'.repeat(64), name: 'other.app' };
  f.sections = [{ name: '另一个应用', fields: [{ key: '版本', value: '2.0' }] }]; f.analysisRead = undefined;
  await f.ui.analyze(next); finish([{ name: '旧应用', fields: [{ key: '版本', value: '1.0' }] }]); await old;
  assert.equal(f.ui.analysisRow, next); assert.equal(f.ui.analysisSections[0].name, '另一个应用');
  assert.equal(f.ui.analysisLoading, false); assert.equal(f.ui.analysisNotice, '');
  f.ui.closeAnalysis(); f.analysisRead = () => new Promise((_done, reject) => fail = reject);
  const failed = f.ui.analyze(row); await new Promise(setImmediate); f.ui.closeAnalysis();
  f.analysisRead = undefined; await f.ui.analyze(next); fail(Error('迟到失败')); await failed;
  assert.equal(f.ui.analysisRow, next); assert.equal(f.ui.analysisNotice, '');
});
test('back dismisses package analysis first and page hide or disposal never publishes late analysis', async () => {
  const f = fixture(); await f.ui.analyze(row);
  assert.equal(f.ui.onBackPress(), true); assert.equal(f.ui.showAnalysis, false);
  assert.equal(f.timers.length, 0); assert.equal(f.ui.headerVisible, true);
  for (const lifecycle of ['onPageHide', 'aboutToDisappear']) {
    const hidden = fixture(); let finish;
    hidden.analysisRead = () => new Promise(done => finish = done);
    const pending = hidden.ui.analyze(row); await new Promise(setImmediate); hidden.ui[lifecycle]();
    finish([{ name: '旧应用', fields: [{ key: '版本', value: '1.0' }] }]); await pending;
    assert.equal(hidden.ui.showAnalysis, false); assert.equal(hidden.ui.analysisSections.length, 0);
    assert.equal(hidden.ui.analysisRow, undefined); assert.equal(hidden.ui.headerVisible, false);
  }
});
test('analysis failure remains dismissible and unavailable or already busy page states cannot start a read', async () => {
  const f = fixture(); f.analysisError = true; await f.ui.analyze(row);
  assert.match(f.ui.analysisNotice, /无法读取/); assert.equal(f.ui.analysisLoading, false);
  assert.equal(f.ui.showAnalysis, true); f.ui.closeAnalysis(); assert.equal(f.ui.headerVisible, true);
  for (const state of ['working', 'loading', 'showSettings', 'settingsOpening', 'showingClear', 'disposed', 'returning']) {
    const busy = fixture(); busy.ui[state] = true; await busy.ui.analyze(row);
    assert.equal(busy.analyses.length, 0); assert.equal(busy.ui.showAnalysis, false);
  }
  const hidden = fixture(); hidden.ui.pageActive = false; await hidden.ui.analyze(row);
  assert.equal(hidden.analyses.length, 0);
});
test('analysis omits empty fields and sections, copies the exact value and only toasts that value', async () => {
  const f = fixture();
  f.sections = [{ name: '空区域', fields: [{ key: '空列表', value: '[]' }] },
    { name: '应用', fields: [{ key: '空值', value: '  ' }, { key: '空对象', value: '{}' },
      { key: '包名', label: '包名', value: 'com.example.app' }, { key: '权限', value: '权限甲\n权限乙' }] }];
  await f.ui.analyze(row); assert.equal(f.ui.analysisSections.length, 1);
  assert.deepEqual(Array.from(f.ui.analysisSections[0].fields, field => field.key), ['包名', '权限']);
  await f.ui.copyAnalysisValue('权限甲\n权限乙');
  assert.deepEqual(f.copied, [{ type: 'text/plain', value: '权限甲\n权限乙' }]);
  assert.deepEqual(f.toasts, ['权限甲\n权限乙']);
  f.copyError = true; await f.ui.copyAnalysisValue('com.example.app'); assert.match(f.toasts[1], /暂时无法复制/);
  f.ui.closeAnalysis(); await f.ui.copyAnalysisValue('关闭后不复制'); assert.equal(f.copied.length, 1);
});
test('a clipboard completion after closing analysis cannot show a stale toast over another operation', async () => {
  const f = fixture(); await f.ui.analyze(row); let finish;
  f.copyWait = new Promise(done => finish = done);
  const copying = f.ui.copyAnalysisValue('com.example.app'); f.ui.closeAnalysis();
  finish(); await copying; assert.equal(f.toasts.length, 0);
});
test('analysis is a centered dark-aware scrollable popup with close and copy controls, following swipe action order', () => {
  const action = source.slice(source.indexOf('@Builder private deleteAction'), source.indexOf('@Builder private analysisDialog'));
  assert.ok(action.search(/Text\((?:I18n\.t\()?'分析'/) < action.search(/Text\((?:I18n\.t\()?'分享'/));
  assert.ok(action.search(/Text\((?:I18n\.t\()?'分享'/) < action.search(/Text\((?:I18n\.t\()?'删除'/));
  const dialog = source.slice(source.indexOf('@Builder private analysisDialog'), source.indexOf('@Builder private settingsDialog'));
  assert.match(dialog, /alignContent: Alignment\.Center/); assert.match(dialog, /Scroll\(\)/);
  assert.match(dialog, /StoreLayout\.sheetMaxHeight/); assert.match(dialog, /backgroundColor\(this\.colors\(\)\.surface\)/);
  assert.match(dialog, /scrim\)\.onClick\(\(\) => this\.closeAnalysis\(\)/);
  assert.match(dialog, /label: (?:I18n\.t\()?'关闭包分析'/); assert.match(dialog, /this\.downloadIcon\(this\.analysisRow\)/);
  assert.match(dialog, /Text\(field\.key\)\.width\('34%'\)/);
  assert.match(dialog, /Text\(field\.value\)[\s\S]*?textAlign\(TextAlign\.End\)[\s\S]*?copyAnalysisValue\(field\.value\)/);
  assert.doesNotMatch(dialog, /slice\(0,\s*20\)|展开|JSON\.stringify/);
});
