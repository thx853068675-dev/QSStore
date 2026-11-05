import { DeviceInstallTarget } from './DeviceInstallTarget';
import { InstallJob, InstallStage } from './InstallJob';
import { InstallTaskSnapshot } from './InstallTaskState';

/** Stable package identity for the card; exact batch identity for completion rows. */
export class DeviceInstallGroup {
  static deviceKey(job:InstallJob):string{try{return job.installTarget?DeviceInstallTarget.parse(job.installTarget).key:'local';}catch(_){return job.id;}}
  static key(job: InstallJob): string { return job.id.replace(/:device:[a-f0-9]{40,128}$/i,''); }
  static activeForApp(rows:InstallTaskSnapshot[],appId:number,bundleName:string=''):InstallTaskSnapshot[]{
    const seed=rows.filter((row)=>row.job.batchId&&row.job.appId===appId&&
      (!bundleName||!row.job.bundleName||row.job.bundleName===bundleName)&&
      row.job.stage!==InstallStage.INSTALLED&&row.job.stage!==InstallStage.SKIPPED&&row.job.stage!==InstallStage.TERMINAL_ERROR)
      .sort((a,b)=>(b.job.stageHistory[0]?.at??0)-(a.job.stageHistory[0]?.at??0))[0];
    return seed?DeviceInstallGroup.local(rows,seed.job):[];
  }
  static representatives(jobs: InstallJob[]): InstallJob[] {
    const seen:Set<string>=new Set();
    return jobs.filter((job)=>{const key=DeviceInstallGroup.key(job);if(seen.has(key))return false;seen.add(key);return true;});
  }
  private static order(rows:InstallTaskSnapshot[]):InstallTaskSnapshot[]{
    return rows.sort((a,b)=>{const left=DeviceInstallGroup.deviceKey(a.job),right=DeviceInstallGroup.deviceKey(b.job);
      return left===right?a.job.id.localeCompare(b.job.id):left==='local'?-1:right==='local'?1:left.localeCompare(right);});
  }
  static local(rows: InstallTaskSnapshot[], selected: InstallJob): InstallTaskSnapshot[] {
    return DeviceInstallGroup.order(rows.filter((row)=>selected.batchId ? row.job.batchId===selected.batchId : row.job.id===selected.id));
  }
  static management(rows: InstallTaskSnapshot[], seed: InstallJob): InstallTaskSnapshot[] {
    const key=DeviceInstallGroup.key(seed);
    const active=rows.filter((row)=>DeviceInstallGroup.key(row.job)===key&&row.job.stage!==InstallStage.INSTALLED&&row.job.stage!==InstallStage.SKIPPED);
    const batches=new Set(active.map((row)=>row.job.batchId).filter((id)=>Boolean(id)));
    return DeviceInstallGroup.order(rows.filter((row)=>DeviceInstallGroup.key(row.job)===key&&
      ((row.job.stage!==InstallStage.INSTALLED&&row.job.stage!==InstallStage.SKIPPED)||Boolean(row.job.batchId&&batches.has(row.job.batchId)))));
  }
}
