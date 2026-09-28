import { common } from '@kit.AbilityKit';
import { fileIo, hash, picker } from '@kit.CoreFileKit';
import { InstallJob } from './InstallJob';
import { JobStore } from './JobStore';
import { inspectPackage } from './PackageInspector';

// Copies a picker URI into the app sandbox before the temporary grant expires.
// The source is never modified and the working file is promoted only after
// integrity calculation and bounded HAP manifest inspection.
export class LocalImport {
  static async pickAndImport(context: common.UIAbilityContext, store: JobStore): Promise<InstallJob> {
    const chooser = new picker.DocumentViewPicker(context);
    const selection = await chooser.select({
      fileSuffixFilters: ['HarmonyOS HAP|.hap'],
      maxSelectNumber: 1
    });
    if (selection.length !== 1) throw new Error('未选择 HAP 文件');

    const dir = context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const temporary = dir + '/local-' + Date.now() + '-' +
      Math.floor(Math.random() * 1000000) + '.part';
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
      const cachePath = dir + '/local-' + sha256 + '.hap';
      const signedPath = dir + '/local-' + sha256 + '.signed.hap';
      if (fileIo.accessSync(cachePath)) {
        const existing = (await hash.hash(cachePath, 'sha256')).toLowerCase();
        if (existing !== sha256) fileIo.unlinkSync(cachePath);
      }
      if (!fileIo.accessSync(cachePath)) fileIo.renameSync(temporary, cachePath);
      const job = await store.enqueueLocal(cachePath, signedPath, sha256,
        identity.bundleName, identity.versionCode, identity.moduleName,
        identity.mainAbility);
      return job;
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }
}
