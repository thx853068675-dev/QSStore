/** Measured scroll bounds, independent of item count and text scaling. */
export class DiscoverShelfPosition {
  static readonly cardStep: number = 134;
  static readonly arrowWidth: number = 26;
  static readonly arrowHeight: number = 42;
  static readonly arrowInset: number = 12;
  static readonly touchWidth: number = 44;
  static readonly touchHeight: number = 66;
  private static readonly tolerance: number = 2;

  static extent(content: number, viewport: number): number {
    return Number.isFinite(content) && Number.isFinite(viewport) && viewport > 0 ?
      Math.max(0, content - viewport) : 0;
  }
  static offset(value: number, content: number, viewport: number): number {
    return Math.min(DiscoverShelfPosition.extent(content, viewport),
      Number.isFinite(value) ? Math.max(0, value) : 0);
  }
  static left(value: number, content: number, viewport: number): boolean {
    return DiscoverShelfPosition.extent(content, viewport) > DiscoverShelfPosition.tolerance &&
      DiscoverShelfPosition.offset(value, content, viewport) > DiscoverShelfPosition.tolerance;
  }
  static right(value: number, content: number, viewport: number): boolean {
    const extent = DiscoverShelfPosition.extent(content, viewport);
    return extent > DiscoverShelfPosition.tolerance &&
      DiscoverShelfPosition.offset(value, content, viewport) < extent - DiscoverShelfPosition.tolerance;
  }
  static next(value: number, direction: number, content: number, viewport: number): number {
    return DiscoverShelfPosition.offset(DiscoverShelfPosition.offset(value, content, viewport) +
      Math.sign(direction) * DiscoverShelfPosition.cardStep, content, viewport);
  }
  static anchorInset(): number {
    return DiscoverShelfPosition.arrowInset - (DiscoverShelfPosition.touchWidth - DiscoverShelfPosition.arrowWidth) / 2;
  }
}
