import { UIAbility, Want, AbilityConstant, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';

// 背景交给页面连续绘制，系统栏仅按主题切换文字颜色。
const BARS_LIGHT: window.SystemBarProperties = {
  statusBarColor: '#00000000',
  statusBarContentColor: '#17213A',
  navigationBarColor: '#F9FAFD',
  navigationBarContentColor: '#17213A'
};
const BARS_DARK: window.SystemBarProperties = {
  statusBarColor: '#00000000',
  statusBarContentColor: '#EAF0F7',
  navigationBarColor: '#0B1220',
  navigationBarContentColor: '#EAF0F7'
};

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
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
      AppStorage.setOrCreate<number>('statusBarInset', top / screen.densityPixels);
    } catch (_) {
      // 窗口切换或销毁中的暂态保留上一次安全区，下一次前台/避让回调重新读取。
    }
  }

  private isDark(): boolean {
    return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private applyAppearance(): void {
    const dark = this.isDark();
    // 页面据此切换调色板（theme/Palette.ets）。
    AppStorage.setOrCreate<boolean>('darkMode', dark);
    this.mainWindow?.setWindowSystemBarProperties(dark ? BARS_DARK : BARS_LIGHT)
      .catch(() => {});
  }

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate<string>('qingqiFilesDir', this.context.filesDir);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const mainWindow = windowStage.getMainWindowSync();
    this.mainWindow = mainWindow;
    mainWindow.on('avoidAreaChange', this.onAvoidAreaChange);
    // 去掉系统导航栏与手势指示条：页面底部已经有自己的 HdsTabs 导航，
    // 系统那一条与应用风格不搭，而且在深色下会留一条浅色横条。
    // 注意 setWindowSystemBarEnable(['status']) 在部分设备上不生效，
    // 要用 setSpecificSystemBarEnabled 逐个关。
    mainWindow.setSpecificSystemBarEnabled('navigation', false).catch(() => {});
    mainWindow.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    this.applyAppearance();
    // 页面底色延伸到系统栏下；内容按实际安全区避让，不写死状态栏高度。
    mainWindow.setWindowLayoutFullScreen(true).catch(() => {}).then(() => {
      this.syncStatusBarInset();
      windowStage.loadContent('pages/Index');
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow?.off('avoidAreaChange', this.onAvoidAreaChange);
    this.mainWindow = undefined;
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深浅色切换：更新系统栏并通知页面重渲染。
    this.context.config = config;
    this.applyAppearance();
  }

  onForeground(): void {
    // 从系统设置返回时也同步，覆盖部分设备在后台没有送达主题回调的情况。
    this.applyAppearance();
    this.syncStatusBarInset();
  }
}
