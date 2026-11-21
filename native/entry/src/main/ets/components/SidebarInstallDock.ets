import { HdsTabs } from '@kit.UIDesignKit';
import { I18n } from '../data/I18n';
import { MaterialPreferences } from '../data/MaterialPreferences';
import { Palette } from '../theme/Palette';
import { StoreLayout, StoreNavigationSurface } from '../theme/StoreDesign';
import { StoreMaterial } from '../theme/StoreMaterial';

export class SidebarInstallView {
  appId: number;
  label: string;
  accessibilityLabel: string;
  enabled: boolean;
  progress: number;

  constructor(appId: number = 0, label: string = '', accessibilityLabel: string = '',
    enabled: boolean = false, progress: number = -1) {
    this.appId = appId;
    this.label = label;
    this.accessibilityLabel = accessibilityLabel;
    this.enabled = enabled;
    this.progress = progress;
  }
}

export type SidebarInstallUpdate = (view: SidebarInstallView, action?: () => void) => void;

/** The detail owns the command; the bottom dock only renders its current presentation. */
@Component
export struct SidebarInstallPublisher {
  @Prop @Watch('publish') view: SidebarInstallView = new SidebarInstallView();
  onChange: SidebarInstallUpdate = () => {};
  action: () => void = () => {};
  private mounted: boolean = false;

  aboutToAppear(): void { this.mounted = true; this.publish(); }
  aboutToDisappear(): void { this.mounted = false; this.onChange(this.view); }
  private publish(): void { if (this.mounted) this.onChange(this.view, this.action); }
  build() { Blank().width(0).height(0).hitTestBehavior(HitTestMode.None) }
}

@Component
export struct SidebarInstallDock {
  @Prop view: SidebarInstallView = new SidebarInstallView();
  @Prop active: boolean = false;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  action: () => void = () => {};

  @Builder private face() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.view.label || I18n.t('读取中')).fontSize(14).fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center).maxLines(2)
        .fontColor(StoreMaterial.foreground(this.darkMode, false, this.materialMode))
    }.width('100%').height('100%')
  }

  @Builder private dockTab() {
    TabContent() {
      if (!StoreMaterial.supported(this.materialMode)) {
        StoreNavigationSurface({ darkMode: this.darkMode }).width('100%').height('100%')
      }
    }.tabBar(this.face)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (StoreMaterial.supported(this.materialMode)) {
        Tabs({ barPosition: BarPosition.End }) {
          this.dockTab()
        }.width('100%').height('100%').borderRadius(StoreLayout.navigationHeight / 2).clip(true)
          .barHeight(StoreLayout.navigationHeight)
          .barMode(BarMode.Fixed).scrollable(false).animationDuration(0).barOverlap(true)
          .barFloatingStyle({ maskColor: '#00000000', barSideMargin: 0, barBottomMargin: 0,
            barWidth: { smallBarWidth: StoreLayout.navigationHeight, mediumBarWidth: StoreLayout.navigationHeight,
              largeBarWidth: StoreLayout.navigationHeight },
            systemMaterial: StoreMaterial.dock(this.materialMode, this.darkMode) })
          .onTabBarClick(() => this.action())
      } else {
        HdsTabs({ barPosition: BarPosition.End }) {
          this.dockTab()
        }.width('100%').height('100%').borderRadius(StoreLayout.navigationHeight / 2).clip(true)
          .barHeight(StoreLayout.navigationHeight)
          .barMode(BarMode.Fixed).scrollable(false).animationDuration(0).barOverlap(true)
          .barFloatingStyle({ gradientMask: { maskColor: '#00000000' }, barSideMargin: 0, barBottomMargin: 0,
            barWidth: { smallWidth: StoreLayout.navigationHeight, mediumWidth: StoreLayout.navigationHeight,
              largeWidth: StoreLayout.navigationHeight },
            systemMaterialEffect: { materialType: MaterialPreferences.type(this.materialMode),
              materialLevel: MaterialPreferences.level(this.materialMode) } })
          .onTabBarClick(() => this.action())
      }
      // Native tab labels have their own padding and clipping. Measure the ring against the disc itself.
      if (this.view.progress >= 0) {
        Progress({ value: this.view.progress, total: 100, type: ProgressType.Ring })
          .width(StoreLayout.navigationHeight - 8).height(StoreLayout.navigationHeight - 8)
          .color(StoreMaterial.foreground(this.darkMode, false, this.materialMode))
          .backgroundColor(Palette.forMode(this.darkMode).border)
          .style({ strokeWidth: 3, enableSmoothEffect: true })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }
    }.width(StoreLayout.navigationHeight).height(StoreLayout.navigationHeight).borderRadius(StoreLayout.navigationHeight / 2)
      .shadow({ radius: 12, color: this.darkMode ? '#70000000' : '#38344769', offsetX: 0, offsetY: 4 })
      .enabled(this.active && this.view.enabled)
      .hitTestBehavior(this.active ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      .accessibilityLevel(this.active ? 'auto' : 'no-hide-descendants')
      .accessibilityText(this.view.accessibilityLabel || I18n.t('读取版本')).id('sidebar-install-action')
  }
}
