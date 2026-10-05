/** Coalesce automatic maintenance outside the return animation and active scrolling. */
export class ForegroundIdle {
  private static foreground: boolean = true;
  private static quietUntil: number = 0;
  private static timer: number = -1;
  private static serial: number = 0;
  private static work: Map<string, () => void> = new Map();

  static onForeground(): void {
    ForegroundIdle.foreground = true;
    ForegroundIdle.quietUntil = Math.max(ForegroundIdle.quietUntil, Date.now() + 800);
    ForegroundIdle.arm();
  }

  static onBackground(): void {
    ForegroundIdle.foreground = false;
    if (ForegroundIdle.timer !== -1) clearTimeout(ForegroundIdle.timer);
    ForegroundIdle.timer = -1;
  }

  static interaction(quietMs: number = 180): void {
    ForegroundIdle.quietUntil = Math.max(ForegroundIdle.quietUntil, Date.now() + quietMs);
    ForegroundIdle.arm();
  }

  static defer(key: string, action: () => void): void {
    ForegroundIdle.work.set(key, action);
    ForegroundIdle.arm();
  }

  static cancel(key: string): void {
    ForegroundIdle.work.delete(key);
  }

  /** Only display scans wait here. Signing, downloads and user actions do not. */
  static wait(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      ForegroundIdle.defer('scan-' + (++ForegroundIdle.serial), resolve);
    });
  }

  private static arm(): void {
    if (!ForegroundIdle.foreground || ForegroundIdle.timer !== -1 || ForegroundIdle.work.size === 0) return;
    ForegroundIdle.timer = setTimeout(() => {
      ForegroundIdle.timer = -1;
      if (!ForegroundIdle.foreground) return;
      if (Date.now() < ForegroundIdle.quietUntil) { ForegroundIdle.arm(); return; }
      // One continuation per event-loop turn, rather than a burst of all callbacks.
      for (const key of ForegroundIdle.work.keys()) {
        const action = ForegroundIdle.work.get(key);
        ForegroundIdle.work.delete(key);
        action?.();
        break;
      }
      ForegroundIdle.arm();
    }, Math.max(16, ForegroundIdle.quietUntil - Date.now()));
  }
}
