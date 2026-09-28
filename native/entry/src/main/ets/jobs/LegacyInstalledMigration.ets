import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { InstallJob, InstallStage } from './InstallJob';
import { JobStore } from './JobStore';

// Preserve the Flutter store's installed history when the same bundle is
// upgraded. A marker prevents an intentionally removed row reappearing later.
export class LegacyInstalledMigration {
  static async run(context: common.UIAbilityContext, jobs: JobStore): Promise<number> {
    const marker = await preferences.getPreferences(context, 'legacy-installed');
    if (await marker.get('complete', false) as boolean) return 0;
    const path = context.filesDir + '/installed.json';
    if (!fileIo.accessSync(path)) return 0;
    const parsed = JSON.parse(fileIo.readTextSync(path)) as Array<Record<string, Object>>;
    if (!Array.isArray(parsed)) throw new Error('旧版安装记录格式无效');
    if (parsed.length > 200) throw new Error('旧版安装记录数量异常');
    let migrated = 0;
    for (let index = 0; index < parsed.length; index++) {
      const row = parsed[index];
      const appId = Number(row['appId'] ?? 0);
      const bundleName = String(row['bundleName'] ?? '');
      const versionCode = Number(row['installedVersionCode'] ?? 0);
      if (!Number.isSafeInteger(appId) || appId <= 0 ||
        !/^[A-Za-z][A-Za-z0-9_.]{2,255}$/.test(bundleName) ||
        !Number.isSafeInteger(versionCode) || versionCode <= 0) continue;
      const id = 'legacy:' + index + ':' + appId + ':' + bundleName;
      if (await jobs.get(id)) continue;
      const job = InstallJob.create(id, appId,
        String(row['displayName'] ?? bundleName), 'legacy', '');
      job.bundleName = bundleName;
      job.versionCode = versionCode;
      job.moduleName = String(row['moduleName'] ?? '');
      job.mainAbility = String(row['mainAbility'] ?? '');
      job.stage = InstallStage.INSTALLED;
      await jobs.save(job);
      migrated++;
    }
    await marker.put('complete', true);
    await marker.flush();
    return migrated;
  }
}
