import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { rewriteArchive } from 'libhap_core.so';

/** Stream new archives through the existing native ZIP writer on its worker thread. */
export class PackageAssembly {
  // One stored pack.info containing {}. It MUST be replaced by caller metadata.
  // Readers keep rejecting empty ZIPs; assembly does not relax their validation.
  private static readonly seed: string = 'UEsDBBQAAAAAAGWcVF1Dv6ajAgAAAAIAAAAJAAAAcGFjay5pbmZve31QSwECFAMUAAAAAABlnFRdQ7+mowIAAAACAAAACQAAAAAAAAAAAAAAgAEAAAAAcGFjay5pbmZvUEsFBgAAAAABAAEANwAAACkAAAAAAA==';
  private static sequence: number = 0;

  static async write(directory: string, output: string, names: string[], paths: string[]): Promise<void> {
    const root = await fileIo.lstat(directory);
    if (!root.isDirectory() || root.isSymbolicLink() || names.length !== paths.length || !names.length || names.length > 33 ||
      !names.includes('pack.info') || new Set(names).size !== names.length ||
      !output.startsWith(directory + '/') || output.substring(directory.length + 1).includes('/') ||
      !/\.(hap|app|hsp)$/.test(output) || paths.includes(output)) throw new Error('安装包封装路径无效');
    let total = 0;
    for (let at = 0; at < paths.length; at++) {
      const path = paths[at], relative = path.substring(directory.length + 1);
      if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,255}$/.test(names[at]) || names[at] === '.' || names[at] === '..' ||
        !path.startsWith(directory + '/') || /[\\\u0000-\u001f\u007f]/.test(relative) ||
        relative.split('/').some((part: string) => !part || part === '.' || part === '..')) throw new Error('安装包封装成员无效');
      const stat = await fileIo.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) throw new Error('安装包封装成员不可读');
      total += stat.size;
      if (total > 2 * 1024 * 1024 * 1024) throw new Error('安装包总量超过 2 GB');
    }
    const template = directory + '/.assembly-' + (++PackageAssembly.sequence) + '.zip';
    const bytes = new util.Base64Helper().decodeSync(PackageAssembly.seed);
    try {
      const file = await fileIo.open(template, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC | fileIo.OpenMode.NOFOLLOW);
      try { await fileIo.write(file.fd, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer); }
      finally { await fileIo.close(file); }
      await rewriteArchive(template, output, names, paths);
    } finally { try { await fileIo.unlink(template); } catch (_) {} }
  }
}
