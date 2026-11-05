import { DeviceInstallTarget } from './DeviceInstallTarget';
import { StorageBudget } from './StorageBudget';
import { common } from '@kit.AbilityKit';
import { fileIo, hash, picker } from '@kit.CoreFileKit';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';
import { PackageArchive } from './PackageArchive';
import { PackageIdentity } from './PackageInspector';
import { EditedPackageProvenance } from './EditedPackageProvenance';
import { DownloadLibrary } from './DownloadLibrary';
import { extractInstallArchive } from 'libhap_core.so';
import { I18n } from '../data/I18n';

class LocalReleaseOrigin {
  tag: string = '';
  name: string = '';
  sha256: string = '';
  assetName: string = '';
}

// Copies a picker URI into the app sandbox before the temporary grant expires.
// The source is never modified and the working file is promoted only after
// integrity calculation and bounded HAP manifest inspection.
export class LocalImport {
  static cleanupOldPreviews(context: common.UIAbilityContext): void {
    const dir = context.cacheDir + '/local-hap-previews';
    if (!fileIo.accessSync(dir)) return;
    for (const name of fileIo.listFileSync(dir)) {
      const match = /^local-(\d+)-\d+(?:-\d+)?\.(?:hap|app|part)(?:\.module-\d+\.hap)?$/.exec(name);
      if (match && Date.now() - Number(match[1]) > 86400000) {
        try { fileIo.unlinkSync(dir + '/' + name); } catch (_) {}
      }
    }
  }

  /** Selection copies and inspects the HAP, but never creates an install task. */
  static async pickPreviews(context: common.UIAbilityContext): Promise<InstallJob[]> {
    const chooser = new picker.DocumentViewPicker(context);
    const selection = await chooser.select({
      fileSuffixFilters: [I18n.t('安装包与压缩包|.hap,.app,.zip,.7z,.rar,.tar,.gz,.tgz,.bz2,.tbz,.tbz2,.xz,.txz,.lzma')],
      maxSelectNumber: 1
    });
    if (selection.length !== 1) throw new Error('未选择安装文件');
    return LocalImport.previewsFromUri(context, selection[0]);
  }

  static supportsName(name: string): boolean {
    return /\.(hap|app|zip|7z|rar|tar|gz|tgz|bz2|tbz|tbz2|xz|txz|lzma)$/i.test(name);
  }

  /** Picker and system FileOpen use the same read-only, preview-only import. */
  static async previewsFromUri(context: common.UIAbilityContext, uri: string): Promise<InstallJob[]> {
    const decoded = decodeURIComponent(uri.split('?')[0]);
    const filename = decoded.substring(decoded.lastIndexOf('/') + 1);
    if (!LocalImport.supportsName(filename)) throw new Error(I18n.t('请选择 HAP、APP 或支持的压缩文件'));

    const dir = context.cacheDir + '/local-hap-previews';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const temporary = dir + '/local-' + Date.now() + '-' +
      Math.floor(Math.random() * 1000000) + '.part';
    const previews: InstallJob[] = [];
    const staged: string[] = [];
    try {
      const source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const size = fileIo.statSync(source.fd).size;
        if (size <= 0 || size > 2 * 1024 * 1024 * 1024) throw new Error(I18n.t('安装文件大小无效（上限 2 GB）'));
        await StorageBudget.require(context.cacheDir, size * 2);
        await fileIo.copyFile(source.fd, temporary);
      }
      finally { fileIo.closeSync(source); }
      const size = fileIo.statSync(temporary).size;
      if (size <= 0 || size > 2 * 1024 * 1024 * 1024) throw new Error(I18n.t('安装文件大小无效（上限 2 GB）'));
      if (!/\.(hap|app)$/i.test(filename)) {
        const entries = await extractInstallArchive(temporary, temporary.replace(/\.part$/, ''), filename);
        staged.push(...entries.map((entry) => entry.path));
        let invalid = 0;
        for (let i = 0; i < entries.length; i++) {
          const output = entries[i].path;
          try {
            previews.push(await LocalImport.preview(context, output, entries[i].name));
          } catch (_) {
            invalid++;
            if (fileIo.accessSync(output)) fileIo.unlinkSync(output);
          }
        }
        if (!previews.length) throw new Error(I18n.t('压缩包中的 ') + invalid + I18n.t(' 个安装包均无效'));
      } else {
        const output = temporary.replace(/\.part$/, PackageArchive.extension(filename));
        staged.push(output);
        fileIo.renameSync(temporary, output);
        previews.push(await LocalImport.preview(context, output, filename));
      }
      return previews;
    } catch (error) {
      for (const path of staged) {
        PackageArchive.release(path);
        if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      }
      throw new Error(String(error));
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  /** Own a separate preview before the package editor releases its work files. */
  static async editedPreview(context: common.UIAbilityContext, path: string, name: string): Promise<InstallJob> {
    const prefix=context.cacheDir+'/package-editor/';
    if(!path.startsWith(prefix)||path.includes('/../')||!/\.(hap|app)$/i.test(path))throw new Error('编辑文件无效');
    const size=fileIo.statSync(path).size;
    if(size<=0||size>2*1024*1024*1024)throw new Error(I18n.t('安装文件大小无效'));
    await StorageBudget.require(context.cacheDir,size*2);
    const dir=context.cacheDir+'/local-hap-previews';if(!fileIo.accessSync(dir))fileIo.mkdirSync(dir,true);
    const output=dir+'/local-'+Date.now()+'-'+Math.floor(Math.random()*1000000)+PackageArchive.extension(path);
    try{await fileIo.copyFile(path,output);return await LocalImport.preview(context,output,name);}
    catch(error){PackageArchive.release(output);if(fileIo.accessSync(output))fileIo.unlinkSync(output);throw error as Error;}
  }

  private static async preview(context: common.UIAbilityContext, path: string, name: string): Promise<InstallJob> {
    const sha256 = (await hash.hash(path, 'sha256')).toLowerCase();
    const identity = await PackageArchive.inspect(path);
    const job = InstallJob.create('local:' + sha256, 0, name, 'local', sha256);
    job.cachePath = path;
    job.bundleName = identity.bundleName;
    job.versionCode = identity.versionCode;
    job.versionName = identity.versionName;
    job.moduleName = identity.moduleName;
    job.mainAbility = identity.mainAbility;
    const origin = await EditedPackageProvenance.source(context, sha256, identity);
    job.editedSourceSha256 = origin.sha256;
    job.editedSourceAssetName = origin.assetName;
    job.stage = InstallStage.PACKAGE_INSPECTED;
    return job;
  }

  static async pickPreview(context: common.UIAbilityContext): Promise<InstallJob> {
    const previews = await LocalImport.pickPreviews(context);
    if (previews.length !== 1) {
      previews.forEach((preview: InstallJob) => LocalImport.discardPreview(context, preview));
      throw new Error(I18n.t('压缩包包含多个安装包，请选择要安装的应用'));
    }
    return previews[0];
  }

  static discardPreview(context: common.UIAbilityContext, preview: InstallJob): void {
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    PackageArchive.release(preview.cachePath);
    if (preview.cachePath.startsWith(prefix) && !preview.cachePath.includes('/../') &&
      /\.(hap|app)$/.test(preview.cachePath) && fileIo.accessSync(preview.cachePath)) {
      fileIo.unlinkSync(preview.cachePath);
    }
  }

  private static async releaseOrigin(store: JobStore, sourceSha256: string,
    identity: PackageIdentity): Promise<LocalReleaseOrigin | undefined> {
    if (!sourceSha256) return undefined;
    const rows = await store.listAll();
    let origin: LocalReleaseOrigin | undefined;
    for (const row of rows) {
      if (row.stage !== InstallStage.INSTALLED || row.bundleName !== identity.bundleName ||
        row.versionCode !== identity.versionCode || row.versionName !== identity.versionName) continue;
      const exact = row.expectedSha256 === sourceSha256 || row.packageSourceSha256 === sourceSha256 ||
        row.editedSourceSha256 === sourceSha256;
      if (!exact || !(row.releaseTag || row.releaseName)) continue;
      const next = new LocalReleaseOrigin();
      next.tag = row.releaseTag || ''; next.name = row.releaseName || ''; next.sha256 = row.catalogSha256 || '';
      next.assetName = row.editedSourceAssetName || row.assetName || '';
      // The same bytes can occur in differently named releases. Do not guess the latest.
      if (origin && (origin.tag !== next.tag || origin.name !== next.name || origin.sha256 !== next.sha256 ||
        origin.assetName !== next.assetName)) return undefined;
      origin = next;
    }
    return origin;
  }

  /** Only an explicit Install action promotes the file and persists a task. */
  static async commitPreview(context: common.UIAbilityContext, store: JobStore,
    preview: InstallJob, renewal: boolean = false, pinnedTarget?: string): Promise<InstallJob> {
    const target=renewal?'':pinnedTarget ?? DeviceInstallTarget.selectedSnapshot();
    const prefix = context.cacheDir + '/local-hap-previews/local-';
    if (!preview.cachePath.startsWith(prefix) || preview.cachePath.includes('/../') ||
      !/^[0-9a-f]{64}$/.test(preview.expectedSha256)) throw new Error(I18n.t('本地安装预览无效，请重新选择'));
    const sha256 = (await hash.hash(preview.cachePath, 'sha256')).toLowerCase();
    if (sha256 !== preview.expectedSha256) throw new Error(I18n.t('预览文件已变化，请重新选择'));
    const identity = await PackageArchive.inspect(preview.cachePath);
    await DownloadLibrary.directory(context);
    const origin = await EditedPackageProvenance.source(context, sha256, identity);
    // Snapshot the proven source before enqueueLocal can reuse and reset a receipt.
    const release = await LocalImport.releaseOrigin(store, origin.sha256, identity);
    const dir = context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const extension = PackageArchive.extension(preview.cachePath);
    const cachePath = dir + '/local-' + sha256 + extension;
    const signedPath = dir + '/local-' + sha256 + (target ? '-device-' + DeviceInstallTarget.parse(target).key : '') + '.signed' + extension;
    await StorageBudget.require(context.filesDir, fileIo.statSync(preview.cachePath).size * 2);
    const temporary = cachePath + '.' + Date.now() + '.part';
    const releasePackage = JobStore.reservePackage(cachePath);
    try {
      const valid = fileIo.accessSync(cachePath) &&
        (await hash.hash(cachePath, 'sha256')).toLowerCase() === sha256;
      if (!valid) {
        await fileIo.copyFile(preview.cachePath, temporary);
        fileIo.renameSync(temporary, cachePath);
      }
      const job = await store.enqueueLocal(cachePath, signedPath, sha256,
        identity.bundleName, identity.versionCode, identity.versionName,
        identity.moduleName, identity.mainAbility, renewal, target);
      if(job.stage!==InstallStage.PACKAGE_INSPECTED)return job;
      job.assetName = preview.assetName;
      // Recheck local proof rather than trusting a mutable preview or an older task.
      job.editedSourceSha256 = origin.sha256;
      job.editedSourceAssetName = release?.assetName || origin.assetName;
      job.packageSourceSha256 = sha256;
      job.releaseTag = release?.tag || '';
      job.releaseName = release?.name || '';
      job.catalogSha256 = release?.sha256 || '';
      job.renewalInstallBaseline = 0;
      // A new explicit import cannot inherit consent to erase an older installation.
      job.allowDataLoss = false;
      job.approvedInstalledVersion = 0;
      job.approvedInstalledFingerprint = '';
      job.approvedInstalledAppIdentifier = '';
      if (renewal) {
        job.renewalRequestedAt = job.renewalRequestedAt || Date.now();
        job.renewalPreparedAt = 0;
        job.renewalPreviousExpiry = job.renewalPreviousExpiry || 0;
        job.renewalExpiresAt = 0;
        job.reinstallRequired = true;
        job.signedProfileSha256 = '';
      } else {
        job.renewalRequestedAt = 0;
        job.renewalPreparedAt = 0;
        job.renewalPreviousExpiry = 0;
        job.renewalExpiresAt = 0;
      }
      await store.save(job);
      LocalImport.discardPreview(context, preview);
      return job;
    } finally {
      releasePackage();
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }

  static async pickAndImport(context: common.UIAbilityContext, store: JobStore): Promise<InstallJob> {
    const preview = await LocalImport.pickPreview(context);
    try { return await LocalImport.commitPreview(context, store, preview); }
    finally { LocalImport.discardPreview(context, preview); }
  }
}
