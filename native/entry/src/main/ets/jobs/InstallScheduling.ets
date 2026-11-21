import { InstallJob } from './InstallJob';
import { DeviceInstallTarget } from './DeviceInstallTarget';

/** Submission provenance, not catalog membership, determines interactive priority. */
export class InstallScheduling {
  static local(job: InstallJob): boolean { return job.sourceUrl === 'local'; }
  static source(job: InstallJob): string { return InstallScheduling.local(job) ? 'local' : 'store'; }
  static device(job: InstallJob): string {
    return job.installTarget ? DeviceInstallTarget.parse(job.installTarget).key : 'local';
  }
  static lane(job: InstallJob): string { return InstallScheduling.source(job) + ':' + InstallScheduling.device(job); }
  static enqueuedAt(job: InstallJob): number { return job.stageHistory?.[0]?.at ?? job.updatedAt; }
}
