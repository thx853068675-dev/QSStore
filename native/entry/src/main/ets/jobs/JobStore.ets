import { DownloadJournal } from './AssetDownload';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { InstallTaskState, InstallTaskSnapshot } from './InstallTaskState';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { JobCancellation } from './JobCancellation';
import { FailureKind, InstallJob, InstallStage, StageMark } from './InstallJob';
import { isPending, stageForFailure } from './RecoveryPlanner';
import { InstalledSigningIdentity } from './InstalledAppRegistry';
import { DownloadLibrary } from './DownloadLibrary';
import { DownloadPreferences } from './DownloadPreferences';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { ReleaseUpdate } from './ReleaseUpdate';
import { InstallPreflight } from './InstallPreflight';
import { I18n } from '../data/I18n';

const JOB_SCHEMA = `CREATE TABLE IF NOT EXISTS install_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  install_target TEXT NOT NULL DEFAULT '',
  install_batch TEXT NOT NULL DEFAULT '',
  app_id INTEGER NOT NULL,
  asset_name TEXT NOT NULL,
  source_url TEXT NOT NULL,
  mirror_urls TEXT NOT NULL DEFAULT '[]',
  custom_mirror_prefix TEXT NOT NULL DEFAULT '',
  expected_sha256 TEXT NOT NULL,
  catalog_bundle_name TEXT NOT NULL DEFAULT '',
  catalog_version_code INTEGER NOT NULL DEFAULT 0,
  release_tag TEXT NOT NULL DEFAULT '',
  release_name TEXT NOT NULL DEFAULT '',
  catalog_sha256 TEXT NOT NULL DEFAULT '',
  catalog_source_url TEXT NOT NULL DEFAULT '',
  device_compatibility_fingerprint TEXT NOT NULL DEFAULT '',
  edited_source_sha256 TEXT NOT NULL DEFAULT '',
  edited_source_asset_name TEXT NOT NULL DEFAULT '',
  package_source_sha256 TEXT NOT NULL DEFAULT '',
  replacement_install_baseline INTEGER NOT NULL DEFAULT 0,
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
  renewal_requested_at INTEGER NOT NULL DEFAULT 0,
  renewal_prepared_at INTEGER NOT NULL DEFAULT 0,
  renewal_previous_expiry INTEGER NOT NULL DEFAULT 0,
  renewal_expires_at INTEGER NOT NULL DEFAULT 0,
  renewal_install_baseline INTEGER NOT NULL DEFAULT 0,
  authorization_expires_at INTEGER NOT NULL DEFAULT 0,
  installed_update_time INTEGER NOT NULL DEFAULT 0,
  installed_fingerprint TEXT NOT NULL DEFAULT '',
  allow_data_loss INTEGER NOT NULL DEFAULT 0,
  approved_installed_version INTEGER NOT NULL DEFAULT 0,
  approved_installed_fingerprint TEXT NOT NULL DEFAULT '',
  approved_installed_app_identifier TEXT NOT NULL DEFAULT '',
  transfer_task_id TEXT NOT NULL,
  staged_ticket TEXT NOT NULL DEFAULT '',
  force_install INTEGER NOT NULL DEFAULT 0,
  skip_reason TEXT NOT NULL DEFAULT '',
  conflict_kind TEXT NOT NULL DEFAULT '',
  conflict_state TEXT NOT NULL DEFAULT '',
  approved_install_proof TEXT NOT NULL DEFAULT '',
  approved_installed_update_time INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL,
  last_error TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)`;

export class JobStore implements DownloadJournal {
  private static targetProvider: () => string = () => '';
  private static executionGuard:(id:string)=>boolean=()=>false;
  static setExecutionGuard(guard:(id:string)=>boolean):void{JobStore.executionGuard=guard;}
  static setTargetProvider(provider: () => string): void { JobStore.targetProvider=provider; }
  private static targetSnapshot(): string {
    const value=JobStore.targetProvider();
    if(value) DeviceInstallTarget.parse(value);
    return value;
  }
  private static opening: Promise<JobStore> | undefined;
  private static packageReaders: Map<string, number> = new Map();
  /** Preserve the exact database payload across awaits; parsed jobs can be mutable. */
  private static cleanupPayloads: WeakMap<InstallJob, string> = new WeakMap();
  private db: relationalStore.RdbStore;
  private context: common.UIAbilityContext | undefined;
  private renewalTail: Promise<void> = Promise.resolve();

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  /** Pins a package while a local import or renewal is becoming a durable task. */
  static reservePackage(path: string): () => void {
    JobStore.packageReaders.set(path, (JobStore.packageReaders.get(path) ?? 0) + 1);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const remaining = (JobStore.packageReaders.get(path) ?? 1) - 1;
      if (remaining > 0) JobStore.packageReaders.set(path, remaining);
      else JobStore.packageReaders.delete(path);
    };
  }

  private static packageInUse(path: string): boolean {
    return path.length > 0 && Array.from(JobStore.packageReaders.keys()).some((base: string) =>
      path === base || path.startsWith(base + '.'));
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
    await db.executeSql('CREATE TABLE IF NOT EXISTS installed_device_receipts (device_key TEXT NOT NULL, bundle_name TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(device_key,bundle_name))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS cancelled_job_cleanup (id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
    const columns = await db.querySql('PRAGMA table_info(install_jobs)');
    const availableColumns = new Set<string>();
    let hasTransferId = false;
    let hasStagedTicket = false;
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
        availableColumns.add(name);
        if (name === 'staged_ticket') hasStagedTicket = true;
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
    for (const name of ['renewal_requested_at', 'renewal_prepared_at',
      'renewal_previous_expiry', 'renewal_expires_at', 'renewal_install_baseline',
      'authorization_expires_at', 'installed_update_time', 'replacement_install_baseline',
      'force_install', 'approved_installed_update_time']) {
      if (!availableColumns.has(name)) {
        await db.executeSql('ALTER TABLE install_jobs ADD COLUMN ' + name + ' INTEGER NOT NULL DEFAULT 0');
      }
    }
    if (!availableColumns.has('installed_fingerprint')) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN installed_fingerprint TEXT NOT NULL DEFAULT ''");
    }
    for (const name of ['release_tag', 'release_name', 'catalog_sha256', 'custom_mirror_prefix',
      'edited_source_sha256', 'edited_source_asset_name', 'package_source_sha256',
      'catalog_source_url', 'device_compatibility_fingerprint', 'install_target', 'install_batch',
      'skip_reason', 'conflict_kind', 'conflict_state', 'approved_install_proof']) {
      if (!availableColumns.has(name)) {
        await db.executeSql('ALTER TABLE install_jobs ADD COLUMN ' + name + " TEXT NOT NULL DEFAULT ''");
      }
    }
    if (!hasStagedTicket) {
      await db.executeSql("ALTER TABLE install_jobs ADD COLUMN staged_ticket TEXT NOT NULL DEFAULT ''");
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
    store.context = context;
    await store.recoverInvalidPathFailures();
    // 应用退出时仍未完成的清理，在下次启动继续。
    await store.pruneCompleted(context);
    await store.pruneSupersededFailures(context);
    await store.cleanupCancelled(context);
    try { await store.cleanupOrphanedPackages(context); } catch (_) {}
    return store;
  }

  /** Repair the previous async-planning failure before any package work began. */
  private async recoverInvalidPathFailures(): Promise<void> {
    const message = I18n.t('安装工作目录无效');
    const rows = await this.query('SELECT * FROM install_jobs WHERE stage = ? AND last_error = ?',
      [InstallStage.TERMINAL_ERROR, message]);
    for (const job of rows) {
      if (job.stage !== InstallStage.TERMINAL_ERROR || job.lastError !== message || job.appId <= 0 ||
        !/^https:\/\//i.test(job.sourceUrl) || job.cachePath || job.signedPath || job.transferTaskId ||
        job.profilePath || job.profileSha256 || job.signedProfileSha256 || job.deviceUdid || job.signingCertId ||
        job.bundleName || job.versionCode > 0 || (job.stagedTicket ?? '') || job.renewalRequestedAt > 0 ||
        JobCancellation.isCancelled(job.id) || job.stageHistory.some((mark: StageMark) =>
          mark.stage !== InstallStage.QUEUED && mark.stage !== InstallStage.TERMINAL_ERROR)) continue;
      const mark = new StageMark(); mark.stage = InstallStage.RETRYABLE_ERROR; mark.at = Date.now();
      const predicates = new relationalStore.RdbPredicates('install_jobs')
        .equalTo('id', job.id).equalTo('stage', InstallStage.TERMINAL_ERROR).equalTo('last_error', message)
        .equalTo('updated_at', job.updatedAt).equalTo('cache_path', '').equalTo('signed_path', '');
      this.db.updateSync({ stage: InstallStage.RETRYABLE_ERROR,
        last_error: I18n.t('安装准备已修复，左滑卡片继续安装'), stage_history: JSON.stringify(job.stageHistory.concat([mark])) }, predicates);
    }
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
       attempt, last_error, updated_at, staged_ticket,
       renewal_requested_at, renewal_prepared_at, renewal_previous_expiry, renewal_expires_at, renewal_install_baseline,
       authorization_expires_at, installed_update_time, installed_fingerprint,
       release_tag, release_name, catalog_sha256, replacement_install_baseline, custom_mirror_prefix,
       edited_source_sha256, edited_source_asset_name, package_source_sha256,
       catalog_source_url, device_compatibility_fingerprint, install_target, install_batch,
       force_install, skip_reason, conflict_kind, conflict_state, approved_install_proof, approved_installed_update_time)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [job.id, job.appId, job.assetName, job.sourceUrl, JSON.stringify(job.mirrorUrls),
       job.expectedSha256, job.catalogBundleName, job.catalogVersionCode,
       job.bundleName, job.versionCode, job.versionName, JSON.stringify(job.stageHistory),
       job.moduleName, job.mainAbility,
       job.stage, job.cachePath, job.signedPath, job.profilePath,
       job.deviceUdid, job.profileSha256, job.signedProfileSha256,
       job.transferTaskId, job.signingCertId, job.reinstallRequired ? 1 : 0, job.allowDataLoss ? 1 : 0,
       job.approvedInstalledVersion, job.approvedInstalledFingerprint,
       job.approvedInstalledAppIdentifier,
       job.attempt, job.lastError, job.updatedAt, job.stagedTicket ?? '',
       job.renewalRequestedAt ?? 0, job.renewalPreparedAt ?? 0,
       job.renewalPreviousExpiry ?? 0, job.renewalExpiresAt ?? 0, job.renewalInstallBaseline ?? 0,
       job.authorizationExpiresAt ?? 0, job.installedUpdateTime ?? 0, job.installedFingerprint ?? '',
       job.releaseTag ?? '', job.releaseName ?? '', job.catalogSha256 ?? '', job.replacementInstallBaseline ?? 0,
       job.customMirrorPrefix ?? '', job.editedSourceSha256 ?? '', job.editedSourceAssetName ?? '',
       job.packageSourceSha256 ?? '', job.catalogSourceUrl ?? '', job.deviceCompatibilityFingerprint ?? '', job.installTarget ?? '', job.batchId ?? '',
       job.forceInstall ? 1 : 0, job.skipReason ?? '', job.conflictKind ?? '', job.conflictState ?? '',
       job.approvedInstallProof ?? '', job.approvedInstalledUpdateTime ?? 0]
    );
    if (JobCancellation.isCancelled(job.id)) {
      await this.rememberCancelledFiles(job);
      await this.db.executeSql('DELETE FROM install_jobs WHERE id = ?', [job.id]);
      throw new Error('安装任务已取消');
    }
    if(job.stage===InstallStage.INSTALLED)await this.preserveReceipt(job);
    InstallTaskState.publish(job);
  }

  private async preserveReceipt(job:InstallJob):Promise<void>{
    if(job.stage!==InstallStage.INSTALLED||!job.bundleName||!job.versionCode)return;
    try{await this.db.executeSql('INSERT OR REPLACE INTO installed_device_receipts(device_key,bundle_name,payload) VALUES(?,?,?)',
      [InstallPreflight.device(job),job.bundleName,JSON.stringify(job)]);}catch(error){console.warn('Install receipt archival deferred: '+String(error));}
  }

  async deviceReceipts(job:InstallJob):Promise<InstallJob[]>{
    const result=await this.db.querySql('SELECT payload FROM installed_device_receipts WHERE device_key=? AND bundle_name=?',[InstallPreflight.device(job),job.bundleName||job.catalogBundleName]);
    const rows:InstallJob[]=[];
    try{while(result.goToNextRow()){try{const row=JSON.parse(result.getString(0)) as InstallJob;
      if(row.stage===InstallStage.INSTALLED&&InstallPreflight.device(row)===InstallPreflight.device(job))rows.push(row);
    }catch(_){}}}finally{result.close();}
    return rows;
  }

  async get(id: string): Promise<InstallJob | undefined> {
    const rows = await this.query('SELECT * FROM install_jobs WHERE id = ?', [id]);
    return rows.length > 0 ? rows[0] : undefined;
  }

  async approveDataLoss(id: string, installed: InstalledSigningIdentity, proof:string=''): Promise<InstallJob> {
    if (installed.versionCode <= 0 ||
      (installed.fingerprint.length !== 64 && installed.appIdentifier.length === 0)) {
      throw new Error(I18n.t('无法核对当前安装身份，请连接无线调试后重试'));
    }
    const job = await this.get(id);
    if (!job || job.stage !== InstallStage.WAITING_CONFIRMATION) {
      throw new Error(I18n.t('安装任务不再等待确认，请重新检查安装状态'));
    }
    if (job.renewalRequestedAt > 0 && installed.versionCode !== job.versionCode) {
      throw new Error(I18n.t('应用版本已变化，请重新选择同版本安装包续签'));
    }
    this.validateConfirmation(job,installed,proof);
    job.approvedInstallProof=InstallPreflight.packageProof(job);job.approvedInstalledUpdateTime=installed.updateTime;
    job.allowDataLoss = true;
    job.forceInstall = true;
    job.approvedInstalledVersion = installed.versionCode;
    job.approvedInstalledFingerprint = installed.fingerprint;
    job.approvedInstalledAppIdentifier = installed.appIdentifier;
    await this.save(job);
    return job;
  }

  private validateConfirmation(job:InstallJob,installed:InstalledSigningIdentity,proof:string):void{
    if(proof&&proof!==InstallPreflight.packageProof(job))throw new Error(I18n.t('安装包或目标已变化，请重新确认'));
    if(job.conflictState){
      const previous=JSON.parse(job.conflictState) as InstalledSigningIdentity;
      if(InstallPreflight.stateProof(previous)!==InstallPreflight.stateProof(installed))throw new Error(I18n.t('已安装应用发生变化，请重新确认'));
    }
  }

  async approveReplacement(id:string,installed:InstalledSigningIdentity,proof:string):Promise<InstallJob>{
    const job=await this.get(id);
    if(!job||job.stage!==InstallStage.WAITING_CONFIRMATION||job.conflictKind!=='source')throw new Error(I18n.t('任务已变化，请重新检查'));
    this.validateConfirmation(job,installed,proof);
    job.forceInstall=true;job.allowDataLoss=false;job.approvedInstallProof=InstallPreflight.packageProof(job);
    job.approvedInstalledVersion=installed.versionCode;job.approvedInstalledUpdateTime=installed.updateTime;
    job.approvedInstalledFingerprint=installed.fingerprint;job.approvedInstalledAppIdentifier=installed.appIdentifier;
    await this.save(job);return job;
  }

  async skip(id:string,reason:string='kept'):Promise<void>{
    const job=await this.get(id);
    if(!job||JobStore.executionGuard(id))throw new Error(I18n.t('任务正在变化，请稍后重试'));
    job.stage=InstallStage.SKIPPED;job.skipReason=reason;job.lastError='';job.allowDataLoss=false;
    job.approvedInstallProof='';job.approvedInstalledUpdateTime=0;
    await this.save(job);
  }

  async enqueue(appId: number, assetName: string, sourceUrl: string,
    expectedSha256: string, mirrorUrls: string[] = [],
    versionName: string = '', catalogBundleName: string = '',
    catalogVersionCode: number = 0, releaseTag: string = '', releaseName: string = '',
    reinstallRequired: boolean = false, approvedDeviceCompatibility: string = '', pinnedTarget?: string): Promise<InstallJob> {
    if (appId <= 0 || assetName.length === 0 || sourceUrl.length === 0 ||
      !/^https:\/\//.test(sourceUrl)) {
      throw new Error(I18n.t('安装任务缺少 HTTPS 下载地址'));
    }
    // 商店摘要只用于任务 ID，不作为下载内容的准入条件。
    // 完成下载后 expectedSha256 才记录文件的实际摘要，供本机缓存恢复使用。
    const catalogSha = /^[0-9a-fA-F]{64}$/.test(expectedSha256) ?
      expectedSha256.toLowerCase() : '';
    const target=pinnedTarget ?? JobStore.targetSnapshot();
    if(target)DeviceInstallTarget.parse(target);
    const targetSuffix=target?':device:'+DeviceInstallTarget.parse(target).key:'';
    const id = appId + ':' + assetName + ':' + (catalogSha.length > 0 ? catalogSha : sourceUrl)+targetSuffix;
    const existing = await this.get(id);
    if(existing?.stage===InstallStage.INSTALLED)await this.preserveReceipt(existing);
    const candidates = mirrorUrls.filter((url: string) => /^https:\/\//.test(url) &&
      url !== sourceUrl).filter((url: string, index: number, urls: string[]) =>
      urls.indexOf(url) === index);
    // 同一附件重复入队保留已完成记录；运行器会核实设备版本，确实卸载后仍可重装。
    if (existing && (isPending(existing.stage) || existing.stage === InstallStage.INSTALLED)) {
      if ((existing.stage === InstallStage.INSTALLED || approvedDeviceCompatibility.length > 0) &&
        ((existing.deviceCompatibilityFingerprint ?? '') !== approvedDeviceCompatibility ||
          (existing.catalogSourceUrl || existing.sourceUrl) !== sourceUrl)) {
        existing.catalogSourceUrl = sourceUrl;
        existing.deviceCompatibilityFingerprint = approvedDeviceCompatibility;
        await this.save(existing);
      }
      if (catalogBundleName.length > 0 && existing.catalogBundleName.length === 0) {
        existing.catalogBundleName = catalogBundleName;
        existing.catalogVersionCode = catalogVersionCode;
        await this.save(existing);
      }
      if (existing.mirrorUrls.length === 0 && candidates.length > 0) {
        existing.mirrorUrls = candidates;
        await this.save(existing);
      }
      if (isPending(existing.stage) && reinstallRequired && !existing.reinstallRequired) {
        existing.reinstallRequired = true;
        await this.save(existing);
      }
      return existing;
    }
    const job = InstallJob.create(id, appId, assetName,
      candidates.length > 0 ? candidates[0] : sourceUrl, '');
    job.installTarget=target;
    job.mirrorUrls = candidates.length > 0 ? [...candidates.slice(1), sourceUrl] : [];
    job.versionName = versionName;
    job.catalogBundleName = catalogBundleName;
    job.catalogVersionCode = catalogVersionCode;
    job.releaseTag = releaseTag; job.releaseName = releaseName; job.catalogSha256 = catalogSha;
    job.catalogSourceUrl = sourceUrl;
    job.deviceCompatibilityFingerprint = approvedDeviceCompatibility;
    job.reinstallRequired = reinstallRequired;
    await this.save(job);
    return job;
  }

  /** Persist a same-version renewal before the dispatcher can observe the task. */
  async enqueueRenewal(appId: number, assetName: string, sourceUrl: string,
    mirrors: string[], bundleName: string, versionCode: number, versionName: string,
    accountReady: boolean = true): Promise<InstallJob> {
    const previous = this.renewalTail;
    let unlock: () => void = () => {};
    this.renewalTail = new Promise<void>((resolve) => { unlock = resolve; });
    await previous;
    let releasePackage: () => void = () => {};
    try {
      if (appId <= 0 || !assetName || !/^https:\/\//.test(sourceUrl) || !bundleName ||
        !Number.isSafeInteger(versionCode) || versionCode <= 0) throw new Error(I18n.t('续签原包信息无效'));
      const rows = await this.listAll();
      const pending = rows.find((job: InstallJob) => isPending(job.stage) &&
        (job.bundleName === bundleName || job.catalogBundleName === bundleName));
      if (pending) {
        if (pending.renewalRequestedAt > 0 && pending.versionCode === versionCode) return pending;
        throw new Error(I18n.t('该应用已有安装任务，请完成或取消后再续签'));
      }
      // Every explicit attempt owns a journal. Replacing the last successful
      // same-version row would discard its installed signing/expiry evidence.
      let requestedAt = Date.now();
      for (const previous of rows) {
        if (previous.bundleName === bundleName) requestedAt = Math.max(requestedAt, previous.renewalRequestedAt + 1);
      }
      const id = 'renew:' + appId + ':' + bundleName + ':' + versionCode + ':' + requestedAt.toString(36);
      const reusable = rows.filter((job: InstallJob) => job.stage === InstallStage.INSTALLED &&
        job.appId === appId && job.bundleName === bundleName && job.versionCode === versionCode &&
        job.assetName === assetName && [job.sourceUrl, ...job.mirrorUrls].includes(sourceUrl))
        .sort((a: InstallJob, b: InstallJob) => b.updatedAt - a.updatedAt)[0];
      const job = InstallJob.create(id, appId, assetName, sourceUrl, '');
      job.mirrorUrls = mirrors.filter((url: string) => /^https:\/\//.test(url) && url !== sourceUrl);
      job.catalogBundleName = bundleName; job.bundleName = bundleName;
      job.catalogVersionCode = versionCode; job.versionCode = versionCode; job.versionName = versionName;
      job.renewalRequestedAt = requestedAt; job.reinstallRequired = true;
      if (!accountReady) { job.stage = InstallStage.WAITING_ACCOUNT; job.lastError = I18n.t('请先登录开发者账号'); }
      if (reusable) {
        job.profilePath = reusable.profilePath; job.signingCertId = reusable.signingCertId;
        job.renewalPreviousExpiry = reusable.renewalExpiresAt || reusable.renewalPreviousExpiry || 0;
        job.moduleName = reusable.moduleName; job.mainAbility = reusable.mainAbility;
        if (reusable.cachePath && fileIo.accessSync(reusable.cachePath)) {
          releasePackage = JobStore.reservePackage(reusable.cachePath);
          job.cachePath = reusable.cachePath; job.expectedSha256 = reusable.expectedSha256;
          job.signedPath = reusable.cachePath + '.renew-' + job.renewalRequestedAt.toString(36) +
            (assetName.toLowerCase().endsWith('.app') ? '.signed.app' : '.signed.hap');
        }
      }
      await this.save(job);
      return job;
    } finally { releasePackage(); unlock(); }
  }

  async enqueueLocal(cachePath: string, signedPath: string, sha256: string,
    bundleName: string, versionCode: number, versionName: string, moduleName: string,
    mainAbility: string, renewal: boolean = false, pinnedTarget?: string): Promise<InstallJob> {
    if (!/^[0-9a-f]{64}$/.test(sha256) || bundleName.length === 0 ||
      versionCode <= 0 || cachePath === signedPath) {
      throw new Error(I18n.t('本地安装任务信息无效'));
    }
    if (renewal) {
      const previous = this.renewalTail;
      let unlock: () => void = () => {};
      this.renewalTail = new Promise<void>((resolve) => { unlock = resolve; });
      await previous;
      try {
        const rows = await this.listAll();
        const pending = rows.find((job: InstallJob) => isPending(job.stage) && job.bundleName === bundleName);
        if (pending) {
          if (pending.renewalRequestedAt > 0 && pending.versionCode === versionCode) {
            throw new Error(I18n.t('续签已在队列中，请在管理页查看进度'));
          }
          throw new Error(I18n.t('该应用已有安装任务，请完成或取消后再续签'));
        }
        let requestedAt = Date.now();
        for (const prior of rows) if (prior.bundleName === bundleName) {
          requestedAt = Math.max(requestedAt, prior.renewalRequestedAt + 1);
        }
        const job = InstallJob.create('local:' + sha256 + ':renew:' + requestedAt.toString(36),
          0, bundleName, 'local', sha256);
        job.cachePath = cachePath;
        job.signedPath = cachePath + '.renew-' + requestedAt.toString(36) + '.signed' +
          (signedPath.endsWith('.app') ? '.app' : '.hap');
        job.bundleName = bundleName; job.versionCode = versionCode; job.versionName = versionName;
        job.moduleName = moduleName; job.mainAbility = mainAbility;
        job.stage = InstallStage.PACKAGE_INSPECTED;
        job.renewalRequestedAt = requestedAt; job.reinstallRequired = true;
        await this.save(job);
        return job;
      } finally { unlock(); }
    }
    // Explicit local import may be a same-version name/icon/bytecode edit.
    // The installed version alone cannot prove this exact file was applied.
    const target=pinnedTarget ?? JobStore.targetSnapshot();
    if(target)DeviceInstallTarget.parse(target);
    const id = 'local:' + sha256+(target?':device:'+DeviceInstallTarget.parse(target).key:'');
    const existing = await this.get(id);
    if(existing&&JobStore.executionGuard(existing.id))return existing;
    if(existing?.stage===InstallStage.INSTALLED)await this.preserveReceipt(existing);
    if (existing && (existing.stage === InstallStage.INSTALLED || existing.renewalRequestedAt > 0)) {
      // Completed task files may have been pruned. Bind the newly imported
      // source before recovery can plan a different, nonexistent cache path.
      existing.cachePath = cachePath;
      existing.signedPath = signedPath;
      existing.bundleName = bundleName;
      existing.versionCode = versionCode;
      existing.versionName = versionName;
      existing.moduleName = moduleName;
      existing.mainAbility = mainAbility;
      existing.reinstallRequired = true;
      existing.stage = InstallStage.PACKAGE_INSPECTED;
      existing.stageHistory = [];
      existing.lastError = '';
      existing.installedUpdateTime = 0;
      existing.installedFingerprint = '';
      await this.save(existing);
      return existing;
    }

    const job = InstallJob.create(id, 0, bundleName + '.hap', 'local', sha256);
    job.cachePath = cachePath;
    job.installTarget=target;
    job.signedPath = signedPath;
    job.bundleName = bundleName;
    job.versionCode = versionCode;
    // 版本名一起存：本地安装没有目录可比对，界面上就没有可读的版本号，
    // 只能回退到 versionCode，显示成 2026092910 这种像日期的数字。
    job.versionName = versionName;
    job.moduleName = moduleName;
    job.mainAbility = mainAbility;
    job.reinstallRequired = true;
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

  async listAll(includeRemote: boolean = false): Promise<InstallJob[]> {
    const rows=await this.query('SELECT * FROM install_jobs ORDER BY updated_at DESC', []);
    return includeRemote?rows:rows.filter((job)=>!job.installTarget);
  }

  async forget(id: string, clean: boolean = true): Promise<void> {
    if (id.length === 0) throw new Error(I18n.t('安装记录编号为空'));
    if (this.context !== undefined) {
      const job = await this.get(id);
      if (job) await this.rememberCancelledFiles(job);
    }
    await this.db.executeSql('DELETE FROM install_jobs WHERE id = ?', [id]);
    InstallTaskState.remove(id);
    if (clean && this.context !== undefined) await this.cleanupCancelled(this.context, id);
  }

  async cancel(job: InstallJob): Promise<void> {
    JobCancellation.cancel(job.id);
    try {
      await this.rememberCancelledFiles(job);
      await this.forget(job.id, false);
    } catch (error) {
      JobCancellation.clear(job.id);
      throw new Error(String(error));
    }
  }

  private async rememberCancelledFiles(job: InstallJob, preserveExisting: boolean = false): Promise<void> {
    await this.db.executeSql((preserveExisting ? 'INSERT OR IGNORE' : 'INSERT OR REPLACE') +
      ' INTO cancelled_job_cleanup (id, payload) VALUES (?, ?)',
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

  private async cancelledFiles(id: string = ''): Promise<InstallJob[]> {
    const result = await this.db.querySql('SELECT id, payload FROM cancelled_job_cleanup' +
      (id.length > 0 ? ' WHERE id = ?' : ''), id.length > 0 ? [id] : []);
    const jobs: InstallJob[] = [];
    try {
      while (result.goToNextRow()) {
        const payload = result.getString(result.getColumnIndex('payload'));
        const job = JSON.parse(payload) as InstallJob;
        if (typeof job.customMirrorPrefix !== 'string') job.customMirrorPrefix = '';
        JobStore.cleanupPayloads.set(job, payload);
        jobs.push(job);
      }
    } finally { result.close(); }
    return jobs;
  }

  private cleanupReceiptMatches(id: string, payload: string): boolean {
    const result = this.db.querySqlSync('SELECT payload FROM cancelled_job_cleanup WHERE id = ?', [id]);
    try {
      return result.goToNextRow() && result.getString(result.getColumnIndex('payload')) === payload;
    } finally { result.close(); }
  }

  async cleanupCancelled(context: common.UIAbilityContext, id: string = ''): Promise<void> {
    const jobs = await this.cancelledFiles(id);
    const prefix = context.filesDir + '/install-jobs/';
    for (const job of jobs) {
      const payload = JobStore.cleanupPayloads.get(job) ?? JSON.stringify(job);
      if (!await this.stopTransfer(context, job)) continue;
      let clean = true;
      if ((job.stagedTicket ?? '').length > 0) {
        clean = HdcDeviceBridge.deviceLinked() &&
          await new HdcDeviceBridge(context, job.installTarget?DeviceInstallTarget.parse(job.installTarget):undefined).discardStaged(job.stagedTicket);
      }
      // Read references after asynchronous device cleanup, immediately before unlinking.
      const retained = await this.listAll(true);
      // Cancellation/forget may have reused the same ID while the device awaited
      // cleanup. The replacement receipt owns its writer and files independently.
      // This single-row read is synchronous: no await may stale retained again.
      if (!this.cleanupReceiptMatches(job.id, payload)) continue;
      const paths = [job.cachePath, job.signedPath, job.cachePath + '.part',
        job.cachePath + '.package.hap', job.cachePath + '.package.app',
        job.cachePath + '.package.hap.part', job.cachePath + '.package.app.part'];
      if (!retained.some((other: InstallJob) => other.cachePath === job.cachePath)) {
        for (const source of [job.cachePath, job.cachePath + '.package.app', job.cachePath + '.package.app.part']) {
          for (let index = 0; index < 32; index++) paths.push(source + '.module-' + index + '.hap');
        }
      }
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
          retained.some((other: InstallJob) => (other.cachePath.length > 0 &&
            (other.cachePath === path || path.startsWith(other.cachePath + '.'))) || other.signedPath === path)) continue;
        if (JobStore.packageInUse(path)) { clean = false; continue; }
        try { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); } catch (_) { clean = false; }
      }
      if (clean) await this.db.executeSql('DELETE FROM cancelled_job_cleanup WHERE id = ? AND payload = ?', [job.id, payload]);
    }
  }

  private canDiscardCompleted(job: InstallJob): boolean {
    const otherReader = Array.from(JobStore.packageReaders.keys()).some((base: string) => base !== job.cachePath &&
      [job.cachePath, job.signedPath].some((path: string) => path.length > 0 && (path === base || path.startsWith(base + '.'))));
    if (JobCancellation.isCancelled(job.id) || (JobStore.packageReaders.get(job.cachePath) ?? 0) !== 1 ||
      otherReader || InstallTaskState.snapshot().some((row: InstallTaskSnapshot) =>
        row.job.id === job.id && (row.running || row.finishing))) return false;
    const result = this.db.querySqlSync('SELECT id FROM install_jobs WHERE id = ? AND stage = ? AND updated_at = ?' +
      ' AND cache_path = ? AND signed_path = ? AND transfer_task_id = ? AND staged_ticket = ?',
      [job.id, job.stage, job.updatedAt, job.cachePath, job.signedPath, job.transferTaskId, job.stagedTicket ?? '']);
    try { return result.goToNextRow(); } finally { result.close(); }
  }

  /** Keep or clear successful originals by preference; retain installation/signing receipts. */
  async pruneCompleted(context: common.UIAbilityContext): Promise<void> {
    let autoClean = false;
    try { autoClean = await DownloadPreferences.load(context); } catch (_) {}
    let enabledSince = 0;
    if (autoClean) {
      try { enabledSince = await DownloadPreferences.enabledSince(context); } catch (_) {}
    }
    const jobs = (await this.listAll(true)).filter((job: InstallJob) =>
      (job.stage === InstallStage.INSTALLED || job.stage === InstallStage.SKIPPED) &&
      (job.cachePath.length > 0 || job.signedPath.length > 0 || job.transferTaskId.length > 0 || (job.stagedTicket ?? '').length > 0) &&
      !JobStore.packageInUse(job.cachePath) && !JobStore.packageInUse(job.signedPath) &&
      !InstallTaskState.snapshot().some((row: InstallTaskSnapshot) => row.job.id === job.id && (row.running || row.finishing)))
      .sort((a: InstallJob, b: InstallJob) => b.updatedAt - a.updatedAt);
    for (const job of jobs) {
      const timestamp = job.updatedAt;
      const cachePath = job.cachePath, signedPath = job.signedPath;
      const transferTaskId = job.transferTaskId, stagedTicket = job.stagedTicket ?? '';
      if (/^https:\/\//i.test(job.sourceUrl ?? '') && job.cachePath.length > 0) {
        const releasePackage = JobStore.reservePackage(job.cachePath);
        try {
          if (autoClean && enabledSince > 0 && ReleaseUpdate.completedAt(job) >= enabledSince) {
            try {
              if (!await DownloadLibrary.discardCompleted(context, job, (): boolean => this.canDiscardCompleted(job), enabledSince)) continue;
            } catch (_) { await DownloadLibrary.keep(context, job); }
          } else { await DownloadLibrary.keep(context, job); }
        }
        catch (_) { continue; } // Preserve the only original if archival is interrupted/full.
        finally { releasePackage(); }
      }
      // Archival yields to imports and renewed installs. Their working files stay pinned.
      if ((job.stage !== InstallStage.INSTALLED && job.stage !== InstallStage.SKIPPED) || JobCancellation.isCancelled(job.id) || JobStore.packageInUse(job.cachePath) ||
        JobStore.packageInUse(job.signedPath) || InstallTaskState.snapshot().some((row: InstallTaskSnapshot) =>
          row.job.id === job.id && (row.running || row.finishing))) continue;
      // Legacy receipts have no timeline. Preserve their original request-order
      // fallback before save() timestamps this maintenance operation as "now".
      const legacyHistory = (job.stageHistory?.length ?? 0) === 0;
      if (legacyHistory) {
        const original = new StageMark();
        original.stage = job.stage; original.at = job.updatedAt;
        job.stageHistory = [original];
      }
      // Journal before clearing references, so interrupted eviction resumes next startup.
      const previous = (await this.cancelledFiles(job.id))[0];
      if (previous !== undefined && (previous.cachePath !== cachePath || previous.signedPath !== signedPath ||
        previous.transferTaskId !== transferTaskId || (previous.stagedTicket ?? '') !== stagedTicket)) continue;
      const payload = previous !== undefined ? JobStore.cleanupPayloads.get(previous) ?? JSON.stringify(previous) : JSON.stringify(job);
      if (previous === undefined) await this.rememberCancelledFiles(job, true);
      if ((job.stage !== InstallStage.INSTALLED && job.stage !== InstallStage.SKIPPED) || JobCancellation.isCancelled(job.id) || JobStore.packageInUse(job.cachePath) ||
        JobStore.packageInUse(job.signedPath) || InstallTaskState.snapshot().some((row: InstallTaskSnapshot) =>
          row.job.id === job.id && (row.running || row.finishing))) continue;
      if (!this.cleanupReceiptMatches(job.id, payload)) continue;
      const predicates = new relationalStore.RdbPredicates('install_jobs')
        .equalTo('id', job.id).equalTo('stage', job.stage)
        .equalTo('updated_at', timestamp).equalTo('cache_path', cachePath)
        .equalTo('signed_path', signedPath).equalTo('transfer_task_id', transferTaskId)
        .equalTo('staged_ticket', stagedTicket);
      const changes: relationalStore.ValuesBucket = {
        cache_path: '', signed_path: '', transfer_task_id: '', staged_ticket: ''
      };
      if (legacyHistory) changes['stage_history'] = JSON.stringify(job.stageHistory);
      // Apply only to the still-completed row; no await or whole-row save may overwrite a restart/cancel.
      if (this.db.updateSync(changes, predicates) === 0) continue;
      job.cachePath = ''; job.signedPath = ''; job.transferTaskId = ''; job.stagedTicket = '';
      InstallTaskState.publish(job);
    }
    await this.cleanupCancelled(context);
  }

  /** Release obsolete failed package bytes, retaining the error journal and signing materials. */
  async pruneSupersededFailures(context: common.UIAbilityContext): Promise<void> {
    const jobs = await this.listAll(true);
    const receipts = new Map<string, InstallJob>();
    for (const receipt of await this.cancelledFiles()) receipts.set(receipt.id, receipt);
    for (const job of jobs) {
      if (job.stage !== InstallStage.TERMINAL_ERROR ||
        !(job.cachePath || job.signedPath || job.transferTaskId || job.stagedTicket) ||
        !jobs.some((other: InstallJob) => other.id !== job.id &&
          JobStore.requestedAt(other) > JobStore.requestedAt(job) &&
          (job.bundleName.length > 0 ? other.bundleName === job.bundleName :
            other.appId === job.appId && other.assetName === job.assetName))) continue;
      if (JobStore.packageInUse(job.cachePath) || JobStore.packageInUse(job.signedPath) ||
        InstallTaskState.snapshot().some((row: InstallTaskSnapshot) => row.job.id === job.id && (row.running || row.finishing))) continue;
      // An earlier cleanup receipt may still own a different package or download.
      // Never replace it and lose the only durable record of that writer.
      const receipt = receipts.get(job.id);
      if (receipt !== undefined && (receipt.cachePath !== job.cachePath || receipt.signedPath !== job.signedPath ||
        receipt.transferTaskId !== job.transferTaskId || (receipt.stagedTicket ?? '') !== (job.stagedTicket ?? ''))) continue;
      if (job.transferTaskId && jobs.some((other: InstallJob) => other.id !== job.id &&
        other.transferTaskId === job.transferTaskId)) continue;
      const payload = JSON.stringify(job);
      if (receipt === undefined) await this.rememberCancelledFiles(job);
      // Recording the receipt yields to retries/imports. Recheck process-owned work
      // and update only the unchanged terminal row, without replacing its history.
      if (JobStore.packageInUse(job.cachePath) || JobStore.packageInUse(job.signedPath) ||
        InstallTaskState.snapshot().some((row: InstallTaskSnapshot) => row.job.id === job.id && (row.running || row.finishing))) {
        if (receipt === undefined) await this.db.executeSql(
          'DELETE FROM cancelled_job_cleanup WHERE id = ? AND payload = ?', [job.id, payload]);
        continue;
      }
      const predicates = new relationalStore.RdbPredicates('install_jobs')
        .equalTo('id', job.id).equalTo('stage', InstallStage.TERMINAL_ERROR)
        .equalTo('updated_at', job.updatedAt).equalTo('cache_path', job.cachePath)
        .equalTo('signed_path', job.signedPath).equalTo('transfer_task_id', job.transferTaskId)
        .equalTo('staged_ticket', job.stagedTicket ?? '');
      const changes: relationalStore.ValuesBucket = {
        cache_path: '', signed_path: '', transfer_task_id: '', staged_ticket: ''
      };
      if (this.db.updateSync(changes, predicates) === 0) {
        if (receipt === undefined) await this.db.executeSql(
          'DELETE FROM cancelled_job_cleanup WHERE id = ? AND payload = ?', [job.id, payload]);
        continue;
      }
      job.cachePath = ''; job.signedPath = ''; job.transferTaskId = ''; job.stagedTicket = '';
      InstallTaskState.publish(job);
      await this.cleanupCancelled(context, job.id);
    }
  }

  /** Match the management queue's request ordering; cache eviction is not a new request. */
  private static requestedAt(job: InstallJob): number {
    return job.renewalRequestedAt > 0 ? job.renewalRequestedAt : (job.stageHistory?.[0]?.at ?? job.updatedAt);
  }

  /** Startup sweep inside the DB-open barrier: installation work cannot begin before it completes. */
  async cleanupOrphanedPackages(context: common.UIAbilityContext): Promise<number> {
    const dir = context.filesDir + '/install-jobs';
    if (!fileIo.accessSync(dir)) return 0;
    const root = fileIo.lstatSync(dir);
    if (!root.isDirectory() || root.isSymbolicLink()) return 0;
    const jobs = (await this.listAll(true)).concat(await this.cancelledFiles());
    // A cancelled system download can still be alive: retain its cleanup receipt's paths too.
    const bases = jobs.flatMap((job: InstallJob) => [job.cachePath, job.signedPath]).filter((path: string) => path.length > 0);
    let removed = 0;
    for (const name of fileIo.listFileSync(dir)) {
      if (/[\\/\u0000-\u001f]/.test(name) || !/\.(hap|app|zip|part)$/i.test(name)) continue;
      const path = dir + '/' + name;
      if (JobStore.packageInUse(path) || bases.some((base: string) => path === base || path.startsWith(base + '.'))) continue;
      try {
        const stat = fileIo.lstatSync(path);
        if (!stat.isFile() || stat.isSymbolicLink()) continue;
        const modified = Number(stat.mtime) * 1000;
        // Fresh/future/unknown timestamps are not reliable evidence of an abandoned writer.
        if (!Number.isFinite(modified) || modified <= 0 || Date.now() - modified < 10 * 60 * 1000) continue;
        fileIo.unlinkSync(path); removed++;
      } catch (_) { /* Retry inaccessible or disappearing files on the next startup. */ }
    }
    return removed;
  }

  private async query(sql: string, args: Array<relationalStore.ValueType>): Promise<InstallJob[]> {
    const result = await this.db.querySql(sql, args);
    const rows: InstallJob[] = [];
    const columns = new Map<string, number>();
    try {
      for (const name of [
        'id', 'app_id', 'asset_name', 'source_url', 'mirror_urls',
        'expected_sha256', 'catalog_bundle_name', 'catalog_version_code', 'bundle_name', 'version_code',
        'version_name', 'stage_history', 'module_name', 'main_ability', 'stage',
        'cache_path', 'signed_path', 'profile_path', 'device_udid', 'profile_sha256',
        'signed_profile_sha256', 'signing_cert_id', 'reinstall_required', 'renewal_requested_at', 'renewal_prepared_at',
        'renewal_previous_expiry', 'renewal_expires_at', 'renewal_install_baseline', 'authorization_expires_at', 'installed_update_time',
        'installed_fingerprint', 'allow_data_loss', 'approved_installed_version', 'approved_installed_fingerprint', 'approved_installed_app_identifier',
        'transfer_task_id', 'staged_ticket', 'attempt', 'last_error', 'updated_at',
        'release_tag', 'release_name', 'catalog_sha256', 'replacement_install_baseline', 'custom_mirror_prefix',
        'edited_source_sha256', 'edited_source_asset_name', 'package_source_sha256',
        'catalog_source_url', 'device_compatibility_fingerprint', 'install_target', 'install_batch',
        'force_install', 'skip_reason', 'conflict_kind', 'conflict_state', 'approved_install_proof', 'approved_installed_update_time'
      ]) columns.set(name, result.getColumnIndex(name));
      let sliceStartedAt = Date.now();
      while (result.goToNextRow()) {
        const job = new InstallJob();
        job.id = result.getString(columns.get('id')!);
        const targetColumn=columns.get('install_target')!;
        job.installTarget=targetColumn>=0?result.getString(targetColumn):'';
        const batchColumn=columns.get('install_batch')!;
        job.batchId=batchColumn>=0?result.getString(batchColumn):'';
        job.appId = result.getLong(columns.get('app_id')!);
        job.assetName = result.getString(columns.get('asset_name')!);
        job.sourceUrl = result.getString(columns.get('source_url')!);
        const prefixColumn = columns.get('custom_mirror_prefix')!;
        job.customMirrorPrefix = prefixColumn >= 0 ? result.getString(prefixColumn) : '';
        const mirrorText = result.getString(columns.get('mirror_urls')!);
        try {
          const parsed = JSON.parse(mirrorText) as string[];
          job.mirrorUrls = Array.isArray(parsed) ? parsed.filter((url: string) =>
            typeof url === 'string' && /^https:\/\//.test(url)) : [];
        } catch (_) {
          job.mirrorUrls = [];
        }
        job.expectedSha256 = result.getString(columns.get('expected_sha256')!);
        job.catalogBundleName = result.getString(columns.get('catalog_bundle_name')!);
        job.catalogVersionCode = result.getLong(columns.get('catalog_version_code')!);
        job.releaseTag = result.getString(columns.get('release_tag')!);
        job.releaseName = result.getString(columns.get('release_name')!);
        job.catalogSha256 = result.getString(columns.get('catalog_sha256')!);
        const sourceColumn = columns.get('catalog_source_url')!;
        job.catalogSourceUrl = sourceColumn >= 0 ? result.getString(sourceColumn) : '';
        const compatibilityColumn = columns.get('device_compatibility_fingerprint')!;
        job.deviceCompatibilityFingerprint = compatibilityColumn >= 0 ? result.getString(compatibilityColumn) : '';
        for (const name of ['edited_source_sha256', 'package_source_sha256']) {
          const column = columns.get(name)!;
          const digest = column >= 0 ? result.getString(column).toLowerCase() : '';
          if (name === 'edited_source_sha256') job.editedSourceSha256 = /^[a-f0-9]{64}$/.test(digest) ? digest : '';
          else job.packageSourceSha256 = /^[a-f0-9]{64}$/.test(digest) ? digest : '';
        }
        const assetColumn = columns.get('edited_source_asset_name')!;
        job.editedSourceAssetName = assetColumn >= 0 ? result.getString(assetColumn) : '';
        job.replacementInstallBaseline = result.getLong(columns.get('replacement_install_baseline')!);
        job.bundleName = result.getString(columns.get('bundle_name')!);
        job.versionCode = result.getLong(columns.get('version_code')!);
        job.versionName = result.getString(columns.get('version_name')!);
        const historyText = result.getString(columns.get('stage_history')!);
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
        job.moduleName = result.getString(columns.get('module_name')!);
        job.mainAbility = result.getString(columns.get('main_ability')!);
        job.stage = result.getString(columns.get('stage')!) as InstallStage;
        job.cachePath = result.getString(columns.get('cache_path')!);
        job.signedPath = result.getString(columns.get('signed_path')!);
        job.profilePath = result.getString(columns.get('profile_path')!);
        job.deviceUdid = result.getString(columns.get('device_udid')!);
        job.profileSha256 = result.getString(columns.get('profile_sha256')!);
        job.signedProfileSha256 = result.getString(columns.get('signed_profile_sha256')!);
        job.signingCertId = result.getString(columns.get('signing_cert_id')!);
        job.reinstallRequired = result.getLong(columns.get('reinstall_required')!) === 1;
        job.renewalRequestedAt = result.getLong(columns.get('renewal_requested_at')!);
        job.renewalPreparedAt = result.getLong(columns.get('renewal_prepared_at')!);
        job.renewalPreviousExpiry = result.getLong(columns.get('renewal_previous_expiry')!);
        job.renewalExpiresAt = result.getLong(columns.get('renewal_expires_at')!);
        job.renewalInstallBaseline = result.getLong(columns.get('renewal_install_baseline')!);
        job.authorizationExpiresAt = result.getLong(columns.get('authorization_expires_at')!);
        job.installedUpdateTime = result.getLong(columns.get('installed_update_time')!);
        job.installedFingerprint = result.getString(columns.get('installed_fingerprint')!);
        job.allowDataLoss = result.getLong(columns.get('allow_data_loss')!) === 1;
        job.approvedInstalledVersion = result.getLong(columns.get('approved_installed_version')!);
        job.approvedInstalledFingerprint = result.getString(columns.get('approved_installed_fingerprint')!);
        job.approvedInstalledAppIdentifier = result.getString(columns.get('approved_installed_app_identifier')!);
        job.transferTaskId = result.getString(columns.get('transfer_task_id')!);
        job.stagedTicket = result.getString(columns.get('staged_ticket')!);
        job.forceInstall = result.getLong(columns.get('force_install')!) === 1;
        job.skipReason = result.getString(columns.get('skip_reason')!);
        job.conflictKind = result.getString(columns.get('conflict_kind')!);
        job.conflictState = result.getString(columns.get('conflict_state')!);
        job.approvedInstallProof = result.getString(columns.get('approved_install_proof')!);
        job.approvedInstalledUpdateTime = result.getLong(columns.get('approved_installed_update_time')!);
        job.attempt = result.getLong(columns.get('attempt')!);
        job.lastError = result.getString(columns.get('last_error')!);
        job.updatedAt = result.getLong(columns.get('updated_at')!);
        rows.push(job);
        // Result-set conversion runs on the UI event loop even though querySql
        // is async. Yield by elapsed time, including small but expensive rows.
        if (Date.now() - sliceStartedAt >= 3) {
          await new Promise<void>((resolve) => setTimeout(resolve, 0));
          sliceStartedAt = Date.now();
        }
      }
    } finally {
      result.close();
    }
    return rows;
  }
}
