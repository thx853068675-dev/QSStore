import { afterPaint } from '../theme/AfterPaint';
import { HomeVisibility } from '../theme/HomeVisibility';
import { motion } from '@kit.MultimodalAwarenessKit';
import { Palette } from '../theme/Palette';
import { DiscoverMotion } from './DiscoverHeader';
import { StoreMaterial } from '../theme/StoreMaterial';
import { StoreImmersiveAction } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

/** Scroll thresholds update only this overlay, not the catalog's card tree. */
@Component
export struct DiscoverTopOverlay {
  @ObjectLink motion: DiscoverMotion;
  @ObjectLink homeVisibility: HomeVisibility;
  @Prop darkMode: boolean = false;
  @Prop inset: number = 24;
  @Prop active: boolean = true;
  @Prop epoch: number = 0;
  action: () => void = () => {};
  backAction: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
        // Keep the control mounted while hidden; only real route ownership changes replace it.
        ForEach([this.epoch], (_epoch: number) => {
          DiscoverTopAction({ darkMode: this.darkMode, inset: this.inset,
            active: this.motion.showTop && this.active && this.homeVisibility.visible, action: this.action,
            backAction: this.backAction })
            .position({ left: 0, bottom: 116 }).hitTestBehavior(HitTestMode.None)
        }, (epoch: number) => String(epoch))
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}

/** 系统握持事件驱动布局；放桌上或双手握持时保留位置，避免按钮来回跳动。 */
export class HoldingSide {
  left: boolean = false;
  private hasSide: boolean = false;
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
    if (this.hasSide && left === this.left) return;
    this.left = left;
    this.hasSide = true;
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
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') @Watch('onActiveChanged') private routeTransitioning:boolean=false;
  @Prop darkMode: boolean = false;
  @Prop inset: number = 24;
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @State private leftHand: boolean = false;
  @State private popupReady: boolean = false;
  private popupGeneration: number = 0;
  private disposed: boolean = false;
  action: () => void = () => {};
  backAction: () => void = () => {};
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
      .fontColor([StoreMaterial.icon(this.darkMode,this.materialMode)])
  }

  @Builder
  private floatingAction(immersive: boolean) {
    Button({ type: ButtonType.Circle }) { this.arrow() }
      .width(48).height(48).id('discover-back-to-top').accessibilityText(I18n.t('回到顶部'))
      .backgroundBlurStyle(immersive ? BlurStyle.NONE : StoreMaterial.blurStyle(this.materialMode), {
        colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .backgroundColor(immersive ? Color.Transparent : StoreMaterial.fallbackFill(this.darkMode))
      .border({ width: immersive ? 0 : 0.5, color: Palette.forMode(this.darkMode).border, radius: 24 })
      .shadow(immersive ? undefined : ShadowStyle.OUTER_DEFAULT_SM)
      .onClick(() => this.action())
  }

  build() {
    Row() {
      StoreImmersiveAction({ visible: this.active && !this.routeTransitioning,
        suspendPopup: !this.popupReady, colored: false, contentDrawsFallback: true,
        controlWidth: 48, controlHeight: 48, controlRadius: 24, followsTarget: true,
        backAction: this.backAction, content: (immersive: boolean): void => this.floatingAction(immersive) })
        .width(48).height(48)
    }.width('100%').height(48).padding({ left: this.inset, right: this.inset })
      .visibility(this.active && !this.routeTransitioning ? Visibility.Visible : Visibility.Hidden)
      .justifyContent(this.leftHand ? FlexAlign.Start : FlexAlign.End)
      .animation({ duration: 220, curve: Curve.EaseOut })
      // Only the 48vp control participates. The empty row must pass drags to
      // the list; Transparent still enrolls the row in hit testing.
      .hitTestBehavior(HitTestMode.None)
  }
}
