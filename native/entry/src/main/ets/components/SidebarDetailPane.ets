import { Detail } from '../pages/Detail';
import { SidebarInstallUpdate } from './SidebarInstallDock';

/** Keep the current detail until its replacement is ready. At most two scenes are mounted. */
@Component
export struct SidebarDetailPane {
  @Prop @Watch('selectApp') appId: number = 0;
  @Prop @Watch('activateScene') visible: boolean = true;
  @Prop topInset: number = 0;
  onDockChange: SidebarInstallUpdate = () => {};
  onScroll: (delta: number) => void = () => {};
  @State private scenes: number[] = [];
  @State private currentId: number = 0;
  @State private revealedId: number = 0;
  @State private transitioning: boolean = false;
  private disposed: boolean = false;
  private transitionGeneration: number = 0;

  aboutToAppear(): void {
    this.currentId = this.appId;
    this.revealedId = this.appId;
    this.scenes = this.visible && this.appId > 0 ? [this.appId] : [];
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.transitionGeneration++;
  }

  private activateScene(): void {
    if (this.disposed || !this.visible) return;
    if (this.scenes.length === 0) {
      this.currentId = this.appId;
      this.revealedId = this.appId;
      this.scenes = this.appId > 0 ? [this.appId] : [];
    } else this.selectApp();
  }

  private selectApp(): void {
    if (this.disposed || !this.visible || this.appId <= 0 || this.transitioning) return;
    if (this.currentId === this.appId) {
      this.scenes = [this.currentId];
      return;
    }
    // Replacing an unfinished request disposes its scene; late responses cannot commit.
    this.scenes = this.currentId > 0 ? [this.currentId, this.appId] : [this.appId];
  }

  private detailReady(id: number): void {
    if (this.disposed || id !== this.appId || id === this.currentId || this.transitioning) return;
    const generation = ++this.transitionGeneration;
    this.transitioning = true;
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut, onFinish: () => {
      if (this.disposed || generation !== this.transitionGeneration) return;
      this.currentId = id;
      this.scenes = [id];
      this.transitioning = false;
      // Rapid taps during the fade are coalesced into the latest selection.
      this.selectApp();
    } }, () => { this.revealedId = id; });
  }

  private sceneAcceptsInput(id: number): boolean {
    return this.visible && id === this.revealedId;
  }

  private sceneActionsVisible(id: number): boolean {
    return this.visible && id === this.currentId && id === this.appId && !this.transitioning;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.scenes, (id: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Detail({ embedded: true, embeddedAppId: id,
            embeddedVisible: this.sceneActionsVisible(id),
            embeddedTopInset: this.topInset,
            onEmbeddedScroll: (delta: number): void => {
              if (this.sceneAcceptsInput(id)) this.onScroll(delta);
            },
            onEmbeddedReady: () => this.detailReady(id), onEmbeddedDockChange: this.onDockChange })
            .width('100%').height('100%')
        }.width('100%').height('100%').opacity(id === this.revealedId ? 1 : 0)
          .hitTestBehavior(this.sceneAcceptsInput(id) ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
          .accessibilityLevel(this.sceneAcceptsInput(id) ? 'auto' : 'no-hide-descendants')
      }, (id: number) => String(id))
    }.width('100%').height('100%').clip(true)
  }
}
