import { NotificationOpen } from '../jobs/NotificationOpen';
import { DeviceOrbHost } from '../components/DeviceOrbHost';
import { DeviceOrbGestureGuard } from '../jobs/DeviceOrbGestureGuard';
import { InstallCoordinator } from '../jobs/InstallCoordinator';
import { WirelessDebugLifecycle } from '../jobs/WirelessDebugLifecycle';
import { UIAbility, Want, AbilityConstant, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { BackgroundInstallTask } from '../jobs/BackgroundInstallTask';
import { DeviceDiscovery } from '../jobs/DeviceDiscovery';
import { DeviceInstallTarget } from '../jobs/DeviceInstallTarget';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ExternalInstallOpen } from '../jobs/ExternalInstallOpen';
import { ForegroundIdle } from '../jobs/ForegroundIdle';
import { AppearancePreferences } from '../data/AppearancePreferences';
import { AppLanguagePreferences } from '../data/AppLanguagePreferences';
import { MaterialPreferences } from '../data/MaterialPreferences';
import { ManagementPreferences } from '../data/ManagementPreferences';
import { DiscoverSortPreferences } from '../data/DiscoverSortPreferences';
import { Palette } from '../theme/Palette';
import { ResumeFramePacing } from '../theme/ResumeFramePacing';
import { PrivacyConsent } from '../data/PrivacyConsent';

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
  private fileOpenWindow?: window.Window;
  private backgroundWindow?: window.Window;
  private backgroundColor: string = '';
  private contentReady: boolean = false;
  private businessConfigured: boolean = false;
  private privacySubscription: number = -1;
  private appearanceTail: Promise<void> = Promise.resolve();
  private onAppearanceChanged = (): void => { this.applyAppearance(); };
  private onWindowSizeChange = (size: window.Size): void => { this.syncStatusBarInset(size); };
  private onAvoidAreaChange = (options: window.AvoidAreaOptions): void => {
    if (options.type === window.AvoidAreaType.TYPE_SYSTEM ||
      options.type === window.AvoidAreaType.TYPE_CUTOUT) this.syncStatusBarInset();
  };

  private syncStatusBarInset(size?: window.Size): void {
    const mainWindow = this.mainWindow;
    if (!mainWindow) return;
    try {
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const top = Math.max(system.topRect.height, cutout.topRect.height);
      // onForeground / 避让回调可早于 loadContent，不能提前取得 UIContext。
      const properties = mainWindow.getWindowProperties();
      const screen = display.getDisplayByIdSync(properties.displayId);
      const density = screen.densityPixels;
      if (!Number.isFinite(density) || density <= 0) return;
      const inset = top / density;
      if (AppStorage.get<number>('statusBarInset') !== inset) {
        AppStorage.setOrCreate<number>('statusBarInset', inset);
      }
      const bottom = Math.max(system.bottomRect?.height ?? 0, cutout.bottomRect?.height ?? 0) / density;
      if (AppStorage.get<number>('navigationBottomInset') !== bottom) {
        AppStorage.setOrCreate<number>('navigationBottomInset', bottom);
      }
      // Resize callbacks carry the new physical size before some window properties update.
      const width = (size?.width ?? properties.windowRect?.width ?? 0) / density;
      const height = (size?.height ?? properties.windowRect?.height ?? 0) / density;
      if (Number.isFinite(width) && width > 0 && AppStorage.get<number>('windowWidth') !== width) {
        AppStorage.setOrCreate<number>('windowWidth', width);
      }
      if (Number.isFinite(height) && height > 0 && AppStorage.get<number>('windowHeight') !== height) {
        AppStorage.setOrCreate<number>('windowHeight', height);
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
    DeviceInstallTarget.localKind=DeviceInstallTarget.kind(deviceInfo.deviceType)||'phone';
    DeviceInstallTarget.localModel=DeviceInstallTarget.displayFact(deviceInfo.productModel);
    DeviceInstallTarget.localMarketName=DeviceInstallTarget.displayFact(deviceInfo.marketName);
    this.context.eventHub.on('appearance-changed', this.onAppearanceChanged);
    if (PrivacyConsent.isManaged()) this.privacySubscription = PrivacyConsent.subscribe(() => {
      this.syncBusinessServices();
      DeviceDiscovery.onPrivacyChanged();
      if (this.contentReady && PrivacyConsent.isBusinessAllowed()) WirelessDebugLifecycle.onForeground();
    });
    PrivacyConsent.configure(this.context);
    this.syncBusinessServices();
    AppStorage.setOrCreate<string>('qingqiFilesDir', this.context.filesDir);
    NotificationOpen.receive(want);
    ExternalInstallOpen.receive(want);
  }

  private syncBusinessServices(): void {
    if (!PrivacyConsent.isBusinessAllowed()) {
      DeviceDiscovery.onPrivacyChanged();
      DeviceOrbHost.dispose();
      if (this.businessConfigured) { WirelessDebugLifecycle.onBackground(); }
      return;
    }
    if (!this.businessConfigured) {
      BackgroundInstallTask.configure(this.context);
      InstallCoordinator.configure(this.context);
      WirelessDebugLifecycle.configure(this.context);
      this.businessConfigured = true;
    }
    if (this.contentReady && this.mainWindow) {
      // Keep the routing context on warm foreground returns; obtaining it again
      // adds work inside the desktop's scale animation without changing it.
      if (this.fileOpenWindow !== this.mainWindow) {
        const ui=this.mainWindow.getUIContext();
        ExternalInstallOpen.configure(ui); NotificationOpen.configure(ui);
        DeviceOrbHost.install(ui,this.context);
        this.fileOpenWindow = this.mainWindow;
      }
      if(!DeviceOrbHost.attached())DeviceOrbHost.install(this.mainWindow.getUIContext(),this.context);
      ExternalInstallOpen.openPending(); NotificationOpen.openPending();
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if(NotificationOpen.receive(want)){if(this.contentReady)NotificationOpen.openPending();return;}
    if (ExternalInstallOpen.receive(want) && this.contentReady) ExternalInstallOpen.openPending();
  }

  /**
   * 语言偏好必须在首页加载前就绪；单元测试或预览器没有该模块时直接跳过，
   * 保持默认中文，不能因为可选配置让整个 ability 初始化失败。
   */
  private loadLanguage(): Promise<void> {
    try {
      const task = AppLanguagePreferences.load(this.context);
      return task === undefined ? Promise.resolve() : task.catch(() => {});
    } catch (_) {
      return Promise.resolve();
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if(AppStorage.get<boolean>('deviceOrbForeground')===undefined)AppStorage.setOrCreate('deviceOrbForeground',true);
    const mainWindow = windowStage.getMainWindowSync();
    this.mainWindow = mainWindow;
    DeviceOrbGestureGuard.attach(mainWindow);
    mainWindow.on('avoidAreaChange', this.onAvoidAreaChange);
    mainWindow.on('windowSizeChange', this.onWindowSizeChange);
    // 先完成全屏，再设置透明系统栏，避免全屏切换覆盖之前的颜色。
    Promise.all([
      // Set the live window policy explicitly as well as the ability manifest.
      // Respect rotation lock and the orientations supported by this device.
      mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_UNSPECIFIED).catch((error: Error) => {
        console.warn('Unable to set automatic rotation: ' + JSON.stringify(error));
      }),
      mainWindow.setWindowLayoutFullScreen(true).catch((error: Error) => {
      console.warn('Unable to enable full-screen layout: ' + JSON.stringify(error));
      })
    ]).then(() => Promise.all([
      AppearancePreferences.load(this.context), ManagementPreferences.load(this.context), DiscoverSortPreferences.load(this.context),
      MaterialPreferences.load(this.context), this.loadLanguage()
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
        this.syncBusinessServices();
      });
    });
  }

  onWindowStageDestroy(): void {
    DeviceOrbGestureGuard.detach();
    DeviceOrbHost.dispose();
    ResumeFramePacing.stop();
    ExternalInstallOpen.suspendRouting(); NotificationOpen.suspendRouting();
    this.fileOpenWindow = undefined;
    this.mainWindow?.off('avoidAreaChange', this.onAvoidAreaChange);
    this.mainWindow?.off('windowSizeChange', this.onWindowSizeChange);
    this.mainWindow = undefined;
    this.backgroundWindow = undefined;
    this.backgroundColor = '';
    this.contentReady = false;
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深浅色切换：更新系统栏并通知页面重渲染。
    this.context.config = config;
    this.applyAppearance();
    this.syncStatusBarInset();
  }

  onForeground(): void {
    DeviceOrbGestureGuard.release();
    if(AppStorage.get<boolean>('deviceOrbForeground')!==true)AppStorage.setOrCreate('deviceOrbForeground',true);
    if (this.contentReady) ResumeFramePacing.start();
    ForegroundIdle.onForeground();
    PrivacyConsent.refresh();
    DeviceDiscovery.onForeground();
    if (PrivacyConsent.isBusinessAllowed()) {
      this.syncBusinessServices();
      BackgroundInstallTask.onForeground();
      WirelessDebugLifecycle.onForeground();
    }
    // 从系统设置返回时也同步，覆盖部分设备在后台没有送达主题回调的情况。
    this.applyAppearance();
    this.syncStatusBarInset();
  }

  onBackground(): void {
    DeviceOrbGestureGuard.release();
    if(AppStorage.get<boolean>('deviceOrbForeground')!==false)AppStorage.setOrCreate('deviceOrbForeground',false);
    DeviceDiscovery.onBackground();
    ResumeFramePacing.stop();
    ForegroundIdle.onBackground();
    if (this.businessConfigured) {WirelessDebugLifecycle.onBackground();}
  }

  onDestroy(): void {
    DeviceDiscovery.dispose();
    DeviceOrbHost.dispose();
    PrivacyConsent.unsubscribe(this.privacySubscription);
    this.context.eventHub.off('appearance-changed', this.onAppearanceChanged);
  }
}
