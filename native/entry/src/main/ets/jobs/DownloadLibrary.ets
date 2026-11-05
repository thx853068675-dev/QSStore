import { common } from '@kit.AbilityKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { releaseDisplayVersion } from '../data/DisplayVersion';
import { InstalledAppRegistry } from './InstalledAppRegistry';
import { InstallJob, InstallStage } from './InstallJob';
import { ReleaseUpdate } from './ReleaseUpdate';
import { PublicDownloadDirectory, DownloadDirectoryLocation } from './PublicDownloadDirectory';
import { I18n } from '../data/I18n';

export class DownloadedPackage {
  id: string = '';
  path: string = '';
  name: string = '';
  title: string = '';
  version: string = '';
  bytes: number = 0;
  sha256: string = '';
  createdAt: number = 0;
  appId: number = 0;
  bundleName: string = '';
}

class DownloadReceipt extends DownloadedPackage {
  deletedAt: number = 0;
}

/** Original online packages, separate from disposable signing and download workspaces. */
export class DownloadLibrary {
  private static tails: Map<string, Promise<void>> = new Map();
  private static readers: Map<string, number> = new Map();
  private static readonly extensions: RegExp = /\.(tar\.gz|tar\.bz2|tar\.xz|tar\.zst|hap|app|zip|7z|rar|tar|tgz|gz|bz2|xz|zst|bin)$/i;

  private static async location(context: common.UIAbilityContext): Promise<DownloadDirectoryLocation> {
    const location = await PublicDownloadDirectory.ensure(context);
    const stat = fileIo.lstatSync(location.path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('下载目录不可用');
    return location;
  }

  static async getLocation(context: common.UIAbilityContext): Promise<DownloadDirectoryLocation> {
    let result: DownloadDirectoryLocation | undefined;
    await DownloadLibrary.enqueue(context, async (): Promise<void> => { result = await DownloadLibrary.location(context); });
    if (result === undefined) throw new Error(I18n.t('下载目录不可用'));
    return result;
  }

  static async directory(context: common.UIAbilityContext): Promise<string> {
    return (await DownloadLibrary.getLocation(context)).path;
  }

  private static legacyDirectory(context: common.UIAbilityContext): string | undefined {
    const directory = context.filesDir + '/downloads';
    if (!fileIo.accessSync(directory)) return undefined;
    const stat = fileIo.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('旧下载目录不可用');
    return directory;
  }

  /** Only system-derived public locations may authorize an old receipt's path. */
  private static async publicDirectories(location: DownloadDirectoryLocation): Promise<string[]> {
    const directories: string[] = [location.path];
    for (const candidate of location.knownPaths) {
      if (directories.includes(candidate)) continue;
      try {
        const stat = await fileIo.lstat(candidate);
        if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
        await fileIo.listFile(candidate);
        directories.push(candidate);
      } catch (_) {}
    }
    return directories;
  }

  /** Keep existing private originals manageable when the public location is temporarily unavailable. */
  private static async availableDirectories(context: common.UIAbilityContext, migrate: boolean = true): Promise<string[]> {
    const legacy = DownloadLibrary.legacyDirectory(context);
    let location: DownloadDirectoryLocation;
    try { location = await DownloadLibrary.location(context); }
    catch (error) {
      if (legacy !== undefined) return [legacy];
      throw error as Error;
    }
    const directories = await DownloadLibrary.publicDirectories(location);
    if (legacy !== undefined && !directories.includes(legacy)) directories.push(legacy);
    if (migrate) {
      for (const previous of directories) {
        if (previous === location.path) continue;
        try { await DownloadLibrary.migrateLegacy(context, location.path, previous); } catch (_) {}
      }
    }
    return directories;
  }

  private static receiptDirectory(context: common.UIAbilityContext): string {
    const directory = context.filesDir + '/download-receipts';
    if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory, true);
    const stat = fileIo.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('下载记录目录不可用');
    return directory;
  }

  private static enqueue(context: common.UIAbilityContext, operation: () => Promise<void>): Promise<void> {
    const scope = context.filesDir;
    const previous = DownloadLibrary.tails.get(scope) ?? Promise.resolve();
    const work = previous.then(operation);
    const tail = work.catch(() => {});
    DownloadLibrary.tails.set(scope, tail);
    tail.then(() => {
      if (DownloadLibrary.tails.get(scope) === tail) DownloadLibrary.tails.delete(scope);
    });
    return work;
  }

  /** Export/import callers pin a record until their file copy has finished. */
  static reserve(context: common.UIAbilityContext, id: string): () => void {
    if (!/^[a-f0-9]{64}$/.test(id)) throw new Error(I18n.t('下载记录无效'));
    const key = context.filesDir + ':' + id;
    DownloadLibrary.readers.set(key, (DownloadLibrary.readers.get(key) ?? 0) + 1);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const count = (DownloadLibrary.readers.get(key) ?? 1) - 1;
      if (count > 0) DownloadLibrary.readers.set(key, count);
      else DownloadLibrary.readers.delete(key);
    };
  }

  private static inUse(context: common.UIAbilityContext, id: string): boolean {
    return (DownloadLibrary.readers.get(context.filesDir + ':' + id) ?? 0) > 0;
  }

  private static extension(name: string): string {
    const match = DownloadLibrary.extensions.exec(name);
    return match === null ? '.bin' : '.' + match[1].toLowerCase();
  }

  private static originalName(job: InstallJob): string {
    let name = (job.assetName ?? '').split(' / ')[0];
    if (!DownloadLibrary.extensions.test(name)) {
      const url = (job.sourceUrl ?? '').split('#')[0].split('?')[0];
      try { name = decodeURIComponent(url.substring(url.lastIndexOf('/') + 1)); } catch (_) {}
    }
    name = name.replace(/[\\/\u0000-\u001f\u007f]/g, '_').trim();
    return name || I18n.t('安装包.hap');
  }

  private static archiveName(name: string, id: string): string {
    const extension = DownloadLibrary.extension(name);
    let base = name.replace(/[\\/\u0000-\u001f\u007f]/g, '_').trim();
    if (base.toLowerCase().endsWith(extension)) base = base.slice(0, -extension.length);
    base = Array.from(base).slice(0, 40).join('').replace(/^[. ]+|[. ]+$/g, '') || I18n.t('安装包');
    const encoder = new util.TextEncoder();
    while (encoder.encodeInto(base).length > 120) base = Array.from(base).slice(0, -1).join('');
    return base + '-' + id + extension;
  }

  /** Recognize only library-owned names, including archives made before friendly naming. */
  private static archiveId(name: string): string {
    const original = name.endsWith('.part') ? name.slice(0, -5) : name;
    if (/[\\/\u0000-\u001f\u007f]/.test(original) || !DownloadLibrary.extensions.test(original)) return '';
    const extension = DownloadLibrary.extension(original);
    const base = original.slice(0, -extension.length);
    if (/^[a-f0-9]{64}$/.test(base)) return base;
    const match = /-([a-f0-9]{64})$/.exec(base);
    if (match === null) return '';
    const id = match[1];
    const prefix = base.slice(0, -65);
    return DownloadLibrary.archiveName(prefix + extension, id) === original ? id : '';
  }

  private static validPath(directories: string[], row: DownloadedPackage): boolean {
    return directories.some((directory: string) => row.path === directory + '/' + DownloadLibrary.archiveName(row.name, row.id) ||
      row.path === directory + '/' + row.id + DownloadLibrary.extension(row.path));
  }

  private static async readReceipt(receipts: string, id: string): Promise<DownloadReceipt | undefined> {
    if (!/^[a-f0-9]{64}$/.test(id)) return undefined;
    try {
      const metadata = receipts + '/' + id + '.json';
      const metadataStat = await fileIo.lstat(metadata);
      if (!metadataStat.isFile() || metadataStat.isSymbolicLink() || metadataStat.size > 65536) return undefined;
      const raw = JSON.parse(await fileIo.readText(metadata)) as Record<string, Object>;
      if (raw['id'] !== id || raw['sha256'] !== id || typeof raw['path'] !== 'string') return undefined;
      const row = new DownloadReceipt();
      row.id = id; row.sha256 = id; row.path = String(raw['path']);
      row.name = String(raw['name'] ?? '').replace(/[\\/\u0000-\u001f\u007f]/g, '_');
      row.title = String(raw['title'] ?? row.name); row.version = String(raw['version'] ?? '');
      row.bytes = Number(raw['bytes']) || 0; row.createdAt = Number(raw['createdAt']) || 0;
      row.appId = Number(raw['appId']) || 0; row.bundleName = String(raw['bundleName'] ?? '');
      row.deletedAt = Number(raw['deletedAt']) || 0;
      return row;
    } catch (_) { return undefined; }
  }

  private static async readRecord(directories: string[], receipts: string,
    id: string): Promise<DownloadedPackage | undefined> {
    const row = await DownloadLibrary.readReceipt(receipts, id);
    if (row === undefined || row.deletedAt > 0 || !DownloadLibrary.validPath(directories, row)) return undefined;
    if (!fileIo.accessSync(row.path)) { DownloadLibrary.writeDeleted(receipts, id); return undefined; }
    try {
      const stat = await fileIo.lstat(row.path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) return undefined;
      row.bytes = stat.size;
      return row;
    } catch (_) { return undefined; }
  }

  private static async copyVerified(source: string, target: string, digest: string): Promise<void> {
    const temporary = target + '.part';
    const output = fileIo.openSync(temporary,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      await fileIo.copyFile(source, output.fd);
      const stat = await fileIo.lstat(temporary);
      if (!stat.isFile() || stat.isSymbolicLink() || (await hash.hash(temporary, 'sha256')).toLowerCase() !== digest) {
        throw new Error(I18n.t('原始下载包已变化'));
      }
      fileIo.renameSync(temporary, target);
    } finally {
      fileIo.closeSync(output);
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  private static async removeLegacyCopy(context: common.UIAbilityContext, source: string, digest: string): Promise<void> {
    if (DownloadLibrary.inUse(context, digest) || !fileIo.accessSync(source)) return;
    const stat = await fileIo.lstat(source);
    if (stat.isFile() && !stat.isSymbolicLink() && (await hash.hash(source, 'sha256')).toLowerCase() === digest &&
      !DownloadLibrary.inUse(context, digest)) fileIo.unlinkSync(source);
  }

  /** Publish verified current bytes and a private receipt before removing an old authorized original. */
  private static async migrateLegacy(context: common.UIAbilityContext, directory: string, legacy: string): Promise<void> {
    const files = (await fileIo.listFile(legacy)).filter((name: string) => !name.endsWith('.part') &&
      DownloadLibrary.archiveId(name).length > 0);
    const ids = new Set<string>();
    for (const name of files) ids.add(DownloadLibrary.archiveId(name));
    if (!ids.size) return;
    const receipts = DownloadLibrary.receiptDirectory(context);
    for (const id of ids) {
      try {
        await DownloadLibrary.migrateLegacyRecord(context, directory, legacy, receipts, files, id);
      } catch (_) {
        // One interrupted original must not block migration of unrelated records.
      }
    }
  }

  private static async migrateLegacyRecord(context: common.UIAbilityContext, directory: string, legacy: string,
    receipts: string, files: string[], id: string): Promise<void> {
    const row = await DownloadLibrary.readReceipt(receipts, id);
    if (row === undefined || row.deletedAt > 0 || DownloadLibrary.inUse(context, id)) return;
    if (DownloadLibrary.validPath([directory], row)) {
      const live = await DownloadLibrary.readRecord([directory], receipts, id);
      if (live === undefined || (await hash.hash(live.path, 'sha256')).toLowerCase() !== id) return;
      for (const name of files) if (DownloadLibrary.archiveId(name) === id && !name.endsWith('.part')) {
        await DownloadLibrary.removeLegacyCopy(context, legacy + '/' + name, id);
      }
      return;
    }
    if (!DownloadLibrary.validPath([legacy], row)) return;
    const old = await DownloadLibrary.readRecord([legacy], receipts, id);
    if (old === undefined || (await hash.hash(old.path, 'sha256')).toLowerCase() !== id) return;
    const target = directory + '/' + DownloadLibrary.archiveName(old.name, id);
    let exists = false;
    if (fileIo.accessSync(target)) {
      const stat = await fileIo.lstat(target);
      exists = stat.isFile() && !stat.isSymbolicLink() && (await hash.hash(target, 'sha256')).toLowerCase() === id;
    }
    if (!exists) await DownloadLibrary.copyVerified(old.path, target, id);
    const source = old.path;
    old.path = target;
    DownloadLibrary.writeRecord(receipts, old);
    await DownloadLibrary.removeLegacyCopy(context, source, id);
  }

  private static async deletedAt(receipts: string, id: string): Promise<number> {
    try {
      const path = receipts + '/' + id + '.json';
      const stat = await fileIo.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 65536) return 0;
      const row = JSON.parse(await fileIo.readText(path)) as Record<string, Object>;
      const deletedAt = Number(row['deletedAt']);
      return row['id'] === id && row['sha256'] === id && Number.isFinite(deletedAt) && deletedAt > 0 ? deletedAt : 0;
    } catch (_) { return 0; }
  }

  private static writeDeleted(receipts: string, id: string): void {
    const row = new DownloadReceipt();
    row.id = id; row.sha256 = id; row.deletedAt = Date.now();
    DownloadLibrary.writeRecord(receipts, row);
  }

  private static writeRecord(directory: string, row: DownloadedPackage): void {
    const target = directory + '/' + row.id + '.json';
    const temporary = target + '.part';
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(row));
    const output = fileIo.openSync(temporary,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const written = fileIo.writeSync(output.fd, bytes.slice(offset).buffer);
        if (written <= 0) throw new Error('下载记录写入失败');
        offset += written;
      }
    } finally { fileIo.closeSync(output); }
    fileIo.renameSync(temporary, target);
  }

  static async list(context: common.UIAbilityContext): Promise<DownloadedPackage[]> {
    let rows: DownloadedPackage[] = [];
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      const directories = await DownloadLibrary.availableDirectories(context);
      const receipts = DownloadLibrary.receiptDirectory(context);
      for (const name of await fileIo.listFile(receipts)) {
        if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
        const row = await DownloadLibrary.readRecord(directories, receipts, name.slice(0, -5));
        if (row !== undefined) rows.push(row);
      }
      rows = rows.sort((left: DownloadedPackage, right: DownloadedPackage) => right.createdAt - left.createdAt);
    });
    return rows;
  }

  /** Restore identical retained bytes into the private workspace, never a signed artifact. */
  static async restore(context: common.UIAbilityContext, job: InstallJob): Promise<string> {
    const destination = job.cachePath;
    const root = context.filesDir + '/install-jobs/';
    if (!/^https:\/\//i.test(job.sourceUrl ?? '') || !destination.startsWith(root) ||
      destination.substring(root.length).includes('/') || /[\\\u0000-\u001f]/.test(destination) ||
      destination === job.signedPath) return '';
    // A version label or filename alone cannot identify a same-version replacement.
    const digests = [job.expectedSha256, job.catalogSha256].map((value: string) => (value ?? '').toLowerCase())
      .filter((value: string, index: number, values: string[]) => /^[a-f0-9]{64}$/.test(value) && values.indexOf(value) === index);
    if (digests.length === 0) return '';
    let restored = '';
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      const directory = await fileIo.lstat(root.slice(0, -1));
      if (!directory.isDirectory() || directory.isSymbolicLink()) return;
      const directories = await DownloadLibrary.availableDirectories(context, false);
      const receipts = DownloadLibrary.receiptDirectory(context);
      for (const digest of digests) {
        const row = await DownloadLibrary.readRecord(directories, receipts, digest);
        if (row === undefined || (job.catalogBundleName && row.bundleName && job.catalogBundleName !== row.bundleName)) continue;
        const release = DownloadLibrary.reserve(context, digest);
        try {
          await DownloadLibrary.copyVerified(row.path, destination, digest);
          restored = digest;
          return;
        } catch (_) { /* Missing or externally edited public files fall back to a new download. */ }
        finally { release(); }
      }
    });
    return restored;
  }

  /** Commit both bytes and a receipt before the installation workspace can be pruned. */
  static keep(context: common.UIAbilityContext, job: InstallJob): Promise<void> {
    const snapshot = InstallJob.displayCopy(job);
    return DownloadLibrary.enqueue(context, async (): Promise<void> => {
      if ((snapshot.stage !== InstallStage.INSTALLED && snapshot.stage !== InstallStage.SKIPPED) || !/^https:\/\//i.test(snapshot.sourceUrl ?? '') ||
        !snapshot.cachePath) return;
      const source = snapshot.cachePath;
      const sourceDirectory = context.filesDir + '/install-jobs/';
      if (!source.startsWith(sourceDirectory) || source.substring(sourceDirectory.length).includes('/') ||
        /[\\\u0000-\u001f]/.test(source) || source === snapshot.signedPath) throw new Error(I18n.t('原始下载包路径无效'));
      if (!fileIo.accessSync(source)) return;
      const sourceRoot = await fileIo.lstat(sourceDirectory.slice(0, -1));
      if (!sourceRoot.isDirectory() || sourceRoot.isSymbolicLink()) throw new Error('原始下载目录不可用');
      const sourceStat = await fileIo.lstat(source);
      if (!sourceStat.isFile() || sourceStat.isSymbolicLink() || sourceStat.size <= 0) throw new Error(I18n.t('原始下载包不可用'));
      const location = await DownloadLibrary.location(context);
      const directory = location.path;
      const legacy = DownloadLibrary.legacyDirectory(context);
      const directories = await DownloadLibrary.publicDirectories(location);
      if (legacy !== undefined && !directories.includes(legacy)) directories.push(legacy);
      const receipts = DownloadLibrary.receiptDirectory(context);
      const name = DownloadLibrary.originalName(snapshot);
      let digest = (snapshot.expectedSha256 ?? '').toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(digest)) digest = (await hash.hash(source, 'sha256')).toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error(I18n.t('原始下载包摘要无效'));
      const completedAt = ReleaseUpdate.completedAt(snapshot);
      if (completedAt <= await DownloadLibrary.deletedAt(receipts, digest)) return;
      const previous = await DownloadLibrary.readRecord(directories, receipts, digest);
      // A live receipt whose file disappeared is an external user deletion too.
      if (completedAt <= await DownloadLibrary.deletedAt(receipts, digest)) return;
      const target = previous !== undefined && DownloadLibrary.validPath([directory], previous) ? previous.path :
        directory + '/' + DownloadLibrary.archiveName(name, digest);
      const validPrevious = previous !== undefined && previous.path === target && previous.bytes === sourceStat.size &&
        (await hash.hash(target, 'sha256')).toLowerCase() === digest;
      if (!validPrevious) {
        await DownloadLibrary.copyVerified(source, target, digest);
      }
      const row = new DownloadedPackage();
      row.id = digest; row.sha256 = digest; row.path = target;
      row.name = previous !== undefined && previous.path === target ? previous.name : name;
      row.title = InstalledAppRegistry.displayName(snapshot.bundleName) || previous?.title || name;
      row.version = releaseDisplayVersion(snapshot.releaseName ?? '', snapshot.releaseTag ?? '',
        snapshot.versionName ?? '', name, snapshot.versionCode);
      row.bytes = sourceStat.size; row.createdAt = previous?.createdAt ?? snapshot.updatedAt;
      for (const mark of snapshot.stageHistory ?? []) if (mark.stage === InstallStage.INSTALLED) {
        if (previous === undefined) row.createdAt = mark.at;
      }
      if (!(row.createdAt > 0)) row.createdAt = Date.now();
      row.appId = snapshot.appId; row.bundleName = snapshot.bundleName;
      DownloadLibrary.writeRecord(receipts, row);
      if (previous !== undefined && previous.path !== target &&
        DownloadLibrary.validPath(directories.filter((path: string) => path !== directory), previous)) {
        await DownloadLibrary.removeLegacyCopy(context, previous.path, digest);
      }
    });
  }

  /** Clear only this successful online installation's original, leaving busy readers retryable. */
  static async discardCompleted(context: common.UIAbilityContext, job: InstallJob,
    allowed: () => boolean = (): boolean => true, preserveBefore: number = 0): Promise<boolean> {
    const snapshot = InstallJob.displayCopy(job);
    let completed = false;
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      if ((snapshot.stage !== InstallStage.INSTALLED && snapshot.stage !== InstallStage.SKIPPED) || !/^https:\/\//i.test(snapshot.sourceUrl ?? '') ||
        !snapshot.cachePath || !allowed()) return;
      const source = snapshot.cachePath;
      const prefix = context.filesDir + '/install-jobs/';
      if (!source.startsWith(prefix) || source.substring(prefix.length).includes('/') ||
        /[\\\u0000-\u001f]/.test(source) || source === snapshot.signedPath) throw new Error(I18n.t('原始下载包路径无效'));
      if (!fileIo.accessSync(source)) { completed = allowed(); return; }
      const root = await fileIo.lstat(prefix.slice(0, -1));
      if (!root.isDirectory() || root.isSymbolicLink()) throw new Error('原始下载目录不可用');
      const stat = await fileIo.lstat(source);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) throw new Error(I18n.t('原始下载包不可用'));
      const digest = (await hash.hash(source, 'sha256')).toLowerCase();
      const expected = (snapshot.expectedSha256 ?? '').toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(digest) || (/^[a-f0-9]{64}$/.test(expected) && expected !== digest)) {
        throw new Error(I18n.t('原始下载包已变化'));
      }
      if (!allowed() || DownloadLibrary.inUse(context, digest)) return;
      const directories = await DownloadLibrary.availableDirectories(context, false);
      const receipts = DownloadLibrary.receiptDirectory(context);
      const row = await DownloadLibrary.readReceipt(receipts, digest);
      if (row !== undefined && row.deletedAt <= 0 && !DownloadLibrary.validPath(directories, row)) {
        throw new Error(I18n.t('原包所在目录暂不可清理'));
      }
      if (row !== undefined && row.deletedAt <= 0 && preserveBefore > 0 && row.createdAt < preserveBefore) {
        const retained = await DownloadLibrary.readRecord(directories, receipts, digest);
        if (retained === undefined || (await hash.hash(retained.path, 'sha256')).toLowerCase() !== digest) {
          throw new Error(I18n.t('已保留的原始下载包已变化'));
        }
        // Enabling cleanup never retrospectively deletes an older retained download.
        completed = allowed() && !DownloadLibrary.inUse(context, digest);
        return;
      }
      await DownloadLibrary.removeFiles(context, directories, receipts, digest, allowed);
      completed = allowed() && !DownloadLibrary.inUse(context, digest);
    });
    return completed;
  }

  /** User-accessible packages can be edited outside the app; verify before exporting/reusing them. */
  static async verify(context: common.UIAbilityContext, id: string): Promise<DownloadedPackage> {
    let result: DownloadedPackage | undefined;
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      const row = await DownloadLibrary.readRecord(await DownloadLibrary.availableDirectories(context),
        DownloadLibrary.receiptDirectory(context), id);
      if (row === undefined || (await hash.hash(row.path, 'sha256')).toLowerCase() !== row.sha256) {
        throw new Error(I18n.t('下载文件已删除或已变化，请重新下载'));
      }
      result = row;
    });
    if (result === undefined) throw new Error(I18n.t('下载记录无效'));
    return result;
  }

  private static async removeFiles(context: common.UIAbilityContext, directories: string[],
    receipts: string, id: string, allowed: () => boolean = (): boolean => true): Promise<boolean> {
    if (!allowed() || DownloadLibrary.inUse(context, id)) {
      return false;
    }
    const row = await DownloadLibrary.readReceipt(receipts, id);
    if (row !== undefined && row.deletedAt <= 0 && !DownloadLibrary.validPath(directories, row)) return false;
    let removed = false;
    // Delete metadata last: a failed file deletion remains visible and retryable.
    for (const directory of directories) {
      const names = (await fileIo.listFile(directory)).filter((name: string) => DownloadLibrary.archiveId(name) === id);
      for (const name of names) {
        const path = directory + '/' + name;
        const stat = await fileIo.lstat(path);
        if (!stat.isFile() || stat.isSymbolicLink()) continue;
        if (!allowed() || DownloadLibrary.inUse(context, id)) return removed;
        fileIo.unlinkSync(path);
        if (!name.endsWith('.part')) removed = true;
      }
    }
    if (allowed() && !DownloadLibrary.inUse(context, id)) DownloadLibrary.writeDeleted(receipts, id);
    return removed;
  }

  static async remove(context: common.UIAbilityContext, id: string): Promise<boolean> {
    if (!/^[a-f0-9]{64}$/.test(id)) return Promise.reject(new Error(I18n.t('下载记录无效')));
    let removed = false;
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      removed = await DownloadLibrary.removeFiles(context, await DownloadLibrary.availableDirectories(context, false),
        DownloadLibrary.receiptDirectory(context), id);
    });
    return removed;
  }

  static async clear(context: common.UIAbilityContext): Promise<number> {
    let removed = 0;
    await DownloadLibrary.enqueue(context, async (): Promise<void> => {
      const directories = await DownloadLibrary.availableDirectories(context, false);
      const receipts = DownloadLibrary.receiptDirectory(context);
      const ids = new Set<string>();
      for (const directory of directories) {
        for (const name of await fileIo.listFile(directory)) {
          const id = DownloadLibrary.archiveId(name);
          if (id) ids.add(id);
        }
      }
      for (const name of await fileIo.listFile(receipts)) if (/^[a-f0-9]{64}\.json$/.test(name)) ids.add(name.slice(0, -5));
      for (const id of ids) if (await DownloadLibrary.removeFiles(context, directories, receipts, id)) removed++;
    });
    return removed;
  }
}
