import { fileIo } from '@kit.CoreFileKit';
import { listPackageEntries, extractPackageEntry } from 'libhap_core.so';
import { inspectPackage, PackageIdentity, PackageInspectError, iconReference, readIconBytes } from './PackageInspector';

export class PackageArchive {
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
    const temporary = output + '.part';
    try {
      await extractPackageEntry(path, entry, temporary);
      // Check the extracted package before promoting it; an extension alone is insufficient.
      await PackageArchive.inspect(temporary, PackageArchive.extension(entry));
      if (fileIo.accessSync(output)) fileIo.unlinkSync(output);
      fileIo.renameSync(temporary, output);
      return output;
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  private static async modules(path: string): Promise<string[]> {
    const entries = listPackageEntries(path);
    if (!entries.length || entries.some((row) => !row.name.toLowerCase().endsWith('.hap'))) {
      throw new PackageInspectError('APP 中没有可安装的 HAP 模块');
    }
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
    const paths = await PackageArchive.modules(path);
    try {
      const identities = paths.map((module: string) => inspectPackage(module));
      const primary = identities.find((identity: PackageIdentity) => identity.moduleType === 'entry') ??
        identities.find((identity: PackageIdentity) => identity.mainAbility.length > 0) ?? identities[0];
      if (identities.some((identity: PackageIdentity, index: number) =>
        identity.bundleName !== primary.bundleName || identity.versionCode !== primary.versionCode ||
        !identity.moduleName || identities.findIndex((other: PackageIdentity) =>
          other.moduleName === identity.moduleName) !== index)) {
        throw new PackageInspectError('APP 模块的应用身份、版本或模块名不一致');
      }
      return primary;
    } finally { PackageArchive.cleanup(paths); }
  }

  static async icon(path: string): Promise<ArrayBuffer | undefined> {
    if (PackageArchive.extension(path) !== '.app') return readIconBytes(path, iconReference(path));
    const paths = await PackageArchive.modules(path);
    try {
      const primary = paths.find((module: string) => inspectPackage(module).moduleType === 'entry') ??
        paths.find((module: string) => inspectPackage(module).mainAbility.length > 0) ?? paths[0];
      return readIconBytes(primary, iconReference(primary));
    } finally { PackageArchive.cleanup(paths); }
  }
}
