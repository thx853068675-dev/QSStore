export enum InstallStage {
  QUEUED = 'queued',
  DOWNLOADING = 'downloading',
  VERIFIED = 'verified',
  PACKAGE_INSPECTED = 'package_inspected',
  PROFILE_READY = 'profile_ready',
  SIGNED = 'signed',
  SIGNATURE_VERIFIED = 'signature_verified',
  WAITING_NETWORK = 'waiting_network',
  WAITING_ACCOUNT = 'waiting_account',
  WAITING_DEVICE = 'waiting_device',
  WAITING_CONFIRMATION = 'waiting_confirmation',
  INSTALLING = 'installing',
  INSTALLED = 'installed',
  RETRYABLE_ERROR = 'retryable_error',
  TERMINAL_ERROR = 'terminal_error'
}

/** 时间轴上的一个点：某个阶段是什么时候进入的。 */
export class StageMark {
  stage: string = '';
  at: number = 0;
}

export class InstallJob {
  id: string = '';
  appId: number = 0;
  assetName: string = '';
  sourceUrl: string = '';
  mirrorUrls: string[] = [];
  /** 本机缓存的实际摘要；在线任务下载前可为空，不要求匹配商店元数据。 */
  expectedSha256: string = '';
  /** 目录声明的身份，仅用于核对下载的 HAP；空值表示旧任务或本地导入。 */
  catalogBundleName: string = '';
  catalogVersionCode: number = 0;
  bundleName: string = '';
  versionCode: number = 0;
  moduleName: string = '';
  mainAbility: string = '';
  /**
   * 展示用的版本名，如 `1.1.0`。
   *
   * 设备认的是 versionCode，但那个数字给人看没意义（2026092902），
   * 所以界面统一显示版本名；拿不到时回退到版本号。
   */
  versionName: string = '';
  stage: InstallStage = InstallStage.QUEUED;
  /** 各阶段的进入时间，用来画时间轴。形如 [{"stage":"queued","at":1690000000000}]。 */
  stageHistory: StageMark[] = [];
  cachePath: string = '';
  signedPath: string = '';
  profilePath: string = '';
  deviceUdid: string = '';
  profileSha256: string = '';
  signedProfileSha256: string = '';
  /** 任务选用的证书 ID，恢复时不能无意改用新的默认身份。 */
  signingCertId: string = '';
  /** 用户明确提交的本地包/修复包，不能只凭版本相同跳过安装。 */
  reinstallRequired: boolean = false;
  /** Durable renewal intent; preparedAt equals requestedAt only after fresh authorization is verified. */
  renewalRequestedAt: number = 0;
  renewalPreparedAt: number = 0;
  renewalPreviousExpiry: number = 0;
  renewalExpiresAt: number = 0;
  renewalInstallBaseline: number = 0;
  /** Verified authorization for this exact installed build; invalidated by any external reinstall. */
  authorizationExpiresAt: number = 0;
  installedUpdateTime: number = 0;
  installedFingerprint: string = '';
  /** 用户明确接受卸载重装导致应用数据丢失，只对当前任务生效。 */
  allowDataLoss: boolean = false;
  approvedInstalledVersion: number = 0;
  approvedInstalledFingerprint: string = '';
  approvedInstalledAppIdentifier: string = '';
  transferTaskId: string = '';
  /** Generated device workspace retained until confirmed cleanup. */
  stagedTicket: string = '';
  attempt: number = 0;
  lastError: string = '';
  updatedAt: number = 0;

  static create(id: string, appId: number, assetName: string, sourceUrl: string,
    expectedSha256: string): InstallJob {
    const job = new InstallJob();
    job.id = id;
    job.appId = appId;
    job.assetName = assetName;
    job.sourceUrl = sourceUrl;
    job.expectedSha256 = expectedSha256.toLowerCase();
    job.updatedAt = Date.now();
    return job;
  }
}

export class RecoveryEvidence {
  verifiedCache: boolean = false;
  validProfile: boolean = false;
  verifiedSignature: boolean = false;
  deviceConnected: boolean = false;
  installedVersionCode: number = 0;
}

export enum FailureKind {
  NETWORK = 'network',
  ACCOUNT = 'account',
  DEVICE = 'device',
  CONFIRMATION = 'confirmation',
  TRANSIENT = 'transient',
  INTERNAL = 'internal',
  INVALID_PACKAGE = 'invalid_package'
}
