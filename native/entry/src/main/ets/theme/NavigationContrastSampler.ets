import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NavigationContrast, NavigationForeground, NavigationBackdrop } from './NavigationContrast';

/** Read mounted geometry only; never force an offscreen render of the whole page. */
export class NavigationContrastSampler {
  private timer: number = -1;
  private previous: NavigationForeground[] = [];
  private reportedUnavailable: boolean = false;
  private ui: UIContext;
  private active: () => boolean;
  private publish: (colors: NavigationForeground[]) => void;
  private backdrop: () => NavigationBackdrop;
  private bottomMargin: number;

  constructor(ui: UIContext, active: () => boolean, publish: (colors: NavigationForeground[]) => void,
    backdrop: () => NavigationBackdrop, bottomMargin: number = 0) {
    this.ui = ui; this.active = active; this.publish = publish;
    this.backdrop = backdrop; this.bottomMargin = bottomMargin;
  }

  request(delay: number = 80): void {
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    if (!this.active()) return;
    this.timer = setTimeout(() => { this.timer = -1; this.capture(); }, delay);
  }

  /** Leading throttle: continuous scrolling still updates contrast, without layout writes. */
  motion(): void {
    if (this.active() && this.timer === -1) this.request(80);
  }

  cancel(): void {
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
  }

  reset(): void { this.cancel(); this.previous = []; }

  private capture(): void {
    if (!this.active()) return;
    try {
      const utils = this.ui.getComponentUtils();
      const shift = this.ui.vp2px(this.bottomMargin);
      const backdrop = this.backdrop();
      const result: NavigationForeground[] = [];
      for (let index = 0; index < 4; index++) {
        const tab = utils.getRectangleById('bottom-tab-' + index);
        if (tab.size.width <= 0 || tab.size.height <= 0) throw new Error('Navigation geometry unavailable');
        result.push(NavigationContrast.paint({ left: tab.windowOffset.x, top: tab.windowOffset.y - shift,
          width: tab.size.width, height: tab.size.height }, backdrop, this.previous[index]));
      }
      if (JSON.stringify(result) !== JSON.stringify(this.previous)) {
        this.previous = result;
        this.publish(result);
        hilog.info(0x0000, 'QingqiNavContrast', 'colors %{public}s', JSON.stringify(result));
      }
      this.reportedUnavailable = false;
    } catch (error) {
      if (!this.reportedUnavailable) {
        this.reportedUnavailable = true;
        hilog.warn(0x0000, 'QingqiNavContrast', 'unavailable %{public}s', String(error));
      }
    }
  }
}
