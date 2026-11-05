import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { InstallJob } from '../jobs/InstallJob';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { AppDisplayName } from './AppDisplayName';
import { I18n } from './I18n';

export class InspectionField { key:string=''; label:string=''; value:string=''; }
export class InspectionSection { name:string=''; fields:InspectionField[]=[]; }
export class InstalledSelection {
  bundleName:string='';title:string='';versionName:string='';versionCode:number=0;appId:number=0;
  source:string='';moduleName:string='';mainAbility:string='';jobId:string='';updatedAt:number=0;
  /** Presentation evidence only; raw package metadata remains in versionName/versionCode. */
  displayReleaseLabel:string='';displayReleaseVersionCode:number=0;displayReleaseUpdateTime:number=0;
}
export class InstalledInspection {
  static selectedIcon?:image.PixelMap;
  static selection(job:InstallJob,title:string,appId:number,
    displayReleaseLabel:string='',displayReleaseUpdateTime:number=0):InstalledSelection {
    const row=new InstalledSelection();row.bundleName=job.bundleName;row.title=AppDisplayName.forBundle(job.bundleName,title);
    row.versionName=job.versionName;row.versionCode=job.versionCode;row.appId=appId;
    row.source=job.sourceUrl==='device'?I18n.t('设备识别'):job.sourceUrl==='local'?I18n.t('本地文件'):I18n.t('在线商店');
    row.moduleName=job.moduleName;row.mainAbility=job.mainAbility;row.jobId=job.id;row.updatedAt=job.updatedAt;
    row.displayReleaseLabel=displayReleaseLabel;row.displayReleaseVersionCode=job.versionCode;
    row.displayReleaseUpdateTime=displayReleaseUpdateTime;return row;
  }
  static async read(context:common.UIAbilityContext,bundleName:string):Promise<Record<string,Object>> {
    if(!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName))throw new Error(I18n.t('应用包名无效'));
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
        const version=InstalledAppRegistry.version(bundleName);
        const observedTime=InstalledAppRegistry.installationTime(bundleName,version) ||
          InstalledAppRegistry.signingIdentity(bundleName)?.updateTime || 0;
        const cachedTime=Number(cached['updateTime']||cached['installTime']||0);
        const observedName=InstalledAppRegistry.versionName(bundleName,version);
        if(Number(cached['versionCode'])===version && (!observedTime || cachedTime===observedTime) &&
          (!observedName || String(cached['versionName']??'')===observedName))return cached;
      }
      throw new Error(I18n.t('更多系统信息需要无线调试连接，当前保留已知安装信息'));
    }
    if(result['name']!==bundleName)throw new Error(I18n.t('系统返回的应用身份不匹配'));
    const text=JSON.stringify(result);
    if(text.length<=1024*1024){const names=JSON.parse(await store.get('_recent','[]') as string) as string[];
      const recent=names.filter((name:string)=>name!==bundleName);recent.push(bundleName);
      while(recent.length>24){const old=recent.shift();if(old)await store.delete(old);}
      await store.put(bundleName,text);await store.put('_recent',JSON.stringify(recent));await store.flush();}
    return result;
  }
  static sections(data:Record<string,Object>):InspectionSection[] {
    const sections:InspectionSection[]=[];const basic=new InspectionSection();basic.name=I18n.t('基本信息');
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
    const labels = new Map<string,string>([['name',I18n.t('名称')], ['displayName',I18n.t('显示名称')], ['versionCode',I18n.t('内部版本号')], ['versionName',I18n.t('软件版本')], ['appIdentifier',I18n.t('应用标识')], ['appId',I18n.t('应用 ID')], ['signatureInfo',I18n.t('签名信息')], ['fingerprint',I18n.t('证书指纹')], ['installTime',I18n.t('安装时间')], ['updateTime',I18n.t('更新时间')], ['applicationInfo',I18n.t('应用配置')], ['hapModuleInfos',I18n.t('安装模块')], ['reqPermissions',I18n.t('声明权限')], ['reqPermissionStates',I18n.t('权限授予状态')], ['reqPermissionDetails',I18n.t('权限明细')], ['abilityInfos',I18n.t('启动能力')], ['extensionInfos',I18n.t('扩展能力')], ['metadata',I18n.t('元数据')], ['moduleName',I18n.t('模块名称')], ['mainAbility',I18n.t('主入口')], ['mainElement',I18n.t('主入口')], ['enabled',I18n.t('已启用')], ['debug',I18n.t('调试构建')], ['appProvisionType',I18n.t('授权类型')], ['targetVersion',I18n.t('目标 API')], ['compatibleVersion',I18n.t('兼容 API')], ['minAPIVersion',I18n.t('最低 API')], ['targetAPIVersion',I18n.t('目标 API')], ['vendor',I18n.t('开发者')], ['deviceTypes',I18n.t('支持设备')], ['nativeLibraryPath',I18n.t('原生库路径')], ['codePath',I18n.t('安装路径')], ['hapPath',I18n.t('安装包路径')], ['bundleName',I18n.t('应用包名')], ['moduleType',I18n.t('模块类型')], ['uid',I18n.t('用户 ID')], ['gid',I18n.t('组 ID')], ['entryModuleName',I18n.t('入口模块')], ['removable',I18n.t('允许卸载')], ['isSystemApp',I18n.t('系统应用')], ['compressNativeLibs',I18n.t('原生库压缩')], ['label',I18n.t('显示名称')], ['icon',I18n.t('图标引用')], ['iconId',I18n.t('图标资源编号')], ['labelId',I18n.t('名称资源编号')]]);
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
    field.value=typeof value==='object'?JSON.stringify(value):typeof value==='boolean'?(value?I18n.t('是'):I18n.t('否')):String(value);
    if((last==='installTime'||last==='updateTime') && Number(value)>0)field.value=new Date(Number(value)).toLocaleString();
    fields.push(field);
  }
}
