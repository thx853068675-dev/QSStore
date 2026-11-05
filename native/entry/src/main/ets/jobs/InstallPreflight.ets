import { InstallJob, InstallStage } from './InstallJob';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { InstalledSigningIdentity } from './InstalledAppRegistry';
import { ReleaseUpdate } from './ReleaseUpdate';
import { I18n } from '../data/I18n';

/** Pure per-device decisions. A release label alone is never proof of identical bytes. */
export class InstallPreflight {
  static device(job:InstallJob):string{return job.installTarget?DeviceInstallTarget.parse(job.installTarget).key:'local';}
  static packageProof(job:InstallJob):string{
    return JSON.stringify([InstallPreflight.device(job),job.bundleName,job.versionCode,
      job.catalogSourceUrl||job.sourceUrl,job.expectedSha256,job.packageSourceSha256||
        ((job.catalogSourceUrl||job.sourceUrl).includes('#qingqi-package=')?'':job.expectedSha256)]);
  }
  static stateProof(state:InstalledSigningIdentity):string{
    return JSON.stringify([state.versionCode,state.updateTime||0,state.fingerprint||'',state.appIdentifier||'']);
  }
  static approved(job:InstallJob,state:InstalledSigningIdentity):boolean{
    return job.approvedInstallProof===InstallPreflight.packageProof(job)&&
      job.approvedInstalledVersion===state.versionCode&&(job.approvedInstalledUpdateTime||0)===(state.updateTime||0)&&
      job.approvedInstalledFingerprint===state.fingerprint&&job.approvedInstalledAppIdentifier===state.appIdentifier;
  }
  static samePackage(job:InstallJob,state:InstalledSigningIdentity,jobs:InstallJob[]):boolean{
    if(!(state.updateTime>0))return false;
    const records=jobs.filter((row)=>InstallPreflight.device(row)===InstallPreflight.device(job));
    const receipt=ReleaseUpdate.record(records,job.bundleName,state.versionCode,state.updateTime);
    if(!receipt)return false;
    // An unknown old timestamp is insufficient to identify same-version installs.
    if(receipt.installedUpdateTime>0?receipt.installedUpdateTime!==state.updateTime:
      Math.abs(ReleaseUpdate.completedAt(receipt)-state.updateTime)>2000)return false;
    if(receipt.installedFingerprint&&state.fingerprint&&receipt.installedFingerprint!==state.fingerprint)return false;
    const current=[job.expectedSha256,job.catalogSha256,job.packageSourceSha256].filter((v)=>/^[a-f0-9]{64}$/i.test(v||'')).map((v)=>v.toLowerCase());
    const previous=[receipt.expectedSha256,receipt.catalogSha256,receipt.packageSourceSha256,receipt.editedSourceSha256]
      .filter((v)=>/^[a-f0-9]{64}$/i.test(v||'')).map((v)=>v.toLowerCase());
    return current.some((digest)=>previous.includes(digest));
  }
  /** install/update/skip-current/skip-newer/confirm-source. */
  static decide(job:InstallJob,state:InstalledSigningIdentity,jobs:InstallJob[],verified:boolean=true):string{
    if(job.renewalRequestedAt>0)return 'install';
    if(state.versionCode===0)return 'install';
    if(state.versionCode<job.versionCode)return 'update';
    if(state.versionCode>job.versionCode)return verified?'skip-newer':'inspect';
    if(job.forceInstall||job.sourceUrl==='local')return 'update';
    if(InstallPreflight.samePackage(job,state,jobs))return 'skip-current';
    if(!verified)return 'inspect';
    const records=jobs.filter((row)=>InstallPreflight.device(row)===InstallPreflight.device(job));
    if(ReleaseUpdate.available(ReleaseUpdate.forJob(job),state.versionCode,state.versionName,records,state.updateTime))return 'update';
    return 'confirm-source';
  }
  static wait(job:InstallJob,kind:string,state:InstalledSigningIdentity):void{
    job.conflictKind=kind;
    job.conflictState=JSON.stringify(state);
  }
  static skipMessage(reason:string):string{
    if(reason==='skip-paused')return I18n.t('此设备已停更，已跳过');
    return reason==='skip-current'?I18n.t('已是此版本，已跳过'):reason==='skip-newer'?I18n.t('已装更高版本，已跳过'):I18n.t('已保留原应用，跳过此设备');
  }
}
