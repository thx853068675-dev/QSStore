import { afterPaint } from '../theme/AfterPaint';
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { Palette } from '../theme/Palette';
import { DiscoverMotion } from './DiscoverHeader';

/** Scroll thresholds update only this overlay, not the catalog's card tree. */
@Component
export struct DiscoverTopOverlay {
  @ObjectLink motion: DiscoverMotion;
  @Prop darkMode: boolean = false;
  @Prop inset: number = 24;
  @Prop active: boolean = true;
  @Prop epoch: number = 0;
  action: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
        // Keep the control mounted while hidden; only real route ownership changes replace it.
        ForEach([this.epoch], (_epoch: number) => {
          DiscoverTopAction({ darkMode: this.darkMode, inset: this.inset,
            active: this.motion.showTop && this.active, action: this.action })
            .position({ left: 0, bottom: 116 }).hitTestBehavior(HitTestMode.None)
        }, (epoch: number) => String(epoch))
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}

/** 系统握持事件驱动布局；放桌上或双手握持时保留位置，避免按钮来回跳动。 */
export class HoldingSide {
  left: boolean = false;
  private subscribed: boolean = false;
  private changed: (left: boolean) => void;
  private callback: (status: motion.HoldingHandStatus) => void;

  constructor(changed: (left: boolean) => void) {
    this.changed = changed;
    this.callback = (status: motion.HoldingHandStatus): void => {
      if (!this.subscribed) return;
      if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) this.setSide(true);
      else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) this.setSide(false);
    };
  }

  private setSide(left: boolean): void {
    if (left === this.left) return;
    this.left = left;
    this.changed(left);
  }

  start(): void {
    if (this.subscribed) return;
    try {
      motion.on('holdingHandChanged', this.callback);
      this.subscribed = true;
    } catch (_) { return; } // 不支持或权限未授予时按钮保持可用。
    try {
      const recent = motion.getRecentOperatingHandStatus();
      if (recent === motion.OperatingHandStatus.LEFT_HAND_OPERATED) this.setSide(true);
      else if (recent === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) this.setSide(false);
    } catch (_) {}
  }

  stop(): void {
    if (!this.subscribed) return;
    this.subscribed = false;
    try { motion.off('holdingHandChanged', this.callback); } catch (_) {}
  }
}

@Component
export struct DiscoverTopAction {
  @StorageProp('routeTransitioning') @Watch('onActiveChanged') private routeTransitioning:boolean=false;
  @Prop darkMode: boolean = false;
  @Prop inset: number = 24;
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @State private leftHand: boolean = false;
  @State private popupReady: boolean = false;
  private popupGeneration: number = 0;
  private disposed: boolean = false;
  action: () => void = () => {};
  private holding: HoldingSide = new HoldingSide((left: boolean): void => { this.leftHand = left; });

  aboutToAppear(): void {
    this.disposed = false;
    this.onActiveChanged();
  }
  aboutToDisappear(): void {
    this.disposed = true;
    this.popupGeneration++;
    this.holding.stop();
  }
  private onActiveChanged(): void {
    const generation = ++this.popupGeneration;
    if (!this.active || this.routeTransitioning) {
      this.popupReady = false;
      this.holding.stop();
      return;
    }
    if (this.popupReady) return;
    afterPaint(this.getUIContext(), () => {
      if (this.disposed || generation !== this.popupGeneration || !this.active || this.routeTransitioning) return;
      this.holding.start();
      this.popupReady = true;
    });
  }

  @Builder
  private arrow() {
    SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(21)
      .fontColor([Palette.forMode(this.darkMode).text])
  }

  @Builder
  private immersiveAction() {
    Button({ type: ButtonType.Circle }) { this.arrow() }
      .width(48).height(48).id('discover-back-to-top').accessibilityText('回到顶部')
      .backgroundColor(Color.Transparent)
      .onClick(() => this.action())
  }

  build() {
    Row() {
      if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
        // Ordinary Button material only works in navigation/tab bars on API 26.
        // Popup supports system material throughout the page. A nonmodal,
        // arrowless circular popup supplies the native floating backplate.
        Stack() {
        Column() {}.width(48).height(48)
          .bindPopup(this.popupReady&&this.active&&!this.routeTransitioning, { builder: this.immersiveAction, width: 48, radius: 24,
            placement: Placement.Top, targetSpace: 0, offset: { x: 0, y: 48 },
            enableArrow: false, autoCancel: false, focusable: false, mask: false,
            transition: TransitionEffect.IDENTITY,
            systemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
              colorInvert: true, applyShadow: true, interactive: true,
              lightEffect: { color: Palette.forMode(this.darkMode).surface } }) })
        if (this.active && !this.routeTransitioning && !this.popupReady) {
          Button({ type: ButtonType.Circle }) { this.arrow() }
            .width(48).height(48).id('discover-back-to-top-preview').accessibilityText('回到顶部')
            .backgroundColor(Palette.forMode(this.darkMode).fill)
            .onClick(() => this.action())
        }
        }.width(48).height(48)
      } else {
        // 旧系统尚无组件级 ImmersiveMaterial，使用系统毛玻璃保持形态与可读性。
        Button({ type: ButtonType.Circle }) { this.arrow() }
          .width(48).height(48).id('discover-back-to-top').accessibilityText('回到顶部')
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, {
            colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 0.5, color: Palette.forMode(this.darkMode).border, radius: 24 })
          .shadow(ShadowStyle.OUTER_DEFAULT_SM)
          .onClick(() => this.action())
      }
    }.width('100%').height(48).padding({ left: this.inset, right: this.inset })
      .visibility(this.active && !this.routeTransitioning ? Visibility.Visible : Visibility.Hidden)
      .justifyContent(this.leftHand ? FlexAlign.Start : FlexAlign.End)
      .animation({ duration: 220, curve: Curve.EaseOut })
      // Only the 48vp control participates. The empty row must pass drags to
      // the list; Transparent still enrolls the row in hit testing.
      .hitTestBehavior(HitTestMode.None)
  }
}
