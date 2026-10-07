/** Visibility gates native bubbles; their original dimensions and corner radii stay unchanged. */
@Observed
export class DiscoverCategorySlice {
  @Track viewportOffset: number = 0;
  @Track visibleWidth: number = 0;
  @Track materialVisible: boolean = false;
  clipTo(start: number, width: number, offset: number, viewport: number, expandedViewport: number = viewport): void {
    const left = Math.min(width, Math.max(0, offset - start));
    const right = Math.min(width, Math.max(left, offset + Math.max(0, viewport) - start));
    const visible = Math.max(0, right - left);
    // Warm the expanded viewport plus one pill before it enters the fixed mask.
    // Opening/closing the toolbar must not create/destroy material at its moving right edge.
    const warmLeft = Math.min(width, Math.max(0, offset - 96 - start));
    const warmRight = Math.min(width, Math.max(warmLeft, offset + Math.max(viewport, expandedViewport) + 96 - start));
    const materialVisible = warmRight - warmLeft > 0.5;
    if ((materialVisible || this.materialVisible) &&
      Math.abs(this.viewportOffset - (start - offset)) > 0.01) this.viewportOffset = start - offset;
    if (Math.abs(this.visibleWidth - visible) > 0.01) this.visibleWidth = visible;
    if (this.materialVisible !== materialVisible) this.materialVisible = materialVisible;
  }
}
