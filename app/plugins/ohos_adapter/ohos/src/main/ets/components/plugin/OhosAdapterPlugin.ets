import {
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityAware
} from '@ohos/flutter_ohos';

import fs from '@ohos.file.fs';
import  { fileUri, picker } from '@kit.CoreFileKit';
import { common, Want } from '@kit.AbilityKit';
import { hdcServer } from 'libhdc_z.so';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import HdcUtils from './HdcUtils';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';


/** OhosAdapterPlugin **/
export default class OhosAdapterPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  binding: AbilityPluginBinding | null  = null;
  constructor() {
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.binding = binding;
  }

  onDetachedFromAbility(): void {
  }

  getUniqueClassName(): string {
    return "OhosAdapterPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "ohos_adapter");
    this.channel.setMethodCallHandler(this)
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const  context = this.binding!.getAbility().context;
    if (call.method == "getPlatformVersion") {
      result.success("OpenHarmony ^ ^ ")
    } else if(call.method == "log") {
      // 供 Dart 侧写系统日志。`print` 在鸿蒙上不保证进 hilog，
      // 排查线上问题时需要一条可靠通道。
      const msg = call.argument("msg") as string;
      hilog.info(0x0000, 'StarHub', '%{public}s', msg);
      result.success("")
    } else if(call.method == "getHuaweiProfile") {
      const request = new authentication.HuaweiIDProvider()
        .createAuthorizationWithHuaweiIDRequest();
      request.scopes = ['profile'];
      request.forceAuthorization = (call.argument('force') as boolean) ?? false;
      request.state = util.generateRandomUUID();
      const controller = new authentication.AuthenticationController(context);
      controller.executeRequest(request).then((response) => {
        const profile = response as authentication.AuthorizationWithHuaweiIDResponse;
        if (profile.state !== request.state) {
          result.error('ACCOUNT_KIT_STATE', '华为帐号授权状态校验失败', null);
          return;
        }
        result.success({
          avatarUrl: profile.data?.avatarUri ?? '',
          nickName: profile.data?.nickName ?? ''
        });
      }).catch((error: BusinessError) => {
        result.error('ACCOUNT_KIT', `${error.code ?? ''}: ${error.message ?? error}`, null);
      });
    } else if(call.method == "openInstalledApp") {
      const bundle = call.argument('bundle') as string;
      const ability = (call.argument('ability') as string) ?? '';
      const moduleName = (call.argument('module') as string) ?? '';
      openInstalledApp(bundle, ability, moduleName, context)
        .then((ok: boolean) => result.success(ok));
    } else if(call.method == "startWant") {
      // 通用 startAbility：系统设置页必须显式给 bundleName + abilityName + uri，
      // 只给 action/uri 是不够的（实测 uri='system_wireless_commissioning'
      // 必须配合 bundleName 与 MainAbility 才能真正拉起设置）。
      const bundle = call.argument("bundle") as string;
      const ability = call.argument("ability") as string;
      const uri = (call.argument("uri") as string) ?? "";
      startWant(bundle, ability, uri, context).then((ok: boolean)=>{
        result.success(ok)
      }).catch(()=>{
        result.success(false)
      })
    } else if(call.method == "openUrl") {
      let url = call.argument("url") as string;
      requestBackground()
      openUrl(url, context)
      result.success("")
    }
    else if(call.method == "selectFile") {
      let filter = call.argument("filter") as string[];
      selectFile(context, filter).then((f)=>{
        result.success(f)
      })
    }
    else if(call.method == "tempDir") {
      result.success(context.tempDir)
    }
    else if(call.method == "deviceType") {
      result.success(deviceInfo.deviceType)
    }
    else if(call.method == "hasJit") {
      result.success(false)
    }
    else if(call.method == "appDir") {
      result.success(context.filesDir)
    }
    else if(call.method == "hdcCmd") {
      const args = call.argument("args") as string;
      HdcUtils.hdcCmd(context, args).then((res)=>{
        result.success(res)
      })
    }
     else if(call.method == "signCmd") {
      const args = call.argument("args") as string;

      HdcUtils.GoSign(args).then((res)=>{
        result.success(res)
      })
    } else if(call.method == "startServer") {
      hdcServer(context.tempDir)
    } else if(call.method == "getKey") {
      let ret = preferences.getPreferencesSync(context,{name:"hap_installer"})
      const key = call.argument("key") as string;
      result.success(ret.getSync(key,"127.0.0.1:12345") as string)
    } else if(call.method == "setKey") {
      let ret = preferences.getPreferencesSync(context,{name:"hap_installer"})
      const key = call.argument("key") as string;
      const value = call.argument("value") as string;
      ret.putSync(key, value);
      ret.flush().then(()=>{
        result.success(null)
      });
    }
    else {
      result.notImplemented()
    }
  }
}

async function selectFile(context: common.Context, filter: string[] | null = null) { // 需确保 context 由 UIAbilityContext 转换而来
  try {
    let documentSelectOptions = new picker.DocumentSelectOptions();
    documentSelectOptions.maxSelectNumber =1;
    documentSelectOptions.fileSuffixFilters = filter ?? ["hap","app","hsp"]
    let documentPicker = new picker.DocumentViewPicker(context);
    const documentSelectResult = await documentPicker.select(documentSelectOptions)
    console.info('testTag' + JSON.stringify(documentSelectResult));
    if(documentSelectResult.length > 0){
      const targetUri = documentSelectResult[0]
      const sl = targetUri.split("/")
      let hapPath =  context.filesDir + "/" + sl[sl.length - 1].replace(/\s+/g, '_')
      await fs.copy(targetUri, fileUri.getUriFromPath(hapPath))
      console.info('testTag selectFile' + hapPath);
      return hapPath
    }
    return null;
  } catch (err) {
    console.error('testTag err: ' + err.message, err.stack);
    return null;
  }
}

export function  openUrl(url: string, context:common.Context): void{
  let want: Want = {
    action: 'ohos.want.action.viewData',
    // entities can be omitted.
    entities: ['entity.system.browsable'],
    uri: url
  };
  try {
    (context as common.UIAbilityContext).startAbility(want)
  } catch (paramError) {
    console.error("openUrl error",paramError)
  }
}

function requestBackground(){
   try {
      let delayInfo = backgroundTaskManager.requestSuspendDelay("open url", () => {
        console.info("Request suspension delay will time out.");
      })
      let taskId = delayInfo.requestId;
    } catch (error) {
      console.error(`requestSuspendDelay failed. code is ${error.code} message is ${error.message}`);
    }
}

/// 通用 startAbility。
///
/// 系统设置页的正确打开方式（照搬轻启 0.9.51 的实测实现）：
///   bundleName  = com.huawei.hmos.settings
///   abilityName = com.huawei.hmos.settings.MainAbility
///   uri         = system_wireless_commissioning（无线调试）
///                 about_device（关于本机，用于开启开发者模式）
///   action      = ohos.want.action.viewData
///
/// 只给 uri/action 而不给 bundleName 与 abilityName 时，
/// 系统会返回 "start ability successfully" 但**实际不打开任何页面**。
export async function startWant(
  bundle: string, ability: string, uri: string, context: common.Context
): Promise<boolean> {
  try {
    const want: Want = {
      bundleName: bundle,
      abilityName: ability,
      uri: uri,
      action: 'ohos.want.action.viewData'
    };
    await (context as common.UIAbilityContext).startAbility(want);
    return true;
  } catch (e) {
    console.error('StarHub startWant failed: ' + uri);
    return false;
  }
}

export async function openInstalledApp(
  bundle: string, storedAbility: string, storedModule: string, context: common.Context
): Promise<boolean> {
  if (!bundle) return false;
  // 新安装记录保存 HAP 内的 mainElement；旧记录兼容 EntryAbility。
  const ability = storedAbility || 'EntryAbility';
  const moduleName = storedModule;
  try {
    const want: Want = { bundleName: bundle, abilityName: ability };
    if (moduleName) want.moduleName = moduleName;
    await (context as common.UIAbilityContext).startAbility(want);
    return true;
  } catch (e) {
    hilog.error(0x0000, 'StarHub', 'open installed app failed: %{public}s', `${e}`);
    return false;
  }
}
