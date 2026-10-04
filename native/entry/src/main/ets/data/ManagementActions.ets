import { InstallJob, InstallStage } from '../jobs/InstallJob';

export class ManagementAction {
  key:string; label:string; shortLabel:string; destructive:boolean;
  constructor(key:string,label:string,shortLabel:string,destructive:boolean=false){
    this.key=key;this.label=label;this.shortLabel=shortLabel;this.destructive=destructive;
  }
}

/** 左滑和长按复用相同的动作编号，显示文案与实际操作分开。 */
export class ManagementActions {
  static queue(job:InstallJob,signedIn:boolean,running:boolean,activeJobId:string):ManagementAction[]{
    const rows:ManagementAction[]=[];
    const failed=job.stage===InstallStage.TERMINAL_ERROR;
    if(failed&&job.renewalRequestedAt>0){rows.push(signedIn?
      new ManagementAction('renew','重新续签','续签'):new ManagementAction('login','前往登录','登录'));}
    else if(!failed&&!running&&job.stage!==InstallStage.QUEUED&&!activeJobId){rows.push(signedIn?
      new ManagementAction('continue','继续安装','继续'):new ManagementAction('login','前往登录','登录'));}
    rows.push(new ManagementAction('details','查看任务信息','信息'));
    rows.push(new ManagementAction('cleanup',failed?'清理记录':'取消并清理','清理',true));
    return rows;
  }
  static installed(renewalLabel:string):ManagementAction[]{
    return [new ManagementAction('renew',renewalLabel,'续签'),new ManagementAction('uninstall','卸载','卸载',true)];
  }
}
