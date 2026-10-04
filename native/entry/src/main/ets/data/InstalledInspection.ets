import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { InstallJob } from '../jobs/InstallJob';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';

export class InspectionField { key:string=''; label:string=''; value:string=''; }
export class InspectionSection { name:string=''; fields:InspectionField[]=[]; }
export class InstalledSelection {
  bundleName:string='';title:string='';versionName:string='';versionCode:number=0;appId:number=0;
  source:string='';moduleName:string='';mainAbility:string='';jobId:string='';updatedAt:number=0;
}
export class InstalledInspection {
  static selectedIcon?:image.PixelMap;
  static selection(job:InstallJob,title:string,appId:number):InstalledSelection {
    const row=new InstalledSelection();row.bundleName=job.bundleName;row.title=InstalledAppRegistry.displayName(job.bundleName)||title;
    row.versionName=job.versionName;row.versionCode=job.versionCode;row.appId=appId;
    row.source=job.sourceUrl==='device'?'设备识别':job.sourceUrl==='local'?'本地文件':'在线商店';
    row.moduleName=job.moduleName;row.mainAbility=job.mainAbility;row.jobId=job.id;row.updatedAt=job.updatedAt;return row;
  }
  static async read(context:common.UIAbilityContext,bundleName:string):Promise<Record<string,Object>> {
    if(!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName))throw new Error('应用包名无效');
    let result:Record<string,Object>={};
    try {result=JSON.parse(JSON.stringify(bundleManager.getBundleInfoSync(bundleName,bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION|bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_HAP_MODULE|bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_ABILITY|bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION|bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO))) as Record<string,Object>;} catch(_){}
    const bridge=new HdcDeviceBridge(context);
    if(await bridge.connected()) {
      try {const details=await bridge.installedDetails(bundleName);Object.keys(details).forEach((key:string)=>result[key]=details[key]);}catch(error){if(Object.keys(result).length===0)throw new Error(String(error));}
    }
    const store=await preferences.getPreferences(context,'installed-inspection');
    if(Object.keys(result).length===0) {
      const text=await store.get(bundleName,'') as string;
      if(text.length>0 && text.length<=1024*1024) {
        const cached=JSON.parse(text) as Record<string,Object>;
        if(Number(cached['versionCode'])===InstalledAppRegistry.version(bundleName))return cached;
      }
      throw new Error('更多系统信息需要无线调试连接，当前保留已知安装信息');
    }
    if(result['name']!==bundleName)throw new Error('系统返回的应用身份不匹配');
    const text=JSON.stringify(result);
    if(text.length<=1024*1024){const names=JSON.parse(await store.get('_recent','[]') as string) as string[];
      const recent=names.filter((name:string)=>name!==bundleName);recent.push(bundleName);
      while(recent.length>24){const old=recent.shift();if(old)await store.delete(old);}
      await store.put(bundleName,text);await store.put('_recent',JSON.stringify(recent));await store.flush();}
    return result;
  }
  static sections(data:Record<string,Object>):InspectionSection[] {
    const sections:InspectionSection[]=[];const basic=new InspectionSection();basic.name='基本信息';
    Object.keys(data).forEach((key:string)=>{
      const value=data[key];
      const section=typeof value==='object' && value!==null && Object.keys(value).length>0?new InspectionSection():basic;
      if(section!==basic)section.name=InstalledInspection.label(key);
      InstalledInspection.flatten(key,value,section.fields,0);if(section!==basic && section.fields.length)sections.push(section);
    });if(basic.fields.length)sections.unshift(basic);return sections;
  }
  static filter(sections:InspectionSection[],query:string):InspectionSection[] {
    const needle=query.trim().toLowerCase();if(!needle)return sections;
    const matches:InspectionSection[]=[];
    for(const section of sections){const fields=section.fields.filter((field:InspectionField)=>section.name.toLowerCase().includes(needle)||field.key.toLowerCase().includes(needle)||field.label.toLowerCase().includes(needle)||field.value.toLowerCase().includes(needle));
      if(fields.length){const match=new InspectionSection();match.name=section.name;match.fields=fields;matches.push(match);}}
    return matches;
  }
  static label(key:string):string {
    const labels = new Map<string,string>([['name','名称'], ['displayName','显示名称'], ['versionCode','内部版本号'], ['versionName','软件版本'], ['appIdentifier','应用标识'], ['appId','应用 ID'], ['signatureInfo','签名信息'], ['fingerprint','证书指纹'], ['installTime','安装时间'], ['updateTime','更新时间'], ['applicationInfo','应用配置'], ['hapModuleInfos','安装模块'], ['reqPermissions','声明权限'], ['reqPermissionStates','权限授予状态'], ['reqPermissionDetails','权限明细'], ['abilityInfos','启动能力'], ['extensionInfos','扩展能力'], ['metadata','元数据'], ['moduleName','模块名称'], ['mainAbility','主入口'], ['mainElement','主入口'], ['enabled','已启用'], ['debug','调试构建'], ['appProvisionType','授权类型'], ['targetVersion','目标 API'], ['compatibleVersion','兼容 API'], ['minAPIVersion','最低 API'], ['targetAPIVersion','目标 API'], ['vendor','开发者'], ['deviceTypes','支持设备'], ['nativeLibraryPath','原生库路径'], ['codePath','安装路径'], ['hapPath','安装包路径'], ['bundleName','应用包名'], ['moduleType','模块类型'], ['uid','用户 ID'], ['gid','组 ID'], ['entryModuleName','入口模块'], ['removable','允许卸载'], ['isSystemApp','系统应用'], ['compressNativeLibs','原生库压缩'], ['label','显示名称'], ['icon','图标引用'], ['iconId','图标资源编号'], ['labelId','名称资源编号']]);
    return labels.get(key)??key;
  }
  private static flatten(path:string,value:Object,fields:InspectionField[],depth:number):void {
    if(value===undefined || value===null)return;
    if(typeof value==='string' && value.trim().length===0)return;
    if(typeof value==='object') {
      const keys=Object.keys(value);if(keys.length===0)return;
      if(depth<12){keys.forEach((key:string)=>InstalledInspection.flatten(path+'.'+key,(value as Record<string,Object>)[key],fields,depth+1));return;}
    }
    const field=new InspectionField();field.key=path;const last=path.split('.').pop()??path;field.label=InstalledInspection.label(last);
    field.value=typeof value==='object'?JSON.stringify(value):typeof value==='boolean'?(value?'是':'否'):String(value);
    if((last==='installTime'||last==='updateTime') && Number(value)>0)field.value=new Date(Number(value)).toLocaleString();
    fields.push(field);
  }
}
