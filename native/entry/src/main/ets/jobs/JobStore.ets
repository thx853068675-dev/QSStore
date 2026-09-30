import { InstallTaskState } from './InstallTaskState';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { JobCancellation } from './JobCancellation';
import { FailureKind, InstallJob, InstallStage, StageMark } from './InstallJob';
import { isPending, stageForFailure } from './RecoveryPlanner';
import { InstalledSigningIdentity } from './InstalledAppRegistry';

const JOB_SCHEMA = `CREATE TABLE IF NOT EXISTS install_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  app_id INTEGER NOT NULL,
  asset_name TEXT NOT NULL,
  source_url TEXT NOT NULL,
  mirror_urls TEXT NOT NULL DEFAULT '[]',
  expected_sha256 TEXT NOT NULL,
  catalog_bundle_name TEXT NOT NULL DEFAULT '',
  catalog_version_code INTEGER NOT NULL DEFAULT 0,
  bundle_name TEXT NOT NULL,
  version_code INTEGER NOT NULL,
  version_name TEXT NOT NULL DEFAULT '',
  stage_history TEXT NOT NULL DEFAULT '[]',
  module_name TEXT NOT NULL DEFAULT '',
  main_ability TEXT NOT NULL DEFAULT '',
  stage TEXT NOT NULL,
  cache_path TEXT NOT NULL,
  signed_path TEXT NOT NULL,
  profile_path TEXT NOT NULL DEFAULT '',
  device_udid TEXT NOT NULL DEFAULT '',
  profile_sha256 TEXT NOT NULL DEFAULT '',
  signed_profile_sha256 TEXT NOT NULL DEFAULT '',
  signing_cert_id TEXT NOT NULL DEFAULT '',
  reinstall_required INTEGER NOT NULL DEFAULT 0,
  allow_data_loss INTEGER NOT NULL DEFAULT 0,
  approved_installed_version INTEGER NOT NULL DEFAULT 0,
  approved_installed_fingerprint TEXT NOT NULL DEFAULT '',
  approved_installed_app_identifier TEXT NOT NULL DEFAULT '',
  transfer_task_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  last_error TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)`;

export class JobStore {
  private static opening: Promise<JobStore> | undefined;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async open(context: common.UIAbilityContext): Promise<JobStore> {
    if (!JobStore.opening) {
      JobStore.opening = JobStore.initialize(context).catch((error: Error) => {
        JobStore.opening = undefined;
        throw error;
      });
    }
    return JobStore.opening;
  }

  private static async initialize(context: common.UIAbilityContext): Promise<JobStore> {
    const db = await relationalStore.getRdbStore(context, {
      name: 'qingqi-jobs.db',
      securityLevel: relationalStore.SecurityLevel.S1
    });
    await db.executeSql(JOB_SCHEMA);
    await db.executeSql('CREATE TABLE IF NOT EXISTS cancelled_job_cleanup (id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
    const columns = await db.querySql('PRAGMA table_info(install_jobs)');
    let hasTransferId = false;
    let hasMirrorUrls = false;
    let hasModuleName = false;
    let hasMainAbility = false;
    let hasProfilePath = false;
    let hasDeviceUdid = false;
    let hasProfileSha256 = false;
    let hasSignedProfileSha256 = false;
    let hasVersionName = false;
    let hasStageHistory = false;
    let hasCatalogBundleName = false;
    let hasCatalogVersionCode = false;
    let hasSigningCertId = false;
    let hasReinstallRequired = false;
    let hasAllowDataLoss = false;
    let hasApprovedVersion = false;
    let hasApprovedFingerprint = false;
    let hasApprovedAppIdentifier = false;
    try {
      while (columns.goToNextRow()) {
        const name = columns.getString(columns.getColumnIndex('name'));
        if (name === 'transfer_task_id') {
          hasTransferId = true;
        }
        if (name === 'mirror_urls') hasMirrorUrls = true;
        if (name === 'module_name') hasModuleName = true;
        if (name === 'main_ability') hasMainAbility = true;
        if (name === 'profile_path') hasProfilePath = true;
        if (name === 'device_udid') hasDeviceUdid = true;
        if (name === 'profile_sha256') hasProfileSha256 = true;
        if (name === 'signed_profile_sha256') hasSignedProfileSha256 = true;
        if (name === 'version_name') hasVersionName = true;
        if (name === 'stage_history') hasStageHistory = true;
        if (name === 'catalog_bundle_name') hasCatalogBundleName = true;
        if (name === 'catalog_version_code') hasCatalogVersionCode = true;
        if (name === 'signing_cert_id') hasSigningCertId = true;
        if (name === 'reinstall_required') hasReinstallRequired = true;
        if (name === 'allow_data_loss') hasAllowDataLoss = true;
        if (name === 'approved_installed_version') hasApprovedVersion = true;
        if (name === 'approved_installed_fingerprint') hasApprovedFingerprint = true;
        if (name === 'approved_installed_app_identifier') hasApprovedAppIdentifier = true;
      }
    } finally {
      columns.close();
    }
    if (!hasTransferId) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN transfer_task_id TEXT NOT NULL DEFAULT ''");
    }
    if (!hasMirrorUrls) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN mirror_urls TEXT NOT NULL DEFAULT '[]'");
    }
    if (!hasModuleName) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN module_name TEXT NOT NULL DEFAULT ''");
    }
    if (!hasMainAbility) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN main_ability TEXT NOT NULL DEFAULT ''");
    }
    if (!hasProfilePath) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN profile_path TEXT NOT NULL DEFAULT ''");
    }
    if (!hasDeviceUdid) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN device_udid TEXT NOT NULL DEFAULT ''");
    }
    if (!hasProfileSha256) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN profile_sha256 TEXT NOT NULL DEFAULT ''");
    }
    if (!hasSignedProfileSha256) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN signed_profile_sha256 TEXT NOT NULL DEFAULT ''");
    }
    // 版本名用于展示，阶段时间轴用于画安装流程；都是后加的，旧库要补列
    if (!hasVersionName) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN version_name TEXT NOT NULL DEFAULT ''");
    }
    if (!hasStageHistory) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN stage_history TEXT NOT NULL DEFAULT '[]'");
    }
    if (!hasCatalogBundleName) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN catalog_bundle_name TEXT NOT NULL DEFAULT ''");
    }
    if (!hasCatalogVersionCode) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN catalog_version_code INTEGER NOT NULL DEFAULT 0");
    }
    if (!hasSigningCertId) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN signing_cert_id TEXT NOT NULL DEFAULT ''");
    }
    if (!hasReinstallRequired) {
      await db.executeSql('ALTER TABLE install_jobs ADD COLUMN reinstall_required INTEGER NOT NULL DEFAULT 0');
    }
    if (!hasAllowDataLoss) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN allow_data_loss INTEGER NOT NULL DEFAULT 0");
    }
    if (!hasApprovedVersion) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN approved_installed_version INTEGER NOT NULL DEFAULT 0");
    }
    if (!hasApprovedFingerprint) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN approved_installed_fingerprint TEXT NOT NULL DEFAULT ''");
    }
    if (!hasApprovedAppIdentifier) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN approved_installed_app_identifier TEXT NOT NULL DEFAULT ''");
    }
    const store = new JobStore(db);
    // 应用退出时仍未完成的清理，在下次启动继续。
    await store.cleanupCancelled(context);
    return store;
  }

  /**
   * 阶段变化时追加一个时间戳。
   *
   * 放在 save 里而不是 JobRunner：下载、恢复、失败重试都会改阶段，收在一处
   * 才不会漏。同一个阶段重复保存（比如下载进度）不会重复记录。
   */
  private static markStage(job: InstallJob, stage: InstallStage): void {
    const last = job.stageHistory.length > 0 ?
      job.stageHistory[job.stageHistory.length - 1] : undefined;
    if (last !== undefined && last.stage === stage) return;
    const mark = new StageMark();
    mark.stage = stage;
    mark.at = job.updatedAt;
    job.stageHistory = job.stageHistory.concat([mark]);
  }

  async save(job: InstallJob): Promise<void> {
    if (JobCancellation.isCancelled(job.id)) {
      await this.rememberCancelledFiles(job);
      throw new Error('安装任务已取消');
    }
    job.updatedAt = Date.now();
    JobStore.markStage(job, job.stage);
    await this.db.executeSql(
      `INSERT OR REPLACE INTO install_jobs
      (id, app_id, asset_name, source_url, mirror_urls, expected_sha256,
       catalog_bundle_name, catalog_version_code, bundle_name,
       version_code, version_name, stage_history, module_name, main_ability, stage,
       cache_path, signed_path, profile_path,
       device_udid, profile_sha256, signed_profile_sha256, transfer_task_id,
       signing_cert_id, reinstall_required, allow_data_loss, approved_installed_version,
       approved_installed_fingerprint, approved_installed_app_identifier,
       attempt, last_error, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [job.id, job.appId, job.assetName, job.sourceUrl, JSON.stringify(job.mirrorUrls),
       job.expectedSha256, job.catalogBundleName, job.catalogVersionCode,
       job.bundleName, job.versionCode, job.versionName, JSON.stringify(job.stageHistory),
       job.moduleName, job.mainAbility,
       job.stage, job.cachePath, job.signedPath, job.profilePath,
       job.deviceUdid, job.profileSha256, job.signedProfileSha256,
       job.transferTaskId, job.signingCertId, job.reinstallRequired ? 1 : 0, job.allowDataLoss ? 1 : 0,
       job.approvedInstalledVersion, job.approvedInstalledFingerprint,
       job.approvedInstalledAppIdentifier,
       job.attempt, job.lastError, job.updatedAt]
    );
    if (JobCancellation.isCancelled(job.id)) {
      await this.rememberCancelledFiles(job);
      await this.db.executeSql('DELETE FROM install_jobs WHERE id = ?', [job.id]);
      throw new Error('安装任务已取消');
    }
    InstallTaskState.publish(job);
  }

  async get(id: string): Promise<InstallJob | undefined> {
    const rows = await this.query('SELECT * FROM install_jobs WHERE id = ?', [id]);
    return rows.length > 0 ? rows[0] : undefined;
  }

  async approveDataLoss(id: string, installed: InstalledSigningIdentity): Promise<InstallJob> {
    if (installed.versionCode <= 0 ||
      (installed.fingerprint.length !== 64 && installed.appIdentifier.length === 0)) {
      throw new Error('无法核对当前安装身份，请连接无线调试后重试');
    }
    const job = await this.get(id);
    if (!job || job.stage !== InstallStage.WAITING_CONFIRMATION) {
      throw new Error('安装任务不再等待确认，请重新检查安装状态');
    }
    job.allowDataLoss = true;
    job.approvedInstalledVersion = installed.versionCode;
    job.approvedInstalledFingerprint = installed.fingerprint;
    job.approvedInstalledAppIdentifier = installed.appIdentifier;
    await this.save(job);
    return job;
  }

  async enqueue(appId: number, assetName: string, sourceUrl: string,
    expectedSha256: string, mirrorUrls: string[] = [],
    versionName: string = '', catalogBundleName: string = '',
    catalogVersionCode: number = 0): Promise<InstallJob> {
    if (appId <= 0 || assetName.length === 0 || sourceUrl.length === 0 ||
      !/^https:\/\//.test(sourceUrl)) {
      throw new Error('安装任务缺少 HTTPS 下载地址');
    }
    // 商店摘要只用于任务 ID，不作为下载内容的准入条件。
    // 完成下载后 expectedSha256 才记录文件的实际摘要，供本机缓存恢复使用。
    const catalogSha = /^[0-9a-fA-F]{64}$/.test(expectedSha256) ?
      expectedSha256.toLowerCase() : '';
    const id = appId + ':' + assetName + ':' + (catalogSha.length > 0 ? catalogSha : sourceUrl);
    const existing = await this.get(id);
    const candidates = mirrorUrls.filter((url: string) => /^https:\/\//.test(url) &&
      url !== sourceUrl).filter((url: string, index: number, urls: string[]) =>
      urls.indexOf(url) === index);
    // 同一附件重复入队保留已完成记录；运行器会核实设备版本，确实卸载后仍可重装。
    if (existing && (isPending(existing.stage) || existing.stage === InstallStage.INSTALLED)) {
      if (catalogBundleName.length > 0 && existing.catalogBundleName.length === 0) {
        existing.catalogBundleName = catalogBundleName;
        existing.catalogVersionCode = catalogVersionCode;
        await this.save(existing);
      }
      if (existing.mirrorUrls.length === 0 && candidates.length > 0) {
        existing.mirrorUrls = candidates;
        await this.save(existing);
      }
      return existing;
    }
    const job = InstallJob.create(id, appId, assetName,
      candidates.length > 0 ? candidates[0] : sourceUrl, '');
    job.mirrorUrls = candidates.length > 0 ? [...candidates.slice(1), sourceUrl] : [];
    job.versionName = versionName;
    job.catalogBundleName = catalogBundleName;
    job.catalogVersionCode = catalogVersionCode;
    await this.save(job);
    return job;
  }

  async enqueueLocal(cachePath: string, signedPath: string, sha256: string,
    bundleName: string, versionCode: number, versionName: string, moduleName: string,
    mainAbility: string): Promise<InstallJob> {
    if (!/^[0-9a-f]{64}$/.test(sha256) || bundleName.length === 0 ||
      versionCode <= 0 || cachePath === signedPath) {
      throw new Error('本地安装任务信息无效');
    }
    // 本地任务的 id 由文件哈希决定，所以**同一个 HAP 每次都是同一个 id**。
    // 已经装完的记录可以复用（幂等）；但停在中间阶段的记录必须重建 ——
    // 那种记录是上次中断留下的，`stageHistory` 停在当时那一步。直接返回它，
    // 界面就会一直显示「已核对应用身份」这条旧时间轴，看起来像进度卡住不走。
    const id = 'local:' + sha256;
    const existing = await this.get(id);
    if (existing && existing.stage === InstallStage.INSTALLED) {
      if (bundleName === 'com.tonghongxiang.quietstart') {
        existing.reinstallRequired = true;
        existing.stage = InstallStage.PACKAGE_INSPECTED;
        existing.lastError = '';
        await this.save(existing);
      }
      return existing;
    }

    const job = InstallJob.create(id, 0, bundleName + '.hap', 'local', sha256);
    job.cachePath = cachePath;
    job.signedPath = signedPath;
    job.bundleName = bundleName;
    job.versionCode = versionCode;
    // 版本名一起存：本地安装没有目录可比对，界面上就没有可读的版本号，
    // 只能回退到 versionCode，显示成 2026092910 这种像日期的数字。
    job.versionName = versionName;
    job.moduleName = moduleName;
    job.mainAbility = mainAbility;
    // 用户主动再次导入轻启，可修复同版本里仍带旧设备授权的工作模块。
    job.reinstallRequired = bundleName === 'com.tonghongxiang.quietstart';
    job.stage = InstallStage.PACKAGE_INSPECTED;
    await this.save(job);
    return job;
  }

  async recordFailure(job: InstallJob, kind: FailureKind, message: string): Promise<void> {
    job.stage = stageForFailure(kind);
    job.lastError = message;
    job.attempt++;
    await this.save(job);
  }

  async listPending(): Promise<InstallJob[]> {
    const rows = await this.query('SELECT * FROM install_jobs ORDER BY updated_at DESC', []);
    return rows.filter((job: InstallJob) => isPending(job.stage));
  }

  async listAll(): Promise<InstallJob[]> {
    return this.query('SELECT * FROM install_jobs ORDER BY updated_at DESC', []);
  }

  async forget(id: string): Promise<void> {
    if (id.length === 0) throw new Error('安装记录编号为空');
    await this.db.executeSql('DELETE FROM install_jobs WHERE id = ?', [id]);
    InstallTaskState.remove(id);
  }

  async cancel(job: InstallJob): Promise<void> {
    JobCancellation.cancel(job.id);
    try {
      await this.rememberCancelledFiles(job);
      await this.forget(job.id);
    } catch (error) {
      JobCancellation.clear(job.id);
      throw new Error(String(error));
    }
  }

  private async rememberCancelledFiles(job: InstallJob): Promise<void> {
    await this.db.executeSql('INSERT OR REPLACE INTO cancelled_job_cleanup (id, payload) VALUES (?, ?)',
      [job.id, JSON.stringify(job)]);
  }

  async stopTransfer(context: common.UIAbilityContext, job: InstallJob): Promise<boolean> {
    if (job.transferTaskId.length === 0) return true;
    try {
      const task = await request.agent.getTask(context, job.transferTaskId);
      try { await task.pause(); } catch (_) {}
      await request.agent.remove(job.transferTaskId);
      return true;
    } catch (error) {
      // 已不存在的任务无需再清；其他失败留到下一次启动重试。
      return (error as BusinessError).code === 21900006;
    }
  }

  async cleanupCancelled(context: common.UIAbilityContext, id: string = ''): Promise<void> {
    const result = await this.db.querySql('SELECT id, payload FROM cancelled_job_cleanup' +
      (id.length > 0 ? ' WHERE id = ?' : ''), id.length > 0 ? [id] : []);
    const jobs: InstallJob[] = [];
    try {
      while (result.goToNextRow()) {
        jobs.push(JSON.parse(result.getString(result.getColumnIndex('payload'))) as InstallJob);
      }
    } finally { result.close(); }
    const prefix = context.filesDir + '/install-jobs/';
    for (const job of jobs) {
      if (!await this.stopTransfer(context, job)) continue;
      const retained = await this.listAll();
      let clean = true;
      const paths = [job.cachePath, job.signedPath, job.cachePath + '.part'];
      if (job.signedPath.startsWith(prefix) && !job.signedPath.includes('/../') &&
        !retained.some((other: InstallJob) => other.signedPath === job.signedPath)) {
        const name = job.signedPath.substring(prefix.length);
        if (!name.includes('/')) {
          const tempPrefix = '.' + name + '.qingqi-';
          try {
            const dir = prefix.substring(0, prefix.length - 1);
            const files = fileIo.accessSync(dir) ? fileIo.listFileSync(dir) : [];
            for (const file of files) {
              if (file.startsWith(tempPrefix) && /^\d+-\d+\.hap$/.test(file.substring(tempPrefix.length))) {
                paths.push(prefix + file);
              }
            }
          } catch (_) { clean = false; }
        }
      }
      for (const path of paths) {
        // 只删本任务工作目录中的文件；证书、授权与用户原始文件不在此范围。
        if (!path.startsWith(prefix) || path.includes('/../') ||
          retained.some((other: InstallJob) => other.cachePath === path ||
            other.signedPath === path || other.cachePath + '.part' === path)) continue;
        try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) { clean = false; }
      }
      if (clean) await this.db.executeSql('DELETE FROM cancelled_job_cleanup WHERE id = ?', [job.id]);
    }
  }

  private async query(sql: string, args: Array<relationalStore.ValueType>): Promise<InstallJob[]> {
    const result = await this.db.querySql(sql, args);
    const rows: InstallJob[] = [];
    try {
      while (result.goToNextRow()) {
        const job = new InstallJob();
        job.id = result.getString(result.getColumnIndex('id'));
        job.appId = result.getLong(result.getColumnIndex('app_id'));
        job.assetName = result.getString(result.getColumnIndex('asset_name'));
        job.sourceUrl = result.getString(result.getColumnIndex('source_url'));
        const mirrorText = result.getString(result.getColumnIndex('mirror_urls'));
        try {
          const parsed = JSON.parse(mirrorText) as string[];
          job.mirrorUrls = Array.isArray(parsed) ? parsed.filter((url: string) =>
            typeof url === 'string' && /^https:\/\//.test(url)) : [];
        } catch (_) {
          job.mirrorUrls = [];
        }
        job.expectedSha256 = result.getString(result.getColumnIndex('expected_sha256'));
        job.catalogBundleName = result.getString(result.getColumnIndex('catalog_bundle_name'));
        job.catalogVersionCode = result.getLong(result.getColumnIndex('catalog_version_code'));
        job.bundleName = result.getString(result.getColumnIndex('bundle_name'));
        job.versionCode = result.getLong(result.getColumnIndex('version_code'));
        job.versionName = result.getString(result.getColumnIndex('version_name'));
        const historyText = result.getString(result.getColumnIndex('stage_history'));
        try {
          const parsed = JSON.parse(historyText) as Array<Record<string, Object>>;
          job.stageHistory = Array.isArray(parsed) ? parsed.map((row: Record<string, Object>) => {
            const mark = new StageMark();
            mark.stage = String(row['stage'] ?? '');
            mark.at = Number(row['at'] ?? 0);
            return mark;
          }).filter((mark: StageMark) => mark.stage.length > 0 && mark.at > 0) : [];
        } catch (_) {
          job.stageHistory = [];
        }
        job.moduleName = result.getString(result.getColumnIndex('module_name'));
        job.mainAbility = result.getString(result.getColumnIndex('main_ability'));
        job.stage = result.getString(result.getColumnIndex('stage')) as InstallStage;
        job.cachePath = result.getString(result.getColumnIndex('cache_path'));
        job.signedPath = result.getString(result.getColumnIndex('signed_path'));
        job.profilePath = result.getString(result.getColumnIndex('profile_path'));
        job.deviceUdid = result.getString(result.getColumnIndex('device_udid'));
        job.profileSha256 = result.getString(result.getColumnIndex('profile_sha256'));
        job.signedProfileSha256 = result.getString(result.getColumnIndex('signed_profile_sha256'));
        job.signingCertId = result.getString(result.getColumnIndex('signing_cert_id'));
        job.reinstallRequired = result.getLong(result.getColumnIndex('reinstall_required')) === 1;
        job.allowDataLoss = result.getLong(result.getColumnIndex('allow_data_loss')) === 1;
        job.approvedInstalledVersion = result.getLong(result.getColumnIndex('approved_installed_version'));
        job.approvedInstalledFingerprint = result.getString(result.getColumnIndex('approved_installed_fingerprint'));
        job.approvedInstalledAppIdentifier = result.getString(result.getColumnIndex('approved_installed_app_identifier'));
        job.transferTaskId = result.getString(result.getColumnIndex('transfer_task_id'));
        job.attempt = result.getLong(result.getColumnIndex('attempt'));
        job.lastError = result.getString(result.getColumnIndex('last_error'));
        job.updatedAt = result.getLong(result.getColumnIndex('updated_at'));
        rows.push(job);
      }
    } finally {
      result.close();
    }
    return rows;
  }
}
