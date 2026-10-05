import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { WirelessDebugLifecycle } from '../jobs/WirelessDebugLifecycle';
import { UIAbility, Want, AbilityConstant, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { BackgroundInstallTask } from '../jobs/BackgroundInstallTask';
import { ExternalInstallOpen } from '../jobs/ExternalInstallOpen';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { AppearancePreferences } from '../data/AppearancePreferences';

// 背景交给页面连续绘制，系统栏仅按主题切换文字颜色。
const BARS_LIGHT: window.SystemBarProperties = {
  statusBarColor: '#00000000',
  statusBarContentColor: '#17213A',
  navigationBarColor: '#00000000',
  navigationBarContentColor: '#17213A'
};
const BARS_DARK: window.SystemBarProperties = {
  statusBarColor: '#00000000',
  statusBarContentColor: '#EAF0F7',
  navigationBarColor: '#00000000',
  navigationBarContentColor: '#EAF0F7'
};

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private backgroundWindow?: window.Window;
  private contentReady: boolean = false;
  private onAppearanceChanged = (): void => { this.applyAppearance(); };
  private onAvoidAreaChange = (options: window.AvoidAreaOptions): void => {
    if (options.type === window.AvoidAreaType.TYPE_SYSTEM ||
      options.type === window.AvoidAreaType.TYPE_CUTOUT) this.syncStatusBarInset();
  };

  private syncStatusBarInset(): void {
    const mainWindow = this.mainWindow;
    if (!mainWindow) return;
    try {
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const top = Math.max(system.topRect.height, cutout.topRect.height);
      // onForeground / 避让回调可早于 loadContent，不能提前取得 UIContext。
      const screen = display.getDisplayByIdSync(mainWindow.getWindowProperties().displayId);
      const inset = top / screen.densityPixels;
      if (AppStorage.get<number>('statusBarInset') !== inset) {
        AppStorage.setOrCreate<number>('statusBarInset', inset);
      }
    } catch (_) {
      // 窗口切换或销毁中的暂态保留上一次安全区，下一次前台/避让回调重新读取。
    }
  }

  private isDark(): boolean {
    const mode = AppStorage.get<string>('appearanceMode') ?? 'system';
    return mode === 'dark' || (mode === 'system' &&
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  private applyAppearance(): Promise<void> {
    const dark = this.isDark();
    // 页面据此切换调色板（theme/Palette.ets）。
    if (AppStorage.get<boolean>('darkMode') !== dark) AppStorage.setOrCreate<boolean>('darkMode', dark);
    const mainWindow = this.mainWindow;
    if (!mainWindow) return Promise.resolve();
    try {
      // 重复设置窗口背景会触发原生渲染节点更新；同一窗口仅初始化一次。
      if (this.backgroundWindow !== mainWindow) {
        mainWindow.setWindowBackgroundColor('#00000000');
        this.backgroundWindow = mainWindow;
      }
    } catch (error) {
      console.warn('Unable to clear window background: ' + JSON.stringify(error));
    }
    // 保留系统手势条。恢复系统栏可能重置底色，因此最后再应用透明颜色。
    return mainWindow.setSpecificSystemBarEnabled('navigation', true).catch(() => {})
      .then(() => mainWindow.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {}))
      .then(() => mainWindow.setWindowSystemBarProperties(dark ? BARS_DARK : BARS_LIGHT))
      .catch((error: Error) => {
        console.warn('Unable to apply transparent system bars: ' + JSON.stringify(error));
      });
  }

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.context.eventHub.on('appearance-changed', this.onAppearanceChanged);
    BackgroundInstallTask.configure(this.context);
    InstallCoordinator.configure(this.context);
    WirelessDebugLifecycle.configure(this.context);
    AppStorage.setOrCreate<string>('qingqiFilesDir', this.context.filesDir);
    ExternalInstallOpen.receive(want);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if (ExternalInstallOpen.receive(want) && this.contentReady) ExternalInstallOpen.openPending();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const mainWindow = windowStage.getMainWindowSync();
    this.mainWindow = mainWindow;
    mainWindow.on('avoidAreaChange', this.onAvoidAreaChange);
    // 先完成全屏，再设置透明系统栏，避免全屏切换覆盖之前的颜色。
    mainWindow.setWindowLayoutFullScreen(true).catch((error: Error) => {
      console.warn('Unable to enable full-screen layout: ' + JSON.stringify(error));
    }).then(() => AppearancePreferences.load(this.context)).then(() => this.applyAppearance()).then(() => {
      if (this.mainWindow !== mainWindow) return;
      this.syncStatusBarInset();
      windowStage.loadContent('pages/Index', (error) => {
        if (error.code) {
          console.warn('Unable to load home page: ' + JSON.stringify(error));
          return;
        }
        // 页面加载后再同步，覆盖组件初始化和系统主题切换的窗口默认值。
        this.applyAppearance();
        this.syncStatusBarInset();
        this.contentReady = true;
        ExternalInstallOpen.openPending();
      });
    });
  }

  onWindowStageDestroy(): void {
    ExternalInstallOpen.suspendRouting();
    this.mainWindow?.off('avoidAreaChange', this.onAvoidAreaChange);
    this.mainWindow = undefined;
    this.backgroundWindow = undefined;
    this.contentReady = false;
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深浅色切换：更新系统栏并通知页面重渲染。
    this.context.config = config;
    this.applyAppearance();
  }

  onForeground(): void {
    ForegroundIdle.onForeground();
    BackgroundInstallTask.onForeground();
    WirelessDebugLifecycle.onForeground();
    // 从系统设置返回时也同步，覆盖部分设备在后台没有送达主题回调的情况。
    this.applyAppearance();
    this.syncStatusBarInset();
  }

  onBackground(): void {
    ForegroundIdle.onBackground();
    WirelessDebugLifecycle.onBackground();
  }

  onDestroy(): void { this.context.eventHub.off('appearance-changed', this.onAppearanceChanged); }
}
