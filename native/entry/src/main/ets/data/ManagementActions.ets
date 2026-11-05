import { InstallJob, InstallStage } from '../jobs/InstallJob';
import { I18n } from './I18n';

export class ManagementAction {
  key:string; label:string; shortLabel:string; destructive:boolean;
  constructor(key:string,label:string,shortLabel:string,destructive:boolean=false){
    this.key=key;this.label=label;this.shortLabel=shortLabel;this.destructive=destructive;
  }
}

/** 左滑操作的显示文案与实际动作编号分开。 */
export class ManagementActions {
  static queue(job:InstallJob,signedIn:boolean,running:boolean,activeJobId:string):ManagementAction[]{
    const rows:ManagementAction[]=[];
    const failed=job.stage===InstallStage.TERMINAL_ERROR;
    if(failed&&job.renewalRequestedAt>0){rows.push(signedIn?
      new ManagementAction('renew',I18n.t('重新续签'),I18n.t('续签')):new ManagementAction('login',I18n.t('前往登录'),I18n.t('登录')));}
    else if(!failed&&!running&&job.stage!==InstallStage.QUEUED&&activeJobId!==job.id){rows.push(signedIn?
      new ManagementAction('continue',I18n.t('继续安装'),I18n.t('继续')):new ManagementAction('login',I18n.t('前往登录'),I18n.t('登录')));}
    rows.push(new ManagementAction('details',I18n.t('查看任务信息'),I18n.t('信息')));
    rows.push(new ManagementAction('cleanup',failed?I18n.t('清理记录'):I18n.t('取消并清理'),I18n.t('清理'),true));
    return rows;
  }
  static installed(renewalLabel:string,updatesDisabled:boolean=false):ManagementAction[]{
    return [new ManagementAction('renew',renewalLabel,I18n.t('续签')),updatesDisabled?
      new ManagementAction('resumeUpdates',I18n.t('续更'),I18n.t('续更')):
      new ManagementAction('stopUpdates',I18n.t('停更'),I18n.t('停更')),
      new ManagementAction('uninstall',I18n.t('卸载'),I18n.t('卸载'),true)];
  }
}
