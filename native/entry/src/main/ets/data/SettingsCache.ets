import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { JobStore } from '../jobs/JobStore';
import { CatalogCache } from './CatalogCache';

/** 目录、图标及安装临时文件；清理保留未完成任务、签名材料和编辑草稿。 */
export class SettingsCache {
  static async size(context: common.UIAbilityContext): Promise<number> {
    const sizes = await Promise.all([SettingsCache.packageSize(context), CatalogCache.size(context)]);
    return sizes[0] + sizes[1];
  }

  private static async packageSize(context: common.UIAbilityContext): Promise<number> {
    const dir = context.filesDir + '/install-jobs';
    try {
      const root = await fileIo.lstat(dir);
      if (!root.isDirectory() || root.isSymbolicLink()) return 0;
      let size = 0;
      for (const name of await fileIo.listFile(dir)) {
        if (/[\\/\u0000-\u001f]/.test(name) || !/\.(hap|app|zip|part)$/i.test(name)) continue;
        try {
          const stat = await fileIo.lstat(dir + '/' + name);
          if (stat.isFile() && !stat.isSymbolicLink()) size += Math.max(0, stat.size);
        } catch (_) { /* Files can disappear after an installation completes. */ }
      }
      return size;
    } catch (_) { return 0; }
  }

  static async clean(context: common.UIAbilityContext): Promise<void> {
    const store = await JobStore.open(context);
    await store.pruneCompleted(context);
    await store.cleanupOrphanedPackages(context);
    await CatalogCache.clear(context);
  }

  static format(bytes: number): string {
    if (bytes < 1024) return Math.max(0, bytes) + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }
}
