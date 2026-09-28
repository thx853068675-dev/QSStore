import { FailureKind, InstallJob, InstallStage, RecoveryEvidence } from './InstallJob';

/// Returns a safe next stage after checking durable artifacts. A journal row
/// alone is never proof that an HAP, profile, signature or installation exists.
export function recoveryStage(job: InstallJob, evidence: RecoveryEvidence): InstallStage {
  if (job.stage === InstallStage.TERMINAL_ERROR) {
    return InstallStage.TERMINAL_ERROR;
  }
  if (job.bundleName.length > 0 && job.versionCode > 0 &&
    evidence.installedVersionCode === job.versionCode) {
    return InstallStage.INSTALLED;
  }
  if (!evidence.verifiedCache) {
    return InstallStage.QUEUED;
  }
  if (job.bundleName.length === 0 || job.versionCode <= 0) {
    return InstallStage.VERIFIED;
  }
  if (!evidence.validProfile) {
    return InstallStage.PACKAGE_INSPECTED;
  }
  if (!evidence.verifiedSignature) {
    return InstallStage.PROFILE_READY;
  }
  if (!evidence.deviceConnected) {
    return InstallStage.WAITING_DEVICE;
  }
  return InstallStage.INSTALLING;
}

export function isPending(stage: InstallStage): boolean {
  return stage !== InstallStage.INSTALLED && stage !== InstallStage.TERMINAL_ERROR;
}

export function stageForFailure(kind: FailureKind): InstallStage {
  switch (kind) {
    case FailureKind.NETWORK: return InstallStage.WAITING_NETWORK;
    case FailureKind.ACCOUNT: return InstallStage.WAITING_ACCOUNT;
    case FailureKind.DEVICE: return InstallStage.WAITING_DEVICE;
    case FailureKind.TRANSIENT: return InstallStage.RETRYABLE_ERROR;
    case FailureKind.INTERNAL: return InstallStage.TERMINAL_ERROR;
    case FailureKind.INVALID_PACKAGE: return InstallStage.TERMINAL_ERROR;
  }
}

/// Only transient failures are retried automatically. Account and device
/// conditions wait for a state change instead of consuming AGC slots or
/// repeatedly interrupting the user.
export function retryDelayMs(attempt: number): number {
  const capped = Math.min(Math.max(attempt, 0), 6);
  return Math.min(1000 * Math.pow(2, capped), 60000);
}
