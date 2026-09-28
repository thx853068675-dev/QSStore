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
  stage: InstallStage = InstallStage.QUEUED;
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
