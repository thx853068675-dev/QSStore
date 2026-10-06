import { UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NavigationContrast, NavigationForeground } from './NavigationContrast';

/** Sample page content beneath the floating navigation, before its glass material is composited. */
export class NavigationContrastSampler {
  private timer: number = -1;
  private revision: number = 0;
  private inFlight: boolean = false;
  private pending: boolean = false;
  private previous: NavigationForeground[] = [];
  private ui: UIContext;
  private active: () => boolean;
  private publish: (colors: NavigationForeground[]) => void;
  private reportedUnavailable: boolean = false;
  private bottomMargin: number;
  private contentId: () => string;

  constructor(ui: UIContext, active: () => boolean, publish: (colors: NavigationForeground[]) => void,
    contentId: () => string, bottomMargin: number = 0) {
    this.ui = ui;
    this.active = active;
    this.publish = publish;
    this.bottomMargin = bottomMargin;
    this.contentId = contentId;
  }

  request(delay: number = 140): void {
    this.revision++;
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    if (!this.active()) return;
    this.timer = setTimeout(() => {
      this.timer = -1;
      if (this.inFlight) { this.pending = true; return; }
      this.capture(this.revision);
    }, delay);
  }

  /** Leading throttle: repeated scroll frames do not keep postponing the update. */
  motion(): void {
    if (!this.active() || this.timer !== -1) return;
    if (this.inFlight) { this.pending = true; return; }
    this.request(240);
  }

  cancel(): void {
    this.revision++;
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    this.pending = false;
  }

  reset(): void {
    this.cancel();
    this.previous = [];
  }

  private async capture(revision: number): Promise<void> {
    if (!this.active()) return;
    this.inFlight = true;
    let pixels: image.PixelMap | undefined;
    try {
      const utils = this.ui.getComponentUtils();
      const contentId = this.contentId();
      const root = utils.getRectangleById(contentId);
      // HDS floats its parent bar upward by barBottomMargin. ComponentUtils returns
      // its children's layout positions without that parent render translation.
      const shift = this.ui.vp2px(this.bottomMargin);
      const tabs = [0, 1, 2, 3].map((index: number) => {
        const tab = utils.getRectangleById('bottom-tab-' + index);
        tab.windowOffset.y -= shift;
        return tab;
      });
      if (root.size.width <= 0 || root.size.height <= 0 ||
        tabs.some((tab) => tab.size.width <= 0 || tab.size.height <= 0)) {
        throw new Error('Navigation geometry unavailable');
      }
      const left = Math.max(0, Math.floor(Math.min(...tabs.map((tab) => tab.windowOffset.x)) - root.windowOffset.x));
      const top = Math.max(0, Math.floor(Math.min(...tabs.map((tab) => tab.windowOffset.y)) - root.windowOffset.y));
      const right = Math.min(root.size.width, Math.ceil(Math.max(...tabs.map((tab) => tab.windowOffset.x + tab.size.width)) - root.windowOffset.x));
      const bottom = Math.min(root.size.height, Math.ceil(Math.max(...tabs.map((tab) => tab.windowOffset.y + tab.size.height)) - root.windowOffset.y));
      if (right <= left || bottom <= top) throw new Error('Navigation crop unavailable');
      // Capture the selected page subtree only. Navigation, glass reflections and
      // the 6.1 material fallback are siblings, so they cannot change the result.
      // SnapshotRegion on a safe-area-expanded HDS page can return transparent
      // pixels. Capture its low-resolution subtree, then read only our tiny crop.
      pixels = await this.ui.getComponentSnapshot().get(contentId, { scale: 0.25,
        waitUntilRenderFinished: true });
      const info = await pixels.getImageInfo();
      const scaleX = info.size.width / root.size.width, scaleY = info.size.height / root.size.height;
      const cropLeft = Math.floor(left * scaleX), cropTop = Math.floor(top * scaleY);
      const width = Math.ceil(right * scaleX) - cropLeft, height = Math.ceil(bottom * scaleY) - cropTop;
      if (width <= 0 || height <= 0 || width * height > 262144) throw new Error('Navigation crop exceeds sampling budget');
      const buffer = new ArrayBuffer(width * height * 4);
      await pixels.readPixels({ pixels: buffer, offset: 0, stride: width * 4,
        region: { x: cropLeft, y: cropTop, size: { width: width, height: height } } });
      if (revision !== this.revision || !this.active() || contentId !== this.contentId()) return;
      const bytes = new Uint8Array(buffer);
      const result: NavigationForeground[] = [];
      for (let index = 0; index < tabs.length; index++) {
        const tab = tabs[index];
        const color = NavigationContrast.sample(bytes, width, height, {
          left: (tab.windowOffset.x - root.windowOffset.x) * scaleX - cropLeft,
          top: (tab.windowOffset.y - root.windowOffset.y) * scaleY - cropTop,
          width: tab.size.width * scaleX, height: tab.size.height * scaleY
        }, this.previous[index]);
        if (color === undefined) throw new Error('Navigation backdrop unavailable');
        result.push(color);
      }
      if (JSON.stringify(result) !== JSON.stringify(this.previous)) {
        this.previous = result;
        this.publish(result);
        hilog.info(0x0000, 'QingqiNavContrast', 'colors %{public}s', JSON.stringify(result));
      }
      this.reportedUnavailable = false;
    } catch (error) {
      // Leave the native theme colors visible if capture or geometry is unavailable.
      if (!this.reportedUnavailable) {
        this.reportedUnavailable = true;
        hilog.warn(0x0000, 'QingqiNavContrast', 'unavailable %{public}s', String(error));
      }
    } finally {
      if (pixels) { try { await pixels.release(); } catch (_) {} }
      this.inFlight = false;
      if (this.pending && this.active()) { this.pending = false; this.request(); }
    }
  }
}
