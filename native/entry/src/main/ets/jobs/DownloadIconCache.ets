import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { listPackageEntries, extractPackageEntry } from 'libhap_core.so';
import { DownloadLibrary, DownloadedPackage } from './DownloadLibrary';
import { PackageArchive } from './PackageArchive';
import { PackageIdentity } from './PackageInspector';
import { StorageBudget } from './StorageBudget';
import { ForegroundIdle } from './ForegroundIdle';
import { I18n } from '../data/I18n';

class IconRecord { fingerprint: string = ''; data: string = ''; }
class IconValue { fingerprint: string = ''; bytes?: ArrayBuffer; }
class IconCandidate {
  path: string; identity: PackageIdentity;
  constructor(path: string, identity: PackageIdentity) { this.path = path; this.identity = identity; }
}
class IconFile {
  path: string; size: number; mtime: number;
  constructor(path: string, size: number, mtime: number) { this.path = path; this.size = size; this.mtime = mtime; }
}

/** Package-owned icons only. A ZIP receipt's selected bundle is part of every cache key. */
export class DownloadIconCache {
  private static values: Map<string, IconValue> = new Map();
  private static flights: Map<string, Promise<ArrayBuffer | undefined>> = new Map();
  private static writes: Promise<void> = Promise.resolve();
  private static generations: Map<string, number> = new Map();
  private static work: Set<string> = new Set();
  private static readonly MAX_ICON: number = 512 * 1024;
  private static readonly MAX_CACHE: number = 8 * 1024 * 1024;

  static key(row: DownloadedPackage): string {
    return row.id + ':' + row.bundleName;
  }
  private static cacheFileName(row: DownloadedPackage): string {
    if (!/^[a-f0-9]{64}$/.test(row.id) || (row.bundleName &&
      (row.bundleName.length > 128 || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(row.bundleName)))) return '';
    return row.id + '--' + (row.bundleName || 'unknown');
  }
  private static directory(context: common.UIAbilityContext): string { return context.cacheDir + '/download-icons'; }
  private static async checkedDirectory(context: common.UIAbilityContext, create: boolean = false): Promise<string> {
    const dir = DownloadIconCache.directory(context);
    if (create && !fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const stat = await fileIo.lstat(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('图标缓存目录不可用');
    return dir;
  }
  private static async requireNew(path: string): Promise<void> {
    let exists = false;
    try { await fileIo.lstat(path); exists = true; } catch (_) {}
    if (exists) throw new Error(I18n.t('图标临时路径已存在'));
  }
  private static async fingerprint(path: string): Promise<string> {
    const stat = await fileIo.lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink() || !(stat.size > 0)) throw new Error(I18n.t('下载包不可读'));
    return path + ':' + stat.size + ':' + stat.mtime + ':' + String(stat.mtimeNs ?? '');
  }

  static async load(context: common.UIAbilityContext, row: DownloadedPackage): Promise<ArrayBuffer | undefined> {
    const name = DownloadIconCache.cacheFileName(row);
    if (!name) return undefined;
    const scope = context.filesDir + ':';
    const key = scope + DownloadIconCache.key(row);
    const release = DownloadLibrary.reserve(context, row.id);
    try {
      const fingerprint = await DownloadIconCache.fingerprint(row.path);
      const cached = DownloadIconCache.values.get(key);
      if (cached?.fingerprint === fingerprint) return cached.bytes;
      const flightKey = key + ':' + fingerprint;
      const pending = DownloadIconCache.flights.get(flightKey);
      if (pending) return await pending;
      const generation = DownloadIconCache.generations.get(context.filesDir) ?? 0;
      const task = DownloadIconCache.read(context, row, name, fingerprint, generation).then((bytes: ArrayBuffer | undefined) => {
        if ((DownloadIconCache.generations.get(context.filesDir) ?? 0) === generation) {
          const value = new IconValue(); value.fingerprint = fingerprint; value.bytes = bytes;
          DownloadIconCache.values.delete(key); DownloadIconCache.values.set(key, value);
          let size = Array.from(DownloadIconCache.values.values()).reduce((sum: number, icon: IconValue) => sum + (icon.bytes?.byteLength ?? 0), 0);
          while (DownloadIconCache.values.size > 128 || size > DownloadIconCache.MAX_CACHE) {
            const oldest = Array.from(DownloadIconCache.values.keys())[0];
            size -= DownloadIconCache.values.get(oldest)?.bytes?.byteLength ?? 0;
            DownloadIconCache.values.delete(oldest);
          }
        }
        return bytes;
      }).finally(() => { DownloadIconCache.flights.delete(flightKey); });
      DownloadIconCache.flights.set(flightKey, task);
      return await task;
    } catch (_) { DownloadIconCache.values.delete(key); return undefined; }
    finally { release(); }
  }

  private static async read(context: common.UIAbilityContext, row: DownloadedPackage, name: string,
    fingerprint: string, generation: number): Promise<ArrayBuffer | undefined> {
    const dir = DownloadIconCache.directory(context), saved = dir + '/' + name + '.json';
    if (fileIo.accessSync(dir)) await DownloadIconCache.checkedDirectory(context);
    try {
      const stat = await fileIo.lstat(saved);
      if (stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size < 750 * 1024) {
        const record = JSON.parse(await fileIo.readText(saved)) as IconRecord;
        if (record.fingerprint === fingerprint && typeof record.data === 'string' && record.data.length < 700 * 1024) {
          const bytes = new util.Base64Helper().decodeSync(record.data);
          if (bytes.byteLength > 0 && bytes.byteLength <= DownloadIconCache.MAX_ICON) {
            return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
          }
        }
      }
    } catch (_) { /* A missing or cleared icon is regenerated from the retained original. */ }
    await ForegroundIdle.wait();
    const verified = await DownloadLibrary.verify(context, row.id);
    if (verified.bundleName !== row.bundleName || verified.path !== row.path) return undefined;
    await DownloadIconCache.checkedDirectory(context, true);
    const bytes = await DownloadIconCache.extract(context, verified, dir + '/' + name);
    if (!bytes || bytes.byteLength === 0 || bytes.byteLength > DownloadIconCache.MAX_ICON ||
      await DownloadIconCache.fingerprint(verified.path) !== fingerprint) return undefined;
    const record = new IconRecord(); record.fingerprint = fingerprint;
    record.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
    DownloadIconCache.writes = DownloadIconCache.writes.then(async (): Promise<void> => {
      if ((DownloadIconCache.generations.get(context.filesDir) ?? 0) !== generation) return;
      const temporary = saved + '.part';
      try {
        await DownloadIconCache.checkedDirectory(context, true);
        const file = await fileIo.open(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC |
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.NOFOLLOW);
        try {
          const data = new util.TextEncoder().encodeInto(JSON.stringify(record));
          let at = 0;
          while (at < data.byteLength) {
            const count = await fileIo.write(file.fd, data.slice(at).buffer);
            if (count <= 0) throw new Error('图标缓存写入失败');
            at += count;
          }
        } finally { await fileIo.close(file); }
        if ((DownloadIconCache.generations.get(context.filesDir) ?? 0) !== generation) return;
        fileIo.renameSync(temporary, saved);
        await DownloadIconCache.trim(context, saved);
      } catch (_) { /* Cache persistence is optional; the decoded package icon remains usable. */ }
      finally { try { if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary); } catch (_) {} }
    });
    await DownloadIconCache.writes;
    return bytes;
  }

  private static async extract(context: common.UIAbilityContext, row: DownloadedPackage,
    prefix: string): Promise<ArrayBuffer | undefined> {
    const staged: string[] = [];
    const work = prefix + '.work-' + Date.now() + '-' + Math.floor(Math.random() * 1000000);
    DownloadIconCache.work.add(work);
    try {
      const extension = row.name.toLowerCase().endsWith('.app') ? '.app' : row.name.toLowerCase().endsWith('.hap') ? '.hap' : '';
      if (extension === '.hap') {
        try {
          const identity = await PackageArchive.inspect(row.path);
          if (row.bundleName && identity.bundleName !== row.bundleName) return undefined;
          return await PackageArchive.icon(row.path);
        } finally { PackageArchive.release(row.path); }
      }
      if (extension === '.app') {
        await StorageBudget.require(context.cacheDir, row.bytes * 3);
        const path = work + '.app'; staged.push(path);
        await DownloadIconCache.checkedDirectory(context); await DownloadIconCache.requireNew(path);
        await fileIo.copyFile(row.path, path);
        const identity = await PackageArchive.inspect(path);
        if (row.bundleName && identity.bundleName !== row.bundleName) return undefined;
        return await PackageArchive.icon(path);
      }
      if (!row.name.toLowerCase().endsWith('.zip')) return undefined;
      const entries = listPackageEntries(row.path);
      await StorageBudget.require(context.cacheDir, entries.reduce((sum, entry) => sum + entry.size, 0) * 3);
      const candidates: IconCandidate[] = [];
      for (let i = 0; i < entries.length; i++) {
        await ForegroundIdle.wait();
        const path = work + '-' + i + PackageArchive.extension(entries[i].name); staged.push(path);
        try {
          await DownloadIconCache.checkedDirectory(context); await DownloadIconCache.requireNew(path);
          await extractPackageEntry(row.path, entries[i].name, path);
          const identity = await PackageArchive.inspect(path);
          if (!row.bundleName || identity.bundleName === row.bundleName) candidates.push(new IconCandidate(path, identity));
        } catch (_) { /* Invalid neighbors must not become another application's displayed icon. */ }
      }
      if (!candidates.length || new Set(candidates.map((entry: IconCandidate) => entry.identity.bundleName)).size !== 1) return undefined;
      const primary = candidates.filter((entry: IconCandidate) => entry.identity.moduleType === 'entry' || entry.identity.mainAbility.length > 0);
      const chosen = primary.length === 1 ? primary[0] : candidates.length === 1 ? candidates[0] : undefined;
      return chosen ? await PackageArchive.icon(chosen.path) : undefined;
    } finally {
      for (const path of staged) {
        PackageArchive.release(path);
        try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) {}
      }
      DownloadIconCache.work.delete(work);
    }
  }

  private static async trim(context: common.UIAbilityContext, newest: string): Promise<void> {
    const dir = await DownloadIconCache.checkedDirectory(context);
    const names = (await fileIo.listFile(dir)).filter((name: string) => name.endsWith('.json'));
    const files: IconFile[] = [];
    for (const name of names) {
      if (/[\\/]/.test(name)) continue;
      const path = dir + '/' + name;
      try { const stat = await fileIo.lstat(path); if (stat.isFile() && !stat.isSymbolicLink()) files.push(new IconFile(path, stat.size, stat.mtime)); } catch (_) {}
    }
    files.sort((a, b) => a.mtime - b.mtime);
    let size = files.reduce((sum, file) => sum + file.size, 0);
    for (const file of files) {
      if (size <= DownloadIconCache.MAX_CACHE) break;
      if (file.path === newest) continue;
      try { fileIo.unlinkSync(file.path); size -= file.size; } catch (_) {}
    }
  }

  static async size(context: common.UIAbilityContext): Promise<number> {
    const dir = DownloadIconCache.directory(context); let size = 0;
    try {
      await DownloadIconCache.checkedDirectory(context);
      for (const name of await fileIo.listFile(dir)) {
        if (/[\\/]/.test(name)) continue;
        try { const stat = await fileIo.lstat(dir + '/' + name); if (stat.isFile() && !stat.isSymbolicLink()) size += stat.size; } catch (_) {}
      }
    } catch (_) {}
    return size;
  }
  static async clear(context: common.UIAbilityContext): Promise<void> {
    DownloadIconCache.generations.set(context.filesDir, (DownloadIconCache.generations.get(context.filesDir) ?? 0) + 1);
    for (const key of Array.from(DownloadIconCache.values.keys())) if (key.startsWith(context.filesDir + ':')) DownloadIconCache.values.delete(key);
    const dir = DownloadIconCache.directory(context);
    try {
      await DownloadIconCache.checkedDirectory(context);
      for (const name of await fileIo.listFile(dir)) {
        if (/[\\/]/.test(name)) continue;
        const path = dir + '/' + name;
        if (Array.from(DownloadIconCache.work).some((work: string) => path.startsWith(work))) continue;
        try { const stat = await fileIo.lstat(path); if (stat.isFile() && !stat.isSymbolicLink()) fileIo.unlinkSync(path); } catch (_) {}
      }
    } catch (_) {}
  }
}
