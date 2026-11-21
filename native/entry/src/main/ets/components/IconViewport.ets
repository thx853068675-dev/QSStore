/** Reports actual viewport ownership, including cached/offscreen lazy cells. */
@Component
export struct IconViewport {
  @Prop @Watch('sync') active: boolean = true;
  @BuilderParam content: () => void;
  changed: (visible: boolean) => void = () => {};
  private inView: boolean = false;
  private pinned: boolean = false;
  private sync(): void {
    const next = this.inView && this.active;
    if (next === this.pinned) return;
    this.pinned = next; this.changed(next);
  }
  aboutToDisappear(): void { this.inView = false; this.sync(); }
  build() {
    Stack() { this.content() }
      .onVisibleAreaChange([0], (visible: boolean, ratio: number) => {
        this.inView = visible && ratio > 0; this.sync();
      })
  }
}
