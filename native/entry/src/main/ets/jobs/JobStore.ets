import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { FailureKind, InstallJob, InstallStage } from './InstallJob';
import { isPending, stageForFailure } from './RecoveryPlanner';

const JOB_SCHEMA = `CREATE TABLE IF NOT EXISTS install_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  app_id INTEGER NOT NULL,
  asset_name TEXT NOT NULL,
  source_url TEXT NOT NULL,
  mirror_urls TEXT NOT NULL DEFAULT '[]',
  expected_sha256 TEXT NOT NULL,
  bundle_name TEXT NOT NULL,
  version_code INTEGER NOT NULL,
  module_name TEXT NOT NULL DEFAULT '',
  main_ability TEXT NOT NULL DEFAULT '',
  stage TEXT NOT NULL,
  cache_path TEXT NOT NULL,
  signed_path TEXT NOT NULL,
  profile_path TEXT NOT NULL DEFAULT '',
  device_udid TEXT NOT NULL DEFAULT '',
  profile_sha256 TEXT NOT NULL DEFAULT '',
  signed_profile_sha256 TEXT NOT NULL DEFAULT '',
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
    const columns = await db.querySql('PRAGMA table_info(install_jobs)');
    let hasTransferId = false;
    let hasMirrorUrls = false;
    let hasModuleName = false;
    let hasMainAbility = false;
    let hasProfilePath = false;
    let hasDeviceUdid = false;
    let hasProfileSha256 = false;
    let hasSignedProfileSha256 = false;
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
    return new JobStore(db);
  }

  async save(job: InstallJob): Promise<void> {
    job.updatedAt = Date.now();
    await this.db.executeSql(
      `INSERT OR REPLACE INTO install_jobs
      (id, app_id, asset_name, source_url, mirror_urls, expected_sha256, bundle_name,
       version_code, module_name, main_ability, stage, cache_path, signed_path, profile_path,
       device_udid, profile_sha256, signed_profile_sha256, transfer_task_id,
       attempt, last_error, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [job.id, job.appId, job.assetName, job.sourceUrl, JSON.stringify(job.mirrorUrls),
       job.expectedSha256,
       job.bundleName, job.versionCode, job.moduleName, job.mainAbility,
       job.stage, job.cachePath, job.signedPath, job.profilePath,
       job.deviceUdid, job.profileSha256, job.signedProfileSha256,
       job.transferTaskId,
       job.attempt, job.lastError, job.updatedAt]
    );
  }

  async get(id: string): Promise<InstallJob | undefined> {
    const rows = await this.query('SELECT * FROM install_jobs WHERE id = ?', [id]);
    return rows.length > 0 ? rows[0] : undefined;
  }

  async enqueue(appId: number, assetName: string, sourceUrl: string,
    expectedSha256: string, mirrorUrls: string[] = []): Promise<InstallJob> {
    if (appId <= 0 || assetName.length === 0 || sourceUrl.length === 0 ||
      !/^https:\/\//.test(sourceUrl) || !/^[0-9a-fA-F]{64}$/.test(expectedSha256)) {
      throw new Error('安装任务缺少可信的附件或 SHA-256');
    }
    const id = appId + ':' + assetName + ':' + expectedSha256.toLowerCase();
    const existing = await this.get(id);
    const candidates = mirrorUrls.filter((url: string) => /^https:\/\//.test(url) &&
      url !== sourceUrl).filter((url: string, index: number, urls: string[]) =>
      urls.indexOf(url) === index);
    if (existing && isPending(existing.stage)) {
      if (existing.mirrorUrls.length === 0 && candidates.length > 0) {
        existing.mirrorUrls = candidates;
        await this.save(existing);
      }
      return existing;
    }
    const job = InstallJob.create(id, appId, assetName,
      candidates.length > 0 ? candidates[0] : sourceUrl, expectedSha256);
    job.mirrorUrls = candidates.length > 0 ? [...candidates.slice(1), sourceUrl] : [];
    await this.save(job);
    return job;
  }

  async enqueueLocal(cachePath: string, signedPath: string, sha256: string,
    bundleName: string, versionCode: number, moduleName: string,
    mainAbility: string): Promise<InstallJob> {
    if (!/^[0-9a-f]{64}$/.test(sha256) || bundleName.length === 0 ||
      versionCode <= 0 || cachePath === signedPath) {
      throw new Error('本地安装任务信息无效');
    }
    const id = 'local:' + sha256;
    const existing = await this.get(id);
    if (existing && isPending(existing.stage)) return existing;
    const job = InstallJob.create(id, 0, bundleName + '.hap', 'local', sha256);
    job.cachePath = cachePath;
    job.signedPath = signedPath;
    job.bundleName = bundleName;
    job.versionCode = versionCode;
    job.moduleName = moduleName;
    job.mainAbility = mainAbility;
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
        job.bundleName = result.getString(result.getColumnIndex('bundle_name'));
        job.versionCode = result.getLong(result.getColumnIndex('version_code'));
        job.moduleName = result.getString(result.getColumnIndex('module_name'));
        job.mainAbility = result.getString(result.getColumnIndex('main_ability'));
        job.stage = result.getString(result.getColumnIndex('stage')) as InstallStage;
        job.cachePath = result.getString(result.getColumnIndex('cache_path'));
        job.signedPath = result.getString(result.getColumnIndex('signed_path'));
        job.profilePath = result.getString(result.getColumnIndex('profile_path'));
        job.deviceUdid = result.getString(result.getColumnIndex('device_udid'));
        job.profileSha256 = result.getString(result.getColumnIndex('profile_sha256'));
        job.signedProfileSha256 = result.getString(result.getColumnIndex('signed_profile_sha256'));
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
