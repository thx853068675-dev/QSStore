import { PackagePresentation } from './PackagePresentation';
import { StorageBudget } from './StorageBudget';
import { fileIo } from '@kit.CoreFileKit';
import { listPackageEntries, extractPackageEntry } from 'libhap_core.so';
import { inspectPackage, PackageIdentity, PackageInspectError, requestedPermissions } from './PackageInspector';

class PreparedApp {
  fingerprint: string = '';
  paths: string[] = [];
  identity: PackageIdentity;
  primary: string = '';
  bytes: number = 0;
  constructor(identity: PackageIdentity) { this.identity = identity; }
}

export class PackageArchive {
  private static prepared: Map<string, PreparedApp> = new Map();
  private static preparing: Map<string, Promise<PreparedApp>> = new Map();

  static release(path: string): void {
    const cached = PackageArchive.prepared.get(path);
    if (cached) PackageArchive.cleanup(cached.paths);
    PackageArchive.prepared.delete(path);
  }

  private static fingerprint(path: string): string {
    const stat = fileIo.statSync(path);
    return stat.size + ':' + stat.mtime + ':' + String(stat.mtimeNs ?? '');
  }

  private static async prepare(path: string): Promise<PreparedApp> {
    const fingerprint = PackageArchive.fingerprint(path);
    const cached = PackageArchive.prepared.get(path);
    if (cached?.fingerprint === fingerprint && cached.paths.every((module: string) => fileIo.accessSync(module))) {
      PackageArchive.prepared.delete(path); PackageArchive.prepared.set(path, cached);
      return cached;
    }
    PackageArchive.release(path);
    const pending = PackageArchive.preparing.get(path);
    if (pending) return pending;
    const task = PackageArchive.prepareNew(path, fingerprint).finally(() => { PackageArchive.preparing.delete(path); });
    PackageArchive.preparing.set(path, task);
    return task;
  }

  private static async prepareNew(path: string, fingerprint: string): Promise<PreparedApp> {
    const paths = await PackageArchive.modules(path);
    try {
      const identities = paths.map((module: string) => inspectPackage(module));
      const primary = identities.findIndex((identity: PackageIdentity) => identity.moduleType === 'entry');
      const index = primary >= 0 ? primary : Math.max(0, identities.findIndex((identity: PackageIdentity) => identity.mainAbility.length > 0));
      const identity = identities[index];
      if (identities.some((other: PackageIdentity, at: number) => other.bundleName !== identity.bundleName ||
        other.versionCode !== identity.versionCode || !other.moduleName ||
        identities.findIndex((candidate: PackageIdentity) => candidate.moduleName === other.moduleName) !== at)) {
        throw new PackageInspectError('APP 模块的应用身份、版本或模块名不一致');
      }
      if (PackageArchive.fingerprint(path) !== fingerprint) throw new PackageInspectError('APP 文件在解析期间发生变化');
      const result = new PreparedApp(identity);
      result.paths = paths; result.primary = paths[index]; result.fingerprint = fingerprint;
      result.bytes = paths.reduce((total: number, module: string) => total + fileIo.statSync(module).size, 0);
      while (PackageArchive.prepared.size > 0 && (PackageArchive.prepared.size >= 2 ||
        Array.from(PackageArchive.prepared.values()).reduce((total: number, item: PreparedApp) => total + item.bytes, 0) + result.bytes > 512 * 1024 * 1024)) PackageArchive.release(Array.from(PackageArchive.prepared.keys())[0]);
      // Large APPs are used once and explicitly released after sign/import; no unbounded retention.
      PackageArchive.prepared.set(path, result);
      return result;
    } catch (error) { PackageArchive.cleanup(paths); throw error as Error; }
  }

  static readonly selector: string = '#qingqi-package=';

  static extension(name: string): string {
    return name.toLowerCase().endsWith('.app') ? '.app' : '.hap';
  }

  /** A URL fragment chooses an entry; HTTP still downloads the original ZIP. */
  static selectedEntry(url: string): string {
    const at = url.indexOf(PackageArchive.selector);
    if (at < 0) return '';
    const name = decodeURIComponent(url.substring(at + PackageArchive.selector.length));
    if (!name || name.length > 1024 || name.startsWith('/') || name.includes('\\') ||
      name.includes('\0') || name.includes(':') || name.split('/').some((part: string) =>
        !part || part === '.' || part === '..') || !/\.(hap|app)$/i.test(name)) {
      throw new PackageInspectError('压缩包内安装文件路径无效');
    }
    return name;
  }

  static async extractSelected(path: string, entry: string, output: string): Promise<string> {
    const entries = listPackageEntries(path);
    const selected = entries.find((row) => row.name === entry);
    if (!selected) throw new PackageInspectError('压缩包中没有所选安装文件');
    await StorageBudget.require(path, selected.size * 2);
    const temporary = output + '.part';
    try {
      await extractPackageEntry(path, entry, temporary);
      // Check the extracted package before promoting it; an extension alone is insufficient.
      await PackageArchive.inspect(temporary, PackageArchive.extension(entry));
      if (fileIo.accessSync(output)) fileIo.unlinkSync(output);
      fileIo.renameSync(temporary, output);
      return output;
    } finally {
      PackageArchive.release(temporary);
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  private static async modules(path: string): Promise<string[]> {
    const entries = listPackageEntries(path);
    if (!entries.length || entries.some((row) => !row.name.toLowerCase().endsWith('.hap'))) {
      throw new PackageInspectError('APP 中没有可安装的 HAP 模块');
    }
    await StorageBudget.require(path, entries.reduce((total: number, row) => total + row.size, 0));
    const paths: string[] = [];
    try {
      for (let i = 0; i < entries.length; i++) {
        const output = path + '.module-' + i + '.hap';
        paths.push(output);
        await extractPackageEntry(path, entries[i].name, output);
      }
      return paths;
    } catch (error) {
      PackageArchive.cleanup(paths);
      throw new PackageInspectError(String(error));
    }
  }

  private static cleanup(paths: string[]): void {
    for (const path of paths) {
      try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) {}
    }
  }

  static async inspect(path: string, extension: string = ''): Promise<PackageIdentity> {
    if ((extension || PackageArchive.extension(path)) !== '.app') return inspectPackage(path);
    return (await PackageArchive.prepare(path)).identity;
  }

  static async permissions(path: string): Promise<string[]> {
    if (PackageArchive.extension(path) !== '.app') return requestedPermissions(path);
    const cached = await PackageArchive.prepare(path);
    const values: string[] = [];
    for (const module of cached.paths) {
      for (const permission of requestedPermissions(module)) {
        if (!values.includes(permission)) values.push(permission);
      }
    }
    return values.sort();
  }

  static workingBytes(path: string): number {
    const size = fileIo.statSync(path).size;
    if (PackageArchive.extension(path) !== '.app') return size * 3;
    return Math.max(size, listPackageEntries(path).reduce((total: number, entry) => total + entry.size, 0)) * 3;
  }

  static async modulePaths(path: string): Promise<string[]> {
    return PackageArchive.extension(path) === '.app' ? (await PackageArchive.prepare(path)).paths.slice() : [path];
  }

  static async icon(path: string): Promise<ArrayBuffer | undefined> {
    if (PackageArchive.extension(path) !== '.app') return PackagePresentation.icon(path);
    const cached = await PackageArchive.prepare(path);
    return PackagePresentation.icon(cached.primary);
  }
}
