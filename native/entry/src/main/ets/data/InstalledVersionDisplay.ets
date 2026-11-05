import { displayVersion, releaseDisplayVersion } from './DisplayVersion';
import { InstallJob } from '../jobs/InstallJob';
import { ReleaseUpdate } from '../jobs/ReleaseUpdate';

/** Shared installed-version presentation; catalog latest versions never enter this path. */
export class InstalledVersionDisplay {
  static label(bundleName: string, versionCode: number, versionName: string,
    updateTime: number, jobs: InstallJob[], appName: string = ''): string {
    const raw = displayVersion(versionName || '', appName) || (versionCode > 0 ? String(versionCode) : '');
    if (!Number.isSafeInteger(versionCode) || versionCode <= 0 ||
      !Number.isSafeInteger(updateTime) || updateTime <= 0) return raw;
    const record = ReleaseUpdate.record(jobs, bundleName, versionCode, updateTime);
    if (record === undefined || (versionName &&
      (record.versionName || '').trim() !== versionName.trim())) return raw;
    return releaseDisplayVersion(record.releaseName ?? '', ReleaseUpdate.tag(record),
      versionName || record.versionName || '', appName, versionCode) || raw;
  }
}
