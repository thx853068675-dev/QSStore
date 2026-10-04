import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { readSignedProfile } from 'libhap_core.so';
import { InstallJob } from '../jobs/InstallJob';
import { JobStore } from '../jobs/JobStore';
import { JobScheduler } from '../jobs/JobScheduler';
import { InstallTaskState } from '../jobs/InstallTaskState';
import { isPending } from '../jobs/RecoveryPlanner';

export class LocalProfileGroup {
  key: string = '';
  bundleName: string = '';
  files: string[] = [];
  expiresAt: number = 0;
}

/** This manager only touches retained local .p7b files, never keys or AGC records. */
export class LocalProfileStore {
  private static directory(context: common.UIAbilityContext): string {
    return context.filesDir + '/signing-profiles';
  }

  private static regular(path: string): boolean {
    const info = fileIo.lstatSync(path);
    return info.isFile() && !info.isSymbolicLink();
  }

  private static fileNames(context: common.UIAbilityContext): string[] {
    const dir = LocalProfileStore.directory(context);
    if (!fileIo.accessSync(dir)) return [];
    const info = fileIo.lstatSync(dir);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('本地 Profile 目录无效');
    return fileIo.listFileSync(dir).filter((name: string) =>
      name.endsWith('.p7b') && !/[\\/\u0000-\u001f]/.test(name) &&
      LocalProfileStore.regular(dir + '/' + name)).sort();
  }

  /** Validated local files for offline metadata inspection; no AGC requests. */
  static retainedFiles(context: common.UIAbilityContext): string[] {
    return LocalProfileStore.fileNames(context).map((name: string) =>
      LocalProfileStore.directory(context) + '/' + name);
  }

  private static describe(context: common.UIAbilityContext, name: string): LocalProfileGroup {
    const group = new LocalProfileGroup();
    group.key = 'file:' + name;
    group.files = [name];
    try {
      const data = JSON.parse(readSignedProfile(LocalProfileStore.directory(context) + '/' + name)) as Record<string, Object>;
      const bundle = data['bundle-info'] as Record<string, Object> | undefined;
      const bundleName = String(bundle?.['bundle-name'] ?? '');
      if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) return group;
      group.key = bundleName; group.bundleName = bundleName;
      const validity = data['validity'] as Record<string, Object> | undefined;
      const end = Number(validity?.['not-after'] ?? 0);
      group.expiresAt = Number.isFinite(end) && end > 0 ? Math.floor(end) : 0;
    } catch (_) {
      // Unreadable CMS remains visible and removable; never guess its app from a filename.
    }
    return group;
  }

  private static inUse(context: common.UIAbilityContext, group: LocalProfileGroup, jobs: InstallJob[]): boolean {
    const paths = group.files.map((name: string) => LocalProfileStore.directory(context) + '/' + name);
    const running = JobScheduler.runningJobIds();
    const live = InstallTaskState.snapshot();
    const all = jobs.concat(live.map((row) => row.job));
    if (running.some((id: string) => !all.some((job: InstallJob) => job.id === id))) return true;
    return all.some((job: InstallJob) =>
      (isPending(job.stage) || running.includes(job.id) ||
        live.some((row) => row.job.id === job.id && (row.running || row.finishing))) &&
      (paths.includes(job.profilePath) ||
        (group.bundleName.length > 0 && job.bundleName === group.bundleName) ||
        (running.includes(job.id) && !job.bundleName)));
  }

  static async list(context: common.UIAbilityContext): Promise<LocalProfileGroup[]> {
    const grouped: Map<string, LocalProfileGroup> = new Map();
    const names = LocalProfileStore.fileNames(context);
    for (let i = 0; i < names.length; i++) {
      const row = LocalProfileStore.describe(context, names[i]);
      const old = grouped.get(row.key);
      if (old) { old.files = old.files.concat(row.files); old.expiresAt = Math.max(old.expiresAt, row.expiresAt); }
      else grouped.set(row.key, row);
      // CMS files are small; yield between batches so a large local archive keeps scrolling responsive.
      if (i % 12 === 11) await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    const rows = Array.from(grouped.values());
    return rows.sort((a: LocalProfileGroup, b: LocalProfileGroup) => a.key.localeCompare(b.key));
  }

  static async remove(context: common.UIAbilityContext, key: string): Promise<number> {
    // Re-read after confirmation; the displayed list is never a deletion authority.
    const rows = await LocalProfileStore.list(context);
    const group = rows.find((row: LocalProfileGroup) => row.key === key);
    if (!group) return 0;
    const jobs = await (await JobStore.open(context)).listAll();
    if (LocalProfileStore.inUse(context, group, jobs)) {
      throw new Error('此应用有未完成的安装任务，请先完成或清理任务后再删除');
    }
    // No await from the final live-task check through unlink: a new runner cannot acquire these files in between.
    let deleted = 0;
    for (const name of group.files) {
      const path = LocalProfileStore.directory(context) + '/' + name;
      if (!fileIo.accessSync(path)) continue;
      if (!LocalProfileStore.regular(path) || LocalProfileStore.describe(context, name).key !== key) {
        throw new Error('Profile 已发生变化，请刷新列表后重试');
      }
      try { fileIo.unlinkSync(path); deleted++; }
      catch (_) { throw new Error('已删除 ' + deleted + ' 份 Profile，其余文件删除失败，请重试'); }
    }
    return deleted;
  }
}
