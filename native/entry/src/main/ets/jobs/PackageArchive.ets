import { PackagePresentation } from './PackagePresentation';
import { StorageBudget } from './StorageBudget';
import { fileIo, hash } from '@kit.CoreFileKit';
import { listPackageEntries, extractPackageEntry, readModuleJson } from 'libhap_core.so';
import { inspectPackage, PackageIdentity, PackageInspectError, requestedPermissions } from './PackageInspector';
import { I18n } from '../data/I18n';

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
        throw new PackageInspectError(I18n.t('APP 模块的应用身份、版本或模块名不一致'));
      }
      // Feature-module targets do not decide which devices can launch the APP.
      // Several entry modules may target different devices; any missing entry
      // declaration makes that APP unknown. Without an entry, only agreement
      // across every module provides a usable declaration.
      identity.deviceTypes = PackageArchive.deviceTypes(identities);
      if (PackageArchive.fingerprint(path) !== fingerprint) throw new PackageInspectError(I18n.t('APP 文件在解析期间发生变化'));
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

  private static deviceTypes(identities: PackageIdentity[]): string[] {
    const entries = identities.filter((identity: PackageIdentity) => identity.moduleType === 'entry');
    const relevant = entries.length > 0 ? entries : identities;
    if (relevant.some((identity: PackageIdentity) => identity.deviceTypes.length === 0)) return [];
    if (entries.length === 0 && relevant.some((identity: PackageIdentity) =>
      JSON.stringify(identity.deviceTypes) !== JSON.stringify(relevant[0].deviceTypes))) return [];
    const types: string[] = [];
    for (const identity of relevant) {
      for (const type of identity.deviceTypes) if (!types.includes(type)) types.push(type);
    }
    return types.sort();
  }

  static extension(name: string): string {
    return name.toLowerCase().endsWith('.app') ? '.app' : '.hap';
  }

  /** A published APP may be renamed .hap; a real HAP can itself contain worker HAPs. */
  static async installablePath(path: string, appOutput: string, expectedSha256: string = ''): Promise<string> {
    if (PackageArchive.extension(path) === '.app') return path;
    try { readModuleJson(path); return path; }
    catch (error) {
      // Only a missing root manifest permits APP detection. Corrupt manifests stay errors.
      if (!String(error).includes('HAP entry is missing: module.json')) throw error as Error;
    }
    await PackageArchive.inspect(path, '.app');
    const digest = /^[a-f0-9]{64}$/i.test(expectedSha256) ? expectedSha256.toLowerCase() :
      (await hash.hash(path, 'sha256')).toLowerCase();
    await StorageBudget.require(path, fileIo.statSync(path).size);
    const temporary = appOutput + '.part';
    try {
      await fileIo.copyFile(path, temporary);
      if ((await hash.hash(temporary, 'sha256')).toLowerCase() !== digest) {
        throw new PackageInspectError(I18n.t('APP 原包在准备期间发生变化'));
      }
      PackageArchive.release(appOutput);
      fileIo.renameSync(temporary, appOutput);
      return appOutput;
    } finally {
      PackageArchive.release(path);
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  /** A URL fragment chooses an entry; HTTP still downloads the original ZIP. */
  static selectedEntry(url: string): string {
    const at = url.indexOf(PackageArchive.selector);
    if (at < 0) return '';
    const name = decodeURIComponent(url.substring(at + PackageArchive.selector.length));
    if (!name || name.length > 1024 || name.startsWith('/') || name.includes('\\') ||
      name.includes('\0') || name.includes(':') || name.split('/').some((part: string) =>
        !part || part === '.' || part === '..') || !/\.(hap|app)$/i.test(name)) {
      throw new PackageInspectError(I18n.t('压缩包内安装文件路径无效'));
    }
    return name;
  }

  static async extractSelected(path: string, entry: string, output: string): Promise<string> {
    const entries = listPackageEntries(path);
    const selected = entries.find((row) => row.name === entry);
    if (!selected) throw new PackageInspectError(I18n.t('压缩包中没有所选安装文件'));
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
    const entries = listPackageEntries(path, true);
    if (!entries.length || entries.some((row) => !/\.(hap|hsp)$/i.test(row.name))) {
      throw new PackageInspectError(I18n.t('APP 中没有可安装的 HAP 模块'));
    }
    await StorageBudget.require(path, entries.reduce((total: number, row) => total + row.size, 0));
    const paths: string[] = [];
    try {
      for (let i = 0; i < entries.length; i++) {
        const output = path + '.module-' + i + (entries[i].name.toLowerCase().endsWith('.hsp') ? '.hsp' : '.hap');
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
    return Math.max(size, listPackageEntries(path, true).reduce((total: number, entry) => total + entry.size, 0)) * 3;
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
