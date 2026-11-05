import { InstalledAppRegistry } from './InstalledAppRegistry';
import { I18n } from '../data/I18n';

/** Route-independent install request. Only the currently visible page presents it. */
export class InstallConfirmation {
  static dataLossTitle(renewal: boolean, bundleName: string = ''): string {
    if (bundleName.length > 0 && InstalledAppRegistry.isAppGallery(bundleName)) return I18n.t('应用包名冲突');
    return renewal ? I18n.t('无法保留数据续签') : I18n.t('需要卸载旧版');
  }

  static dataLossMessage(renewal: boolean, self: boolean, bundleName: string = '',
    targetName: string = ''): string {
    if (bundleName.length > 0 && InstalledAppRegistry.isAppGallery(bundleName)) {
      const installedName = InstalledAppRegistry.displayName(bundleName) || bundleName;
      const incomingName = targetName.trim() || I18n.t('所选安装包');
      return I18n.t('已安装的「') + installedName + I18n.t('」来自华为应用市场，与准备安装的「') + incomingName +
        I18n.t('」使用相同包名（') + bundleName + I18n.t('），不能同时安装。继续将卸载「') + installedName +
        I18n.t('」，再安装「') + incomingName + I18n.t('」；「') + installedName +
        I18n.t('」的缓存、设置和登录状态都会清除。取消将保留「') + installedName + I18n.t('」。是否继续？');
    }
    if (self) return I18n.t('继续会先卸载轻启·安装器，再安装') + (renewal ? I18n.t('续签后的版本') : I18n.t('新版')) +
      I18n.t('。登录状态、本地安装记录、无线调试配对和本地签名材料会清除；签名身份会在卸载前备份。是否继续？');
    return (renewal ? I18n.t('当前签名身份无法保留数据续签。') : I18n.t('系统无法保留数据覆盖更新。')) +
      I18n.t('继续会先卸载旧版，再安装') + (renewal ? I18n.t('续签后的同版本应用') : I18n.t('新版')) +
      I18n.t('；该应用的缓存、设置和登录状态都会清除。取消会保留旧应用。是否继续？');
  }

  static dataLossAction(renewal: boolean): string {
    return renewal ? I18n.t('清除数据并续签') : I18n.t('清除数据并安装');
  }

  private static requests: string[] = [];
  private static presenting: string = '';
  private static presenter: number = -1;
  private static lease: number = 0;
  private static revisions:Map<string,number>=new Map();
  private static claimedRevision:number=0;
  private static owner: number = -1;
  private static nextId: number = 0;
  private static listeners: Map<number, (jobId: string) => void> = new Map();

  static subscribe(listener: (jobId: string) => void): number {
    const id = ++InstallConfirmation.nextId;
    InstallConfirmation.listeners.set(id, listener);
    return id;
  }

  private static notify(id: number, jobId: string): void {
    try { InstallConfirmation.listeners.get(id)?.(jobId); } catch (_) {}
  }

  static activate(id: number): void {
    if (InstallConfirmation.owner !== id) InstallConfirmation.notify(InstallConfirmation.owner, '');
    InstallConfirmation.owner = id;
    InstallConfirmation.pump();
  }

  static isOwner(id: number): boolean {
    return id > 0 && InstallConfirmation.owner === id && InstallConfirmation.listeners.has(id);
  }

  static isRequested(id: string): boolean { return InstallConfirmation.requests.includes(id); }

  static deactivate(id: number): void {
    if (InstallConfirmation.owner !== id) return;
    InstallConfirmation.notify(id, '');
    InstallConfirmation.owner = -1;
  }

  static unsubscribe(id: number): void {
    InstallConfirmation.deactivate(id);
    InstallConfirmation.listeners.delete(id);
  }

  private static pump():void{
    if(InstallConfirmation.presenting||InstallConfirmation.owner<0)return;
    InstallConfirmation.notify(InstallConfirmation.owner,InstallConfirmation.requests[0]??'');
  }
  static claim(owner:number,id:string):number{
    if(!InstallConfirmation.isOwner(owner)||InstallConfirmation.presenting||InstallConfirmation.requests[0]!==id)return 0;
    InstallConfirmation.presenting=id;InstallConfirmation.presenter=owner;
    InstallConfirmation.claimedRevision=InstallConfirmation.revisions.get(id)??0;
    return ++InstallConfirmation.lease;
  }
  static valid(owner:number,id:string,lease:number):boolean{
    return InstallConfirmation.isOwner(owner)&&InstallConfirmation.presenter===owner&&
      InstallConfirmation.presenting===id&&InstallConfirmation.lease===lease&&InstallConfirmation.requests.includes(id)&&
      InstallConfirmation.claimedRevision===(InstallConfirmation.revisions.get(id)??0);
  }
  static finish(owner:number,id:string,lease:number,requeue:boolean=false):void{
    if(InstallConfirmation.presenter!==owner||InstallConfirmation.presenting!==id||InstallConfirmation.lease!==lease)return;
    InstallConfirmation.presenting='';InstallConfirmation.presenter=-1;
    if(!requeue&&InstallConfirmation.claimedRevision===(InstallConfirmation.revisions.get(id)??0)){
      InstallConfirmation.requests=InstallConfirmation.requests.filter((key)=>key!==id);
    }
    if(!InstallConfirmation.requests.includes(id))InstallConfirmation.revisions.delete(id);
    InstallConfirmation.pump();
  }
  static request(jobId: string): void {
    if(!jobId)return;
    if(!InstallConfirmation.requests.includes(jobId)){
      InstallConfirmation.requests.push(jobId);
      InstallConfirmation.revisions.set(jobId,(InstallConfirmation.revisions.get(jobId)??0)+1);
    }
    InstallConfirmation.pump();
  }
  static clear(jobId: string): void {
    InstallConfirmation.requests=InstallConfirmation.requests.filter((id)=>id!==jobId);
    // A native dialog still visible owns its lease until its promise settles.
    // Cancellation must not allow the next target to open underneath it.
    InstallConfirmation.pump();
  }
}
