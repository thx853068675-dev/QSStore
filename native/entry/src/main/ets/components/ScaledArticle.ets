/** Measure the article at its logical size while keeping the dock's layout and hit region unscaled. */
@Component
export struct ScaledArticle {
  @Prop sceneScale: number = 1;
  @BuilderParam content: () => void;

  onMeasureSize(info: GeometryInfo, children: Array<Measurable>, constraint: ConstraintSizeOptions): SizeResult {
    const width = Number.isFinite(Number(constraint.maxWidth)) ? Math.max(0, Number(constraint.maxWidth)) : Number(info.width);
    const height = Number.isFinite(Number(constraint.maxHeight)) ? Math.max(0, Number(constraint.maxHeight)) : Number(info.height);
    const scale = Number.isFinite(this.sceneScale) && this.sceneScale > 0 ? this.sceneScale : 1;
    children.forEach((child: Measurable) => child.measure({
      minWidth: width / scale, maxWidth: width / scale,
      minHeight: height / scale, maxHeight: height / scale
    }));
    return { width: width, height: height };
  }

  onPlaceChildren(_info: GeometryInfo, children: Array<Layoutable>, _constraint: ConstraintSizeOptions): void {
    children.forEach((child: Layoutable) => child.layout({ x: 0, y: 0 }));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.content();
    }.width('100%').height('100%')
      .scale({ x: this.sceneScale, y: this.sceneScale, centerX: '0%', centerY: '0%' })
  }
}
