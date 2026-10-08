import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { WirelessDebugLifecycle } from '../jobs/WirelessDebugLifecycle';
import { UIAbility, Want, AbilityConstant, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { BackgroundInstallTask } from '../jobs/BackgroundInstallTask';
import { ExternalInstallOpen } from '../jobs/ExternalInstallOpen';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { AppearancePreferences } from '../data/AppearancePreferences';
import { ManagementPreferences } from '../data/ManagementPreferences';
import { DiscoverSortPreferences } from '../data/DiscoverSortPreferences';
import { Palette } from '../theme/Palette';
import { ResumeFramePacing } from '../theme/ResumeFramePacing';

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
  private backgroundColor: string = '';
  private contentReady: boolean = false;
  private appearanceTail: Promise<void> = Promise.resolve();
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

  private sameBarColor(value: string | undefined, expected: string | undefined): boolean {
    const actual = (value ?? '').toLowerCase();
    const wanted = (expected ?? '').toLowerCase();
    return (actual.length === 7 ? '#ff' + actual.substring(1) : actual) ===
      (wanted.length === 7 ? '#ff' + wanted.substring(1) : wanted);
  }

  private systemBarsMatch(mainWindow: window.Window, bars: window.SystemBarProperties): boolean {
    try {
      const current = mainWindow.getWindowSystemBarProperties();
      return this.sameBarColor(current.statusBarColor, bars.statusBarColor) &&
        this.sameBarColor(current.statusBarContentColor, bars.statusBarContentColor) &&
        this.sameBarColor(current.navigationBarColor, bars.navigationBarColor) &&
        this.sameBarColor(current.navigationBarContentColor, bars.navigationBarContentColor);
    } catch (_) { return false; }
  }

  private applyAppearance(): Promise<void> {
    const dark = this.isDark();
    // 页面据此切换调色板（theme/Palette.ets）。
    if (AppStorage.get<boolean>('darkMode') !== dark) AppStorage.setOrCreate<boolean>('darkMode', dark);
    const mainWindow = this.mainWindow;
    if (!mainWindow) return Promise.resolve();
    try {
      // Match the opaque page backing; system bars remain transparent above it.
      // Reuse the backing on warm return rather than changing its render node.
      const background = Palette.forMode(dark).bg;
      if (this.contentReady && (this.backgroundWindow !== mainWindow || this.backgroundColor !== background)) {
        mainWindow.setWindowBackgroundColor(background);
        this.backgroundWindow = mainWindow;
        this.backgroundColor = background;
      }
    } catch (error) {
      console.warn('Unable to apply window background: ' + JSON.stringify(error));
    }
    // Read the actual window state. Warm returns do not rewrite unchanged bars
    // during the desktop's scale animation; reset defaults still get restored.
    const apply = this.appearanceTail.then(async (): Promise<void> => {
      if (this.mainWindow !== mainWindow) return;
      const bars = this.isDark() ? BARS_DARK : BARS_LIGHT;
      if (this.systemBarsMatch(mainWindow, bars)) return;
      // Restoring navigation may reset its background, so apply colors last.
      await mainWindow.setSpecificSystemBarEnabled('navigation', true).catch(() => {});
      await mainWindow.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {});
      await mainWindow.setWindowSystemBarProperties(bars);
    });
    this.appearanceTail = apply.catch((error: Error) => {
      console.warn('Unable to apply transparent system bars: ' + JSON.stringify(error));
    });
    return this.appearanceTail;
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
    }).then(() => Promise.all([
      AppearancePreferences.load(this.context), ManagementPreferences.load(this.context), DiscoverSortPreferences.load(this.context)
    ])).then(() => this.applyAppearance()).then(() => {
      if (this.mainWindow !== mainWindow) return;
      this.syncStatusBarInset();
      windowStage.loadContent('pages/Index', (error) => {
        if (error.code) {
          console.warn('Unable to load home page: ' + JSON.stringify(error));
          return;
        }
        if (this.mainWindow !== mainWindow) return;
        this.contentReady = true;
        ResumeFramePacing.start();
        // 页面加载后再同步，覆盖组件初始化和系统主题切换的窗口默认值。
        this.applyAppearance();
        this.syncStatusBarInset();
        ExternalInstallOpen.configure(mainWindow.getUIContext());
        ExternalInstallOpen.openPending();
      });
    });
  }

  onWindowStageDestroy(): void {
    ResumeFramePacing.stop();
    ExternalInstallOpen.suspendRouting();
    this.mainWindow?.off('avoidAreaChange', this.onAvoidAreaChange);
    this.mainWindow = undefined;
    this.backgroundWindow = undefined;
    this.backgroundColor = '';
    this.contentReady = false;
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深浅色切换：更新系统栏并通知页面重渲染。
    this.context.config = config;
    this.applyAppearance();
  }

  onForeground(): void {
    if (this.contentReady) ResumeFramePacing.start();
    ForegroundIdle.onForeground();
    BackgroundInstallTask.onForeground();
    WirelessDebugLifecycle.onForeground();
    // 从系统设置返回时也同步，覆盖部分设备在后台没有送达主题回调的情况。
    this.applyAppearance();
    this.syncStatusBarInset();
  }

  onBackground(): void {
    ResumeFramePacing.stop();
    ForegroundIdle.onBackground();
    WirelessDebugLifecycle.onBackground();
  }

  onDestroy(): void { this.context.eventHub.off('appearance-changed', this.onAppearanceChanged); }
}
