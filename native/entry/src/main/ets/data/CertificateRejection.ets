import { ClassifiedFailure } from './ServiceFailure';
import { FailureKind } from '../jobs/InstallJob';

/** Only a missing certificate warrants refreshing signing identity, not every AGC error. */
export function isMissingCertificate(error: Error): boolean {
  const kind = (error as ClassifiedFailure).failureKind;
  if (kind === FailureKind.NETWORK || kind === FailureKind.ACCOUNT) return false;
  return /\bcert(?:ificate)?(?:[\s_-]+)(?:not[\s_-]+(?:exist(?:s)?|found)|does[\s_-]+not[\s_-]+exist)\b/i
    .test(error.message ?? String(error));
}
