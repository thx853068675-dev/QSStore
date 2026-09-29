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
  expectedSha256: string = '';
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
  transferTaskId: string = '';
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
  TRANSIENT = 'transient',
  INTERNAL = 'internal',
  INVALID_PACKAGE = 'invalid_package'
}
