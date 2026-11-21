/** Visible cells own pins. A small warm set keeps reverse scrolling instant. */
export class IconResidency {
  private pins: Map<string, number> = new Map();
  private recent: string[] = [];
  private warmCount: number;
  constructor(warmCount: number = 20) { this.warmCount = warmCount; }
  visible(key: string, visible: boolean): void {
    const count = this.pins.get(key) ?? 0;
    if (visible) this.pins.set(key, count + 1);
    else if (count > 1) this.pins.set(key, count - 1);
    else this.pins.delete(key);
    this.recent = this.recent.filter((value: string) => value !== key);
    this.recent.push(key);
    if (this.recent.length > 256) this.recent.shift();
  }
  wanted(key: string): boolean { return (this.pins.get(key) ?? 0) > 0; }
  keep(keys: string[], pressure: boolean = false): Set<string> {
    const present = new Set(keys), out = new Set<string>();
    this.pins.forEach((_count: number, key: string) => { if (present.has(key)) out.add(key); });
    if (!pressure) {
      let warm = 0;
      for (let i = this.recent.length - 1; i >= 0 && warm < this.warmCount; i--) {
        const key = this.recent[i];
        if (present.has(key) && !out.has(key)) { out.add(key); warm++; }
      }
    }
    return out;
  }
}
