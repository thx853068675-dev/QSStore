import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { InstallConfirmation } from './InstallConfirmation';
import { InstallCoordinator } from './InstallCoordinator';
import { InstallJob, InstallStage } from './InstallJob';
import { InstalledSigningIdentity } from './InstalledAppRegistry';
import { InstallPreflight } from './InstallPreflight';
import { JobStore } from './JobStore';
import { HdcDeviceBridge } from './HdcDeviceBridge';
import { DeviceInstallTarget } from './DeviceInstallTarget';
import { LocalBundles } from './LocalBundles';
import { Palette } from '../theme/Palette';
import { errorText } from './ErrorText';
import { I18n } from '../data/I18n';

class PackageCompatibilityDecision { fingerprint:string='';title:string='';current:string='';supported:string=''; }

/** One process-wide FIFO of decisions; installation lanes never wait inside a dialog. */
export class InstallConflictFlow {
  static async present(context:common.UIAbilityContext,owner:number,id:string):Promise<void>{
    const lease=InstallConfirmation.claim(owner,id);
    if(!lease)return;
    let requeue=false;
    let resume=false;
    try{
      const store=await JobStore.open(context),job=await store.get(id);
      if(!job||job.stage!==InstallStage.WAITING_CONFIRMATION||!InstallConfirmation.isRequested(id))return;
      if(!InstallConfirmation.isOwner(owner)){requeue=true;return;}
      const proof=InstallPreflight.packageProof(job);
      const target=job.installTarget?DeviceInstallTarget.parse(job.installTarget):undefined;
      const colors=Palette.forMode(AppStorage.get<boolean>('darkMode')??false);
      if(job.conflictKind==='compatibility'){
        const decision=JSON.parse(job.conflictState) as PackageCompatibilityDecision;
        const result=await promptAction.showDialog({title:I18n.t('确认设备适配'),
          message:(target?.name||I18n.t('本机'))+' · '+decision.title+I18n.t('\n支持：')+decision.supported+I18n.t('\n当前：')+decision.current+I18n.t('\n仍要尝试安装吗？'),
          buttons:[{text:I18n.t('跳过此设备'),color:colors.textSecondary},{text:I18n.t('继续安装'),color:colors.accent}]});
        if(!InstallConfirmation.isOwner(owner)){requeue=true;return;}
        if(!InstallConfirmation.valid(owner,id,lease))return;
        const fresh=await store.get(id);
        if(!fresh||fresh.stage!==InstallStage.WAITING_CONFIRMATION||fresh.conflictState!==job.conflictState||InstallPreflight.packageProof(fresh)!==proof)return;
        if(result.index===0){await store.skip(id,'incompatible');return;}
        if(result.index===1){fresh.deviceCompatibilityFingerprint=decision.fingerprint;fresh.stage=InstallStage.QUEUED;
          await store.save(fresh);resume=true;}
        return;
      }
      const bridge=new HdcDeviceBridge(context,target);
      let state:InstalledSigningIdentity;
      try{state=job.conflictState?JSON.parse(job.conflictState) as InstalledSigningIdentity:
        await bridge.installedState(job.bundleName);}
      catch(error){promptAction.showToast({message:errorText(error)});return;}
      const source=job.conflictKind==='source';
      const name=job.assetName||job.bundleName;
      const targetName=target?.name||I18n.t('本机');
      const version=state.versionName||String(state.versionCode);
      const incoming=job.versionName||String(job.versionCode);
      let body=source?I18n.t('已安装相同内部编号，尚不能确认是同一个安装包。覆盖安装将先尝试保留应用数据。'):
        InstallConfirmation.dataLossMessage(job.renewalRequestedAt>0,!target&&LocalBundles.isSelfBundle(job.bundleName),
          target?'':job.bundleName,name);
      if(!source&&state.appGallery)body=I18n.t('此设备上的现有应用来自华为应用市场，与所选包使用相同包名。继续会卸载现有应用，清除缓存、设置和登录状态。');
      const result=await promptAction.showDialog({
        title:source?I18n.t('确认覆盖安装'):I18n.t('确认清除应用数据'),
        message:targetName+' · '+name+'\n'+version+' → '+incoming+'\n\n'+body,
        buttons:[{text:I18n.t('保留并跳过'),color:colors.textSecondary},
          {text:source?I18n.t('覆盖并继续'):I18n.t('清除数据并继续'),color:source?colors.accent:colors.danger}]
      });
      if(!InstallConfirmation.isOwner(owner)){requeue=true;return;}
      if(!InstallConfirmation.valid(owner,id,lease))return;
      const fresh=await store.get(id);
      if(!fresh||fresh.stage!==InstallStage.WAITING_CONFIRMATION||InstallPreflight.packageProof(fresh)!==proof)return;
      if(result.index===0){await store.skip(id);return;}
      if(result.index!==1)return;
      // Consent names the displayed state. Never grant it to a later external update.
      const current=await bridge.installedState(job.bundleName);
      if(InstallPreflight.stateProof(current)!==InstallPreflight.stateProof(state)){
        // Reclassify rather than applying an old decision to a changed app.
        fresh.allowDataLoss=false;fresh.forceInstall=false;fresh.approvedInstallProof='';
        fresh.conflictKind='';fresh.conflictState='';fresh.stage=InstallStage.QUEUED;
        await store.save(fresh);resume=true;return;
      }
      if(source)await store.approveReplacement(id,current,proof);
      else await store.approveDataLoss(id,current,proof);
      // Resume the accepted job immediately; the next prompt does not wait for its install.
      resume=true;
    }catch(error){
      // Back/outside-dismiss keeps this task pending but advances to other requests.
      if(!/cancel/i.test(String(error)))promptAction.showToast({message:errorText(error)});
    }finally{
      InstallConfirmation.finish(owner,id,lease,requeue);
      if(resume)InstallCoordinator.run(context,id).catch((error:Error)=>promptAction.showToast({message:errorText(error)}));
    }
  }
}
