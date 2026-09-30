import { common } from '@kit.AbilityKit';
import { fileIo, hash, picker } from '@kit.CoreFileKit';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { inspectPackage } from './PackageInspector';

// Copies a picker URI into the app sandbox before the temporary grant expires.
// The source is never modified and the working file is promoted only after
// integrity calculation and bounded HAP manifest inspection.
export class LocalImport {
  /** Selection copies and inspects the HAP, but never creates an install task. */
  static async pickPreview(context: common.UIAbilityContext): Promise<InstallJob> {
    const chooser = new picker.DocumentViewPicker(context);
    const selection = await chooser.select({
      fileSuffixFilters: ['HarmonyOS HAP|.hap'],
      maxSelectNumber: 1
    });
    if (selection.length !== 1) throw new Error('未选择 HAP 文件');

    const dir = context.cacheDir + '/local-hap-previews';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const temporary = dir + '/local-' + Date.now() + '-' +
      Math.floor(Math.random() * 1000000) + '.part';
    const previewPath = temporary.replace(/\.part$/, '.hap');
    let ready = false;
    try {
      const source = fileIo.openSync(selection[0], fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(source.fd, temporary);
      } finally {
        fileIo.closeSync(source);
      }
      const size = fileIo.statSync(temporary).size;
      if (size <= 0 || size > 2 * 1024 * 1024 * 1024) {
        throw new Error('HAP 文件大小无效');
      }
      const sha256 = (await hash.hash(temporary, 'sha256')).toLowerCase();
      const identity = inspectPackage(temporary);
      fileIo.renameSync(temporary, previewPath);
      const job = InstallJob.create('local:' + sha256, 0, identity.bundleName + '.hap', 'local', sha256);
      job.cachePath = previewPath;
      job.bundleName = identity.bundleName;
      job.versionCode = identity.versionCode;
      job.versionName = identity.versionName;
      job.moduleName = identity.moduleName;
      job.mainAbility = identity.mainAbility;
      job.stage = InstallStage.PACKAGE_INSPECTED;
      ready = true;
      return job;
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
      if (!ready && fileIo.accessSync(previewPath)) fileIo.unlinkSync(previewPath);
    }
  }

  static discardPreview(context: common.UIAbilityContext, preview: InstallJob): void {
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    if (preview.cachePath.startsWith(prefix) && !preview.cachePath.includes('/../') &&
      preview.cachePath.endsWith('.hap') && fileIo.accessSync(preview.cachePath)) {
      fileIo.unlinkSync(preview.cachePath);
    }
  }

  /** Only an explicit Install action promotes the file and persists a task. */
  static async commitPreview(context: common.UIAbilityContext, store: JobStore,
    preview: InstallJob): Promise<InstallJob> {
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    if (!preview.cachePath.startsWith(prefix) || preview.cachePath.includes('/../') ||
      !/^[0-9a-f]{64}$/.test(preview.expectedSha256)) throw new Error('本地 HAP 预览无效，请重新选择');
    const sha256 = (await hash.hash(preview.cachePath, 'sha256')).toLowerCase();
    if (sha256 !== preview.expectedSha256) throw new Error('预览文件已变化，请重新选择 HAP');
    const identity = inspectPackage(preview.cachePath);
    const dir = context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const cachePath = dir + '/local-' + sha256 + '.hap';
    const signedPath = dir + '/local-' + sha256 + '.signed.hap';
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
