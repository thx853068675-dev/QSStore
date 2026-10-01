import { FailureKind } from '../jobs/InstallJob';

/** HTTP status remains available to callers; auth and permission failures never retry as network errors. */
export class ServiceFailure extends Error {
  failureKind: FailureKind;
  status: number;
  constructor(kind: FailureKind, message: string, status: number = 0) {
    super(message);
    this.failureKind = kind;
    this.status = status;
  }
}
export interface ClassifiedFailure { failureKind?: FailureKind; }
