
import { FlutterAbility, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { AbilityConstant, Configuration, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';

export default class EntryAbility extends FlutterAbility implements MethodCallHandler {
  chanel?: MethodChannel;
  private navigationChannel?: MethodChannel;
  private qingqiWindow?: window.Window;

  private updateSystemBars(colorMode?: number): void {
    const dark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.qingqiWindow?.setWindowSystemBarProperties({
      statusBarColor: dark ? '#101722' : '#F6F7FB',
      statusBarContentColor: dark ? '#FFFFFF' : '#142033',
      navigationBarColor: dark ? '#101722' : '#F6F7FB',
      navigationBarContentColor: dark ? '#FFFFFF' : '#142033'
    }).catch(() => {});
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      this.qingqiWindow = mainWindow;
      this.updateSystemBars(this.context.config.colorMode);
    }).catch(() => {});
  }

  onConfigurationUpdate(config: Configuration): void {
    super.onConfigurationUpdate(config);
    this.updateSystemBars(config.colorMode);
  }
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.chanel = new MethodChannel(flutterEngine.dartExecutor, "com.tonghongxiang.xiaobaiquietstart/openFile");
    this.navigationChannel = new MethodChannel(flutterEngine.dartExecutor, 'qingqi/native_bottom_tabs');
    this.navigationChannel.setMethodCallHandler(this);
    this.context.eventHub.on('NATIVE_TAB_TAP', (index: number) => {
      this.navigationChannel?.invokeMethod('navigationTap', index);
    });
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'setNavigation') {
      result.notImplemented();
      return;
    }
    const visible = call.argument('visible') as boolean;
    const index = call.argument('index') as number;
    AppStorage.setOrCreate<boolean>('nativeTabsVisible', visible);
    AppStorage.setOrCreate<number>('nativeTabIndex', index);
    result.success(null);
  }
  openFile(){

    this.chanel?.invokeMethod("openFile", {url: "test"},{
      success:() =>{
        console.log('openFile', "success");
      },
      error: ()=>{
        console.log('openFile', "error");
      },
      notImplemented: ()=>{
        console.log('openFile', "notImplemented");
      }
    });
  }

  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    super.onNewWant(want,launchParams)
    let uri = want.uri;
    if (uri && uri != "") {
      this.sendFileUrl(uri)
    }
  }

  async sendFileUrl(targetUri: string){
    console.log('openFile', 'onNewWant' + targetUri);
    const sl = targetUri.split("/")
    let hapPath = this.context.filesDir + "/" + sl[sl.length - 1].trim()
    await fs.copy(targetUri, fileUri.getUriFromPath(hapPath))
    this.chanel?.invokeMethod("openFile", hapPath);
  }
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    await super.onCreate(want, launchParam)
    let uri = want.uri;
    if (uri && uri != "") {
      this.sendFileUrl(uri)
    }
  }
}
