import { UIAbility, Want, AbilityConstant, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 浅色 / 深色两套系统栏配色，与 theme/Palette.ets 保持一致。
 * 之前这里是写死的浅色，系统切到深色后状态栏和导航栏仍是白底，
 * 页面与系统栏对不上，底部看起来像"多出一条"。
 */
const BARS_LIGHT: window.SystemBarProperties = {
  statusBarColor: '#F9FAFD',
  statusBarContentColor: '#17213A',
  navigationBarColor: '#F9FAFD',
  navigationBarContentColor: '#17213A'
};
const BARS_DARK: window.SystemBarProperties = {
  statusBarColor: '#0B1220',
  statusBarContentColor: '#EAF0F7',
  navigationBarColor: '#0B1220',
  navigationBarContentColor: '#EAF0F7'
};

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

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
    // 不启用 setWindowLayoutFullScreen：那会让页面钻到状态栏下面，
    // 标题被压掉一截。
    // 去掉系统导航栏与手势指示条：页面底部已经有自己的 HdsTabs 导航，
    // 系统那一条与应用风格不搭，而且在深色下会留一条浅色横条。
    // 注意 setWindowSystemBarEnable(['status']) 在部分设备上不生效，
    // 要用 setSpecificSystemBarEnabled 逐个关。
    mainWindow.setSpecificSystemBarEnabled('navigation', false).catch(() => {});
    mainWindow.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    this.applyAppearance();
    windowStage.loadContent('pages/Index');
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深浅色切换：更新系统栏并通知页面重渲染。
    this.context.config = config;
    this.applyAppearance();
  }

  onForeground(): void {
    // 从系统设置返回时也同步，覆盖部分设备在后台没有送达主题回调的情况。
    this.applyAppearance();
  }
}
