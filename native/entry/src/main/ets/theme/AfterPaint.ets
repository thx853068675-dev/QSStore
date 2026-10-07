import { FrameCallback, UIContext } from '@kit.ArkUI';

/** Run a small publication after painting, rather than competing with that frame's layout. */
class PaintContinuation extends FrameCallback {
  private action: () => void;
  private completed: boolean = false;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_timeLeft: number): void {
    if (this.completed) return;
    this.completed = true;
    this.action();
  }
}

export function afterPaint(ui: UIContext, action: () => void): void {
  ui.postFrameCallback(new PaintContinuation(action));
}
