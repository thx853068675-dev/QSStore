/** Coalesce automatic maintenance outside the return animation and active scrolling. */
export class ForegroundIdle {
  private static foreground: boolean = true;
  private static quietUntil: number = 0;
  private static timer: number = -1;
  private static serial: number = 0;
  private static work: Map<string, () => void> = new Map();
  private static priorities: Map<string, () => boolean> = new Map();

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

  // Short pauses between consecutive flings are still interaction. Reserve maintenance for a settled screen.
  static interaction(quietMs: number = 450): void {
    ForegroundIdle.quietUntil = Math.max(ForegroundIdle.quietUntil, Date.now() + quietMs);
    ForegroundIdle.arm();
  }

  static defer(key: string, action: () => void): void {
    ForegroundIdle.work.set(key, action);
    ForegroundIdle.arm();
  }

  static cancel(key: string): void {
    ForegroundIdle.work.delete(key);
    ForegroundIdle.priorities.delete(key);
  }

  /** Only display scans wait here. Signing, downloads and user actions do not. */
  static wait(interactive?: () => boolean): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      if (ForegroundIdle.foreground && interactive?.() === true) { setTimeout(resolve, 0); return; }
      const key = 'scan-' + (++ForegroundIdle.serial);
      if (interactive !== undefined) ForegroundIdle.priorities.set(key, interactive);
      ForegroundIdle.defer(key, () => {
        ForegroundIdle.priorities.delete(key);
        resolve();
      });
    });
  }

  /** 手动刷新可提升已合并的自动扫描，保留同一个完成信号且不重复发起查询。 */
  static promote(): void {
    if (!ForegroundIdle.foreground) return;
    for (const key of ForegroundIdle.priorities.keys()) {
      if (ForegroundIdle.priorities.get(key)?.() !== true) continue;
      const action = ForegroundIdle.work.get(key);
      ForegroundIdle.work.delete(key);
      ForegroundIdle.priorities.delete(key);
      if (action !== undefined) setTimeout(action, 0);
    }
    if (ForegroundIdle.work.size === 0 && ForegroundIdle.timer !== -1) {
      clearTimeout(ForegroundIdle.timer);
      ForegroundIdle.timer = -1;
    }
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
