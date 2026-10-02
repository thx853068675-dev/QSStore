import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { Palette } from '../theme/Palette';

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
  @Prop darkMode: boolean = false;
  @Prop inset: number = 24;
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @State private leftHand: boolean = false;
  action: () => void = () => {};
  private holding: HoldingSide = new HoldingSide((left: boolean): void => { this.leftHand = left; });

  aboutToAppear(): void { this.onActiveChanged(); }
  aboutToDisappear(): void { this.holding.stop(); }
  private onActiveChanged(): void {
    if (this.active) this.holding.start();
    else this.holding.stop();
  }

  @Builder
  private arrow() {
    SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(21)
      .fontColor([Palette.forMode(this.darkMode).text])
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
        Button({ type: ButtonType.Circle }) { this.arrow() }
          .width(48).height(48).id('discover-back-to-top').accessibilityText('回到顶部')
          .backgroundColor(Color.Transparent)
          .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
            colorInvert: true, applyShadow: true, interactive: true,
            lightEffect: { color: Palette.forMode(this.darkMode).surface } }))
          .position({ x: this.leftHand ? this.inset : 'calc(100% - ' + (this.inset + 48) + 'vp)', y: 0 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .onClick(() => this.action())
      } else {
        // 旧系统尚无组件级 ImmersiveMaterial，使用系统毛玻璃保持形态与可读性。
        Button({ type: ButtonType.Circle }) { this.arrow() }
          .width(48).height(48).id('discover-back-to-top').accessibilityText('回到顶部')
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, {
            colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 0.5, color: Palette.forMode(this.darkMode).border, radius: 24 })
          .shadow(ShadowStyle.OUTER_DEFAULT_SM)
          .position({ x: this.leftHand ? this.inset : 'calc(100% - ' + (this.inset + 48) + 'vp)', y: 0 })
          .animation({ duration: 220, curve: Curve.EaseOut })
          .onClick(() => this.action())
      }
    }.width('100%').height(48).hitTestBehavior(HitTestMode.Transparent)
  }
}
