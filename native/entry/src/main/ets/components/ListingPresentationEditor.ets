import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { ListingPresentationDraft, ListingScreenshot } from '../data/ListingPresentation';
import { StoreClient } from '../data/StoreClient';
import { I18n } from '../data/I18n';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreLayout } from '../theme/StoreDesign';

@Component
export struct StoreScreenshotImage {
  @Prop appId: number = 0;
  @Prop source: string = '';
  @Prop edge: number = 400;
  @Prop deviceFrame: boolean = false;
  @Prop darkMode: boolean = false;
  @Prop availableWidth: number = 248;
  @State private pixels: image.PixelMap | undefined = undefined;
  @State private screenshotRatio: number = 9 / 19.5;
  private gone: boolean = false;

  aboutToAppear(): void { this.load(); }

  aboutToDisappear(): void {
    this.gone = true;
    this.pixels?.release().catch(() => {});
  }

  private async load(): Promise<void> {
    let source: image.ImageSource | undefined;
    try {
      const bytes = /^[a-f0-9]{24}$/.test(this.source) ?
        await new StoreClient(getContext(this) as common.UIAbilityContext).screenshotBytes(this.appId, this.source) :
        new util.Base64Helper().decodeSync(this.source).buffer as ArrayBuffer;
      if (!bytes || this.gone) return;
      source = image.createImageSource(bytes);
      const size = (await source.getImageInfo()).size;
      if (size.width < 1 || size.height < 1) return;
      const ratio = Math.min(1, this.edge / Math.max(size.width, size.height));
      const pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(size.width * ratio)), height: Math.max(1, Math.round(size.height * ratio))
      } });
      if (this.gone) await pixels.release();
      else {
        if (this.deviceFrame) this.screenshotRatio = size.width / size.height;
        this.pixels = pixels;
      }
    } catch (_) {
      // A screenshot may have been replaced while the app was open.
    } finally { await source?.release().catch(() => {}); }
  }

  private screenHeight(): number {
    return Math.min(212, Math.max(42, Math.min(240, this.availableWidth - 8)) / this.screenshotRatio);
  }

  private screenWidth(): number { return Math.max(42, this.screenHeight() * this.screenshotRatio); }
  private frameRadius(): number { return Math.min(17, this.screenWidth() / 5); }

  @Builder
  private picture() {
    Stack() {
      if (this.pixels) {
        Image(this.pixels).width('100%').height('100%').objectFit(ImageFit.Contain)
      } else {
        SymbolGlyph($r('sys.symbol.doc')).fontSize(19).fontColor(['#8895AA'])
      }
    }.width('100%').height('100%')
  }

  build() {
    if (this.deviceFrame) {
      Stack() {
        Stack() { this.picture() }
          .width(this.screenWidth()).height(this.screenHeight()).borderRadius(this.frameRadius() - 4).clip(true)
      }.padding(4).borderRadius(this.frameRadius()).backgroundColor('#141820')
        .border({ width: 1, color: this.darkMode ? '#424B59' : '#353F4D' })
    } else {
      this.picture()
    }
  }
}

@Component
export struct ListingPresentationEditor {
  @ObjectLink draft: ListingPresentationDraft;
  @Prop appId: number = 0;
  @Prop darkMode: boolean = false;
  @Prop editable: boolean = true;
  @State private message: string = '';
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  private async add(): Promise<void> {
    const draft = this.draft;
    const remaining = ListingScreenshot.LIMIT - draft.screenshots.length;
    if (!this.editable || draft.processing || remaining < 1) return;
    draft.processing = true;
    this.message = '';
    try {
      const incoming = await ListingScreenshot.pick(getContext(this) as common.UIAbilityContext, remaining);
      draft.screenshots = Array.from(new Set(draft.screenshots.concat(incoming))).slice(0, ListingScreenshot.LIMIT);
    } catch (error) { this.message = errorText(error); }
    finally { draft.processing = false; }
  }

  build() {
    Column({ space: 8 }) {
      Text(I18n.t('应用名')).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
      TextInput({ text: this.draft.name, placeholder: I18n.t('应用名') }).maxLength(80).height(44)
        .fontColor(this.colors().text).backgroundColor(this.colors().fill).enabled(this.editable)
        .onChange((text: string) => { this.draft.name = text; })
      Text(I18n.t('应用介绍')).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
      TextArea({ text: this.draft.description, placeholder: I18n.t('应用介绍') }).maxLength(2000).height(96)
        .fontColor(this.colors().text).backgroundColor(this.colors().fill).enabled(this.editable)
        .onChange((text: string) => { this.draft.description = text; })
      Row() {
        Text(I18n.t('界面截图')).fontSize(12).fontColor(this.colors().textSecondary).layoutWeight(1)
        Text(String(this.draft.screenshots.length) + '/' + ListingScreenshot.LIMIT)
          .fontSize(11).fontColor(this.colors().textTertiary)
      }.width('100%')
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.draft.screenshots, (source: string) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              StoreScreenshotImage({ appId: this.appId, source: source, edge: 280 })
              Button({ type: ButtonType.Circle }) {
                SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([this.colors().text])
              }.width(25).height(25).margin(3).backgroundColor(this.colors().surface)
                .accessibilityText(I18n.t('删除截图')).enabled(this.editable && !this.draft.processing)
                .onClick(() => { this.draft.screenshots = this.draft.screenshots.filter((item: string) => item !== source); })
            }.width(72).height(82).backgroundColor(this.colors().fill).borderRadius(12).clip(true)
          }, (source: string) => ListingScreenshot.key(source))
          if (this.draft.screenshots.length < ListingScreenshot.LIMIT) {
            Button({ type: ButtonType.Normal }) {
              if (this.draft.processing) {
                LoadingProgress().width(22).height(22).color(this.colors().accent)
              } else {
                SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([this.colors().accent])
              }
            }.width(72).height(82).borderRadius(12).backgroundColor(this.colors().accentSoft)
              .accessibilityText(I18n.t('添加截图')).enabled(this.editable && !this.draft.processing)
              .onClick(() => this.add())
          }
        }
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      if (this.message) {
        Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%')
      }
    }.width('100%')
  }
}

@CustomDialog
struct ListingScreenshotPreview {
  controller?: CustomDialogController;
  appId: number = 0;
  screenshots: string[] = [];
  startIndex: number = 0;
  @State private selected: number = 0;

  aboutToAppear(): void { this.selected = this.startIndex; }

  build() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.End }) {
        Text((this.selected + 1) + ' / ' + this.screenshots.length).fontSize(14).fontWeight(FontWeight.Medium)
          .width('100%').textAlign(TextAlign.Center).fontColor(Color.White).id('listing-screenshot-page')
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(17).fontColor([Color.White])
        }.width(44).height(44).padding(0).backgroundColor('#28FFFFFF')
          .accessibilityText(I18n.t('关闭截图预览')).id('listing-screenshot-close')
          .onClick(() => this.controller?.close())
      }.width('100%').height(44)
      Swiper() {
        ForEach(this.screenshots, (source: string) => {
          StoreScreenshotImage({ appId: this.appId, source: source, edge: 1440 })
        }, (source: string) => source)
      }.width('100%').layoutWeight(1).index(this.selected)
        .loop(false).indicator(false).cachedCount(1).duration(250).disableSwipe(this.screenshots.length <= 1)
        .onChange((index: number) => { this.selected = index; }).id('listing-screenshot-swiper')
    }.width('94%').height('88%')
  }
}

@Component
export struct ListingScreenshotGallery {
  @Prop appId: number = 0;
  @Prop screenshots: string[] = [];
  @Prop darkMode: boolean = false;
  @State private viewportWidth: number = 248;
  private preview?: CustomDialogController;

  aboutToDisappear(): void { this.preview?.close(); }

  private open(index: number): void {
    if (this.preview) return;
    this.preview = new CustomDialogController({
      builder: ListingScreenshotPreview({ appId: this.appId, screenshots: this.screenshots.slice(), startIndex: index }),
      alignment: DialogAlignment.Center, customStyle: true, autoCancel: true,
      showInSubWindow: true, isModal: true, maskColor: '#E6000000',
      onDidDisappear: () => { this.preview = undefined; }
    });
    this.preview.open();
  }

  build() {
    Column({ space: 8 }) {
      Text(I18n.t('预览')).fontSize(18).fontWeight(FontWeight.Bold).width('100%').id('listing-screenshot-title')
        .fontColor(Palette.forMode(this.darkMode).text)
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.screenshots, (source: string, index: number) => {
            Stack() {
              StoreScreenshotImage({ appId: this.appId, source: source, edge: 560,
                deviceFrame: true, darkMode: this.darkMode, availableWidth: this.viewportWidth })
            }.id('listing-screenshot-' + index)
              .accessibilityText(I18n.t('界面截图') + ' ' + (index + 1))
              .onClick(() => this.open(index))
          }, (source: string) => String(this.appId) + ':' + source)
        }.height(220).alignItems(VerticalAlign.Center)
      }.width('100%').align(Alignment.TopStart)
        .scrollable(this.screenshots.length > 1 ? ScrollDirection.Horizontal : ScrollDirection.None)
        .scrollBar(BarState.Off)
        .fadingEdge(this.screenshots.length > 1, { fadingEdgeLength: LengthMetrics.vp(StoreLayout.horizontalFadeLength) })
        .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
          const width = Number(size.width);
          if (width > 0 && width !== this.viewportWidth) this.viewportWidth = width;
        })
    }.width('100%')
  }
}
