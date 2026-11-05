import { InstallJob, InstallStage } from './InstallJob';
import { LocalBundles } from './LocalBundles';
import { InstalledSigningIdentity } from './InstalledAppRegistry';
import { AgcProfile } from '../data/AgcProfile';
import { JobStore } from './JobStore';
import { JobScheduler } from './JobScheduler';
import { InstallReconnect } from './InstallReconnect';
import { InstallConfirmation } from './InstallConfirmation';
import { PrivacyConsent } from '../data/PrivacyConsent';
import { I18n } from '../data/I18n';

/** Recover the success receipt lost when installing this app kills its process. */
export class SelfInstallRecovery {
  static attemptedAt(job:InstallJob):number {
    if(job.installTarget||!(job.versionCode>0)||!job.bundleName)return 0;
    if(job.stage!==InstallStage.INSTALLING&&job.stage!==InstallStage.WAITING_DEVICE&&job.stage!==InstallStage.RETRYABLE_ERROR)return 0;
    let at=0;
    for(const mark of job.stageHistory??[]){
      if(mark.stage===InstallStage.QUEUED)at=0;
      if(mark.stage===InstallStage.INSTALLING)at=mark.at;
    }
    return at;
  }

  static async confirmed(job:InstallJob,state:InstalledSigningIdentity):Promise<boolean> {
    const at=SelfInstallRecovery.attemptedAt(job);
    if(!(at>0)||state.versionCode!==job.versionCode)return false;
    // Even an old online task without reinstallRequired may target a different
    // release sharing this build number. Require a real installation after submission.
    if(!(state.updateTime>=at)||
      (job.replacementInstallBaseline>0&&state.updateTime<=job.replacementInstallBaseline))return false;
    if(job.renewalRequestedAt>0){
      if(job.renewalPreparedAt!==job.renewalRequestedAt||!(job.renewalInstallBaseline>0)||
        state.updateTime<=job.renewalInstallBaseline||job.renewalExpiresAt<=Date.now()/1000||!job.profilePath)return false;
      try{return !!state.fingerprint&&state.fingerprint===await AgcProfile.signingFingerprint(job.profilePath);}
      catch(_){return false;}
    }
    // A local import is deliberately forced even when its internal code is unchanged.
    // The old version alone cannot prove that an edited icon/name was installed.
    if(job.reinstallRequired){
      if(!(state.updateTime>0))return false;
      if(job.replacementInstallBaseline>0){if(state.updateTime<=job.replacementInstallBaseline)return false;}
      else if(state.updateTime<at)return false; // legacy tasks have no saved baseline
      if(job.profilePath){
        try{if(!state.fingerprint||state.fingerprint!==await AgcProfile.signingFingerprint(job.profilePath))return false;}
        catch(_){return false;}
      }
    }
    return true;
  }

  static async reconcile(store:JobStore):Promise<number> {
    let settled=0;
    for(const snapshot of await store.listAll()){
      if(!PrivacyConsent.isBusinessAllowed())break;
      if(!SelfInstallRecovery.attemptedAt(snapshot)||JobScheduler.isRunning(snapshot.id))continue;
      // Re-read after awaits: a deleted or manually restarted task is no longer ours.
      const job=await store.get(snapshot.id);
      if(!job||job.updatedAt!==snapshot.updatedAt||JobScheduler.isRunning(job.id))continue;
      const at=SelfInstallRecovery.attemptedAt(job);
      if(!at)continue;
      const state=LocalBundles.selfInstalledIdentity(job.bundleName);
      if(!state)continue;
      const superseded=state.versionCode>job.versionCode&&state.updateTime>=at;
      if(!superseded&&!await SelfInstallRecovery.confirmed(job,state))continue;
      if(JobScheduler.isRunning(job.id)||!PrivacyConsent.isBusinessAllowed())continue;
      const current=await store.get(job.id);
      if(!current||current.updatedAt!==job.updatedAt||JobScheduler.isRunning(job.id))continue;
      job.stage=superseded?InstallStage.SKIPPED:InstallStage.INSTALLED;
      job.lastError='';job.reinstallRequired=false;job.allowDataLoss=false;
      job.approvedInstalledVersion=0;job.approvedInstalledFingerprint='';job.approvedInstalledAppIdentifier='';
      job.approvedInstallProof='';job.approvedInstalledUpdateTime=0;job.forceInstall=false;job.conflictKind='';job.conflictState='';
      job.skipReason=superseded?I18n.t('本机已安装更高版本，已跳过此任务'):'';
      if(!superseded){
        job.installedUpdateTime=state.updateTime;job.installedFingerprint=state.fingerprint;
        if(job.renewalRequestedAt>0)job.authorizationExpiresAt=job.renewalExpiresAt;
      }
      await store.save(job);settled++;
      InstallReconnect.clear(job.id);InstallConfirmation.clear(job.id);
    }
    return settled;
  }
}
