import { common } from '@kit.AbilityKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { extractInstallArchive, readModuleJson, readPackInfo, hasSigningBlock, ImportedArchiveEntry } from 'libhap_core.so';
import { InspectionField, InspectionSection } from '../data/InstalledInspection';
import { DownloadLibrary, DownloadedPackage } from './DownloadLibrary';
import { PackageArchive } from './PackageArchive';
import { inspectPackage, requestedPermissions } from './PackageInspector';
import { StorageBudget } from './StorageBudget';
import { ForegroundIdle } from './ForegroundIdle';
import { I18n } from '../data/I18n';

/** Read original package facts, never catalog release labels or signature validity claims. */
export class DownloadAnalysis {
  private static serial: number = 0;
  private static readonly limit: number = 2 * 1024 * 1024 * 1024;

  private static field(section: InspectionSection, name: string, value: string): void {
    if (!value.trim()) return;
    const field = new InspectionField(); field.key = name; field.label = name; field.value = value;
    section.fields.push(field);
  }

  private static text(value: Object | undefined): string {
    if (typeof value === 'string') return value.trim();
    if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    return '';
  }

  private static object(value: Object | undefined): Record<string, Object> {
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : {};
  }

  private static size(bytes: number): string {
    const units = ['B', 'KB', 'MB', 'GB']; let value = bytes, at = 0;
    while (value >= 1024 && at < units.length - 1) { value /= 1024; at++; }
    return (at === 0 ? String(bytes) : value.toFixed(1).replace(/\.0$/, '')) + ' ' + units[at];
  }

  private static fingerprint(stat: fileIo.Stat): string {
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > DownloadAnalysis.limit) {
      throw new Error(I18n.t('安装包不是有效文件或超过 2 GB'));
    }
    return stat.size + ':' + stat.mtime + ':' + stat.ctime + ':' + String(stat.mtimeNs ?? '') + ':' + String(stat.ctimeNs ?? '');
  }

  private static workspace(context: common.UIAbilityContext): string {
    const cache = fileIo.lstatSync(context.cacheDir);
    if (!cache.isDirectory() || cache.isSymbolicLink()) throw new Error('临时目录不可用');
    const base = context.cacheDir + '/download-analysis';
    if (!fileIo.accessSync(base)) fileIo.mkdirSync(base);
    const stat = fileIo.lstatSync(base);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('临时目录不可用');
    let work: string;
    do { work = base + '/analysis-' + Date.now() + '-' + (++DownloadAnalysis.serial); } while (fileIo.accessSync(work));
    fileIo.mkdirSync(work);
    return work;
  }

  private static extension(name: string): string {
    const match = /\.(hap|app|zip|7z|rar|tar|gz|tgz|bz2|tbz|tbz2|xz|txz|lzma)$/i.exec(name);
    if (match === null) throw new Error(I18n.t('暂不支持分析这种安装包格式'));
    return '.' + match[1].toLowerCase();
  }

  private static metadata(name: string, bytes: number, digest: string): InspectionSection {
    const result = new InspectionSection(); result.name = name;
    DownloadAnalysis.field(result, I18n.t('文件名'), name);
    DownloadAnalysis.field(result, I18n.t('文件大小'), DownloadAnalysis.size(bytes));
    DownloadAnalysis.field(result, 'SHA-256', digest);
    return result;
  }

  private static moduleValues(manifests: Record<string, Object>[], packs: Record<string, Object>[], key: string,
    fallback: string): string {
    const rows: string[] = [], values: string[] = [];
    manifests.forEach((manifest: Record<string, Object>, at: number) => {
      const app = DownloadAnalysis.object(manifest['app']);
      const packApp = DownloadAnalysis.object(DownloadAnalysis.object(packs[at]['summary'])['app']);
      const api = DownloadAnalysis.object(packApp['apiVersion']);
      const value = DownloadAnalysis.text(app[key]) || DownloadAnalysis.text(api[fallback]);
      if (!value) return;
      const module = DownloadAnalysis.object(manifest['module']);
      rows.push((DownloadAnalysis.text(module['name']) || String(at + 1)) + ': ' + value);
      if (!values.includes(value)) values.push(value);
    });
    return values.length === 1 ? values[0] : rows.join(I18n.t('；'));
  }

  private static async package(path: string, name: string, bytes: number, digest: string): Promise<InspectionSection> {
    const result = DownloadAnalysis.metadata(name, bytes, digest);
    try {
      await ForegroundIdle.wait();
      const paths = await PackageArchive.modulePaths(path);
      // PackageArchive has a shared bounded APP cache. Consume all paths
      // synchronously before any further await, then release this private APP.
      const manifests = paths.map((module: string) => DownloadAnalysis.object(JSON.parse(readModuleJson(module)) as Object));
      const packs = paths.map((module: string) => {
        const text = readPackInfo(module); return text ? DownloadAnalysis.object(JSON.parse(text) as Object) : {};
      });
      const primary = manifests.findIndex((manifest: Record<string, Object>) =>
        DownloadAnalysis.object(manifest['module'])['type'] === 'entry');
      const index = primary >= 0 ? primary : Math.max(0, manifests.findIndex((manifest: Record<string, Object>) =>
        !!DownloadAnalysis.object(manifest['module'])['mainElement']));
      const identity = inspectPackage(paths[index]);
      result.name = identity.displayName || identity.bundleName || name;
      DownloadAnalysis.field(result, I18n.t('应用名'), identity.displayName);
      DownloadAnalysis.field(result, I18n.t('包名'), identity.bundleName);
      DownloadAnalysis.field(result, I18n.t('包内版本'), identity.versionName);
      DownloadAnalysis.field(result, I18n.t('内部编号'), String(identity.versionCode));
      DownloadAnalysis.field(result, I18n.t('最低 API'), DownloadAnalysis.moduleValues(manifests, packs, 'minAPIVersion', 'compatible'));
      DownloadAnalysis.field(result, I18n.t('目标 API'), DownloadAnalysis.moduleValues(manifests, packs, 'targetAPIVersion', 'target'));
      const devices: string[] = [], modules: string[] = [], permissions: string[] = [], signatures: string[] = [];
      manifests.forEach((manifest: Record<string, Object>, at: number) => {
        const module = DownloadAnalysis.object(manifest['module']);
        const moduleName = DownloadAnalysis.text(module['name']); if (moduleName) modules.push(moduleName);
        const types = module['deviceTypes'];
        if (Array.isArray(types)) types.forEach((value: Object) => {
          const device = DownloadAnalysis.text(value); if (device && !devices.includes(device)) devices.push(device);
        });
        for (const permission of requestedPermissions(paths[at])) if (!permissions.includes(permission)) permissions.push(permission);
        signatures.push((moduleName || String(at + 1)) + ': ' + (hasSigningBlock(paths[at]) ? I18n.t('已检出（未验签）') : I18n.t('未检出')));
      });
      DownloadAnalysis.field(result, I18n.t('设备类型'), devices.join(I18n.t('、')));
      if (path.toLowerCase().endsWith('.app')) {
        DownloadAnalysis.field(result, '模块数', String(paths.length));
        DownloadAnalysis.field(result, I18n.t('模块'), modules.join(I18n.t('、')));
        DownloadAnalysis.field(result, I18n.t('入口模块'), identity.moduleName);
        signatures.unshift(I18n.t('外包: ') + (hasSigningBlock(path) ? I18n.t('已检出（未验签）') : I18n.t('未检出')));
      } else DownloadAnalysis.field(result, I18n.t('模块'), identity.moduleName);
      DownloadAnalysis.field(result, I18n.t('主入口'), identity.mainAbility);
      DownloadAnalysis.field(result, I18n.t('权限'), permissions.sort().join('\n'));
      DownloadAnalysis.field(result, I18n.t('签名块'), paths.length === 1 && !path.toLowerCase().endsWith('.app') ?
        signatures[0].substring(signatures[0].indexOf(': ') + 2) : signatures.join('\n'));
      return result;
    } finally { if (path.toLowerCase().endsWith('.app')) PackageArchive.release(path); }
  }

  private static safeEntry(work: string, entry: ImportedArchiveEntry, index: number): void {
    if (!entry.name || entry.name.length > 1024 || /[\\:\u0000-\u001f\u007f]/.test(entry.name) ||
      entry.name.split('/').some((part: string) => !part || part === '.' || part === '..') ||
      !/\.(hap|app)$/i.test(entry.name) ||
      entry.path !== work + '/member-' + index + PackageArchive.extension(entry.name)) {
      throw new Error(I18n.t('压缩包安装文件路径无效'));
    }
    const stat = fileIo.lstatSync(entry.path);
    DownloadAnalysis.fingerprint(stat);
    if (stat.size !== entry.size) throw new Error(I18n.t('压缩包安装文件大小不一致'));
  }

  static async read(context: common.UIAbilityContext, row: DownloadedPackage): Promise<InspectionSection[]> {
    const release = DownloadLibrary.reserve(context, row.id); let work = '';
    try {
      await ForegroundIdle.wait();
      const source = await DownloadLibrary.verify(context, row.id);
      if (source.id !== row.id || source.sha256 !== row.id) throw new Error(I18n.t('下载记录不匹配'));
      const stat = fileIo.lstatSync(source.path), original = DownloadAnalysis.fingerprint(stat);
      const extension = DownloadAnalysis.extension(source.name);
      await StorageBudget.require(context.cacheDir, stat.size * 2);
      work = DownloadAnalysis.workspace(context);
      const snapshot = work + '/source' + extension;
      const file = fileIo.openSync(source.path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      try {
        if (DownloadAnalysis.fingerprint(fileIo.statSync(file.fd)) !== original) throw new Error('安装包已变化，请重新分析');
        await fileIo.copyFile(file.fd, snapshot);
      } finally { fileIo.closeSync(file); }
      if ((await hash.hash(snapshot, 'sha256')).toLowerCase() !== source.sha256) throw new Error(I18n.t('安装包已变化，请重新分析'));
      let sections: InspectionSection[];
      if (extension === '.hap' || extension === '.app') {
        sections = [await DownloadAnalysis.package(snapshot, source.name, stat.size, source.sha256)];
      } else {
        const entries = await extractInstallArchive(snapshot, work + '/member', source.name);
        if (!entries.length || entries.length > 32) throw new Error(I18n.t('压缩包安装文件数量无效（上限 32 个）'));
        entries.forEach((entry: ImportedArchiveEntry, index: number) => DownloadAnalysis.safeEntry(work, entry, index));
        const container = DownloadAnalysis.metadata(source.name, stat.size, source.sha256);
        container.name = I18n.t('压缩包'); DownloadAnalysis.field(container, I18n.t('安装包数量'), String(entries.length));
        sections = [container];
        for (const entry of entries) {
          try {
            const digest = (await hash.hash(entry.path, 'sha256')).toLowerCase();
            sections.push(await DownloadAnalysis.package(entry.path, entry.name, entry.size, digest));
          } catch (error) {
            const failed = DownloadAnalysis.metadata(entry.name, entry.size, '');
            DownloadAnalysis.field(failed, I18n.t('解析错误'), String(error).substring(0, 512));
            sections.push(failed);
          }
        }
      }
      if (DownloadAnalysis.fingerprint(fileIo.lstatSync(source.path)) !== original) throw new Error('安装包已变化，请重新分析');
      return sections;
    } finally {
      try { if (work && fileIo.accessSync(work)) fileIo.rmdirSync(work); } catch (_) {}
      release();
    }
  }
}
