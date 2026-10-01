import { common } from '@kit.AbilityKit';
import { fileIo, hash, picker } from '@kit.CoreFileKit';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { PackageArchive } from './PackageArchive';
import { listPackageEntries } from 'libhap_core.so';

// Copies a picker URI into the app sandbox before the temporary grant expires.
// The source is never modified and the working file is promoted only after
// integrity calculation and bounded HAP manifest inspection.
export class LocalImport {
  /** Selection copies and inspects the HAP, but never creates an install task. */
  static async pickPreviews(context: common.UIAbilityContext): Promise<InstallJob[]> {
    const chooser = new picker.DocumentViewPicker(context);
    const selection = await chooser.select({
      fileSuffixFilters: ['HarmonyOS 安装包|.hap,.app,.zip'],
      maxSelectNumber: 1
    });
    if (selection.length !== 1) throw new Error('未选择安装文件');

    const dir = context.cacheDir + '/local-hap-previews';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const temporary = dir + '/local-' + Date.now() + '-' +
      Math.floor(Math.random() * 1000000) + '.part';
    const previews: InstallJob[] = [];
    const staged: string[] = [];
    try {
      const source = fileIo.openSync(selection[0], fileIo.OpenMode.READ_ONLY);
      try { await fileIo.copyFile(source.fd, temporary); }
      finally { fileIo.closeSync(source); }
      const size = fileIo.statSync(temporary).size;
      if (size <= 0 || size > 2 * 1024 * 1024 * 1024) throw new Error('安装文件大小无效（上限 2 GB）');
      const decoded = decodeURIComponent(selection[0].split('?')[0]);
      const filename = decoded.substring(decoded.lastIndexOf('/') + 1);
      if (/\.zip$/i.test(filename)) {
        const entries = listPackageEntries(temporary);
        if (!entries.length) throw new Error('ZIP 中没有找到 APP 或 HAP 安装包');
        let invalid = 0;
        for (let i = 0; i < entries.length; i++) {
          const output = temporary.replace(/\.part$/, '-' + i + PackageArchive.extension(entries[i].name));
          staged.push(output);
          try {
            await PackageArchive.extractSelected(temporary, entries[i].name, output);
            previews.push(await LocalImport.preview(output, entries[i].name));
          } catch (_) {
            invalid++;
            if (fileIo.accessSync(output)) fileIo.unlinkSync(output);
          }
        }
        if (!previews.length) throw new Error('ZIP 中的 ' + invalid + ' 个安装包均无效');
      } else {
        if (!/\.(hap|app)$/i.test(filename)) throw new Error('请选择 HAP、APP 或 ZIP 文件');
        const output = temporary.replace(/\.part$/, PackageArchive.extension(filename));
        staged.push(output);
        fileIo.renameSync(temporary, output);
        previews.push(await LocalImport.preview(output, filename));
      }
      return previews;
    } catch (error) {
      for (const path of staged) {
        if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      }
      throw new Error(String(error));
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  private static async preview(path: string, name: string): Promise<InstallJob> {
    const sha256 = (await hash.hash(path, 'sha256')).toLowerCase();
    const identity = await PackageArchive.inspect(path);
    const job = InstallJob.create('local:' + sha256, 0, name, 'local', sha256);
    job.cachePath = path;
    job.bundleName = identity.bundleName;
    job.versionCode = identity.versionCode;
    job.versionName = identity.versionName;
    job.moduleName = identity.moduleName;
    job.mainAbility = identity.mainAbility;
    job.stage = InstallStage.PACKAGE_INSPECTED;
    return job;
  }

  static async pickPreview(context: common.UIAbilityContext): Promise<InstallJob> {
    const previews = await LocalImport.pickPreviews(context);
    if (previews.length !== 1) {
      previews.forEach((preview: InstallJob) => LocalImport.discardPreview(context, preview));
      throw new Error('压缩包包含多个安装包，请选择要安装的应用');
    }
    return previews[0];
  }

  static discardPreview(context: common.UIAbilityContext, preview: InstallJob): void {
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    if (preview.cachePath.startsWith(prefix) && !preview.cachePath.includes('/../') &&
      /\.(hap|app)$/.test(preview.cachePath) && fileIo.accessSync(preview.cachePath)) {
      fileIo.unlinkSync(preview.cachePath);
    }
  }

  /** Only an explicit Install action promotes the file and persists a task. */
  static async commitPreview(context: common.UIAbilityContext, store: JobStore,
    preview: InstallJob): Promise<InstallJob> {
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    if (!preview.cachePath.startsWith(prefix) || preview.cachePath.includes('/../') ||
      !/^[0-9a-f]{64}$/.test(preview.expectedSha256)) throw new Error('本地安装预览无效，请重新选择');
    const sha256 = (await hash.hash(preview.cachePath, 'sha256')).toLowerCase();
    if (sha256 !== preview.expectedSha256) throw new Error('预览文件已变化，请重新选择');
    const identity = await PackageArchive.inspect(preview.cachePath);
    const dir = context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const extension = PackageArchive.extension(preview.cachePath);
    const cachePath = dir + '/local-' + sha256 + extension;
    const signedPath = dir + '/local-' + sha256 + '.signed' + extension;
    const temporary = cachePath + '.' + Date.now() + '.part';
    try {
      const valid = fileIo.accessSync(cachePath) &&
        (await hash.hash(cachePath, 'sha256')).toLowerCase() === sha256;
      if (!valid) {
        await fileIo.copyFile(preview.cachePath, temporary);
        fileIo.renameSync(temporary, cachePath);
      }
      const job = await store.enqueueLocal(cachePath, signedPath, sha256,
        identity.bundleName, identity.versionCode, identity.versionName,
        identity.moduleName, identity.mainAbility);
      job.assetName = preview.assetName;
      await store.save(job);
      LocalImport.discardPreview(context, preview);
      return job;
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  static async pickAndImport(context: common.UIAbilityContext, store: JobStore): Promise<InstallJob> {
    const preview = await LocalImport.pickPreview(context);
    try { return await LocalImport.commitPreview(context, store, preview); }
    finally { LocalImport.discardPreview(context, preview); }
  }
}
