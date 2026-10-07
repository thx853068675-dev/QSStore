import { router, UIContext } from '@kit.ArkUI';
import { ForegroundIdle } from '../jobs/ForegroundIdle';

/** Opaque native cover. Floating material is hidden before either page starts moving. */
export class StorePageMotion {
  static readonly duration: number = 220;
  private static revealTimer: number = -1;
  private static revision: number = 0;
  private static pushFlight: Promise<void> | undefined = undefined;
  private static pushTarget: string = '';
  private static pushPending: boolean = false;
  private static revealReady: boolean = false;
  private static waiting: Array<() => void> = [];
  static options(type: RouteType): PageTransitionOptions {
    return { type: type, duration: StorePageMotion.duration, curve: Curve.EaseOut };
  }
  static stationary(type: RouteType): PageTransitionOptions {
    return { type: type, duration: StorePageMotion.duration, curve: Curve.Linear };
  }
  /** Only real page transitions invalidate a cached page's native popup ownership. */
  static routeRevision(): number { return StorePageMotion.revision; }
  static prepare(): void {
    const revision = ++StorePageMotion.revision;
    StorePageMotion.revealReady = false;
    if (StorePageMotion.revealTimer !== -1) clearTimeout(StorePageMotion.revealTimer);
    AppStorage.setOrCreate<boolean>('routeTransitioning', true);
    ForegroundIdle.interaction(StorePageMotion.duration + 64);
    StorePageMotion.revealTimer = setTimeout(() => {
      if (revision !== StorePageMotion.revision) return;
      StorePageMotion.revealTimer = -1;
      StorePageMotion.revealReady = true;
      StorePageMotion.settle();
    }, StorePageMotion.duration + 64);
  }
  static dismissFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 32); });
  }
  private static settle(): void {
    if (StorePageMotion.pushPending) return;
    StorePageMotion.pushFlight = undefined;
    StorePageMotion.pushTarget = '';
    AppStorage.setOrCreate<boolean>('routeTransitioning', false);
    const waiting = StorePageMotion.waiting;
    StorePageMotion.waiting = [];
    waiting.forEach((resolve: () => void) => resolve());
  }
  static pushUrl(options: router.RouterOptions, mode: router.RouterMode = router.RouterMode.Standard,
    ui?: UIContext): Promise<void> {
    const target = JSON.stringify([options, mode]);
    if (StorePageMotion.pushFlight !== undefined) {
      if (target === StorePageMotion.pushTarget) return StorePageMotion.pushFlight;
      // A different destination (including an external file open) is serialized, never lost.
      return new Promise<void>((resolve: () => void) => { StorePageMotion.waiting.push(resolve); })
        .then(() => StorePageMotion.pushUrl(options, mode, ui));
    }
    const flight = StorePageMotion.push(options, mode, ui);
    StorePageMotion.pushTarget = target;
    StorePageMotion.pushFlight = flight;
    return flight;
  }
  private static async push(options: router.RouterOptions, mode: router.RouterMode, ui?: UIContext): Promise<void> {
    StorePageMotion.pushPending = true;
    StorePageMotion.prepare();
    const revision = StorePageMotion.revision;
    // Popup material is a separate window: allow its dismissal to reach the render frame first.
    try {
      await StorePageMotion.dismissFrame();
      // An Ability callback has no ambient ArkUI instance after the async frame delay.
      if (ui) await ui.getRouter().pushUrl(options, mode);
      else await router.pushUrl(options, mode);
      StorePageMotion.pushPending = false;
      if (StorePageMotion.revealReady) StorePageMotion.settle();
    } catch (error) {
      StorePageMotion.pushPending = false;
      if (revision === StorePageMotion.revision) {
        if (StorePageMotion.revealTimer !== -1) clearTimeout(StorePageMotion.revealTimer);
        StorePageMotion.revealTimer = -1;
        StorePageMotion.settle();
      } else if (StorePageMotion.revealReady) StorePageMotion.settle();
      throw error as Error;
    }
  }
}
