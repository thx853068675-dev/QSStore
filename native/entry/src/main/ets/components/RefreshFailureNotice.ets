import { uiMaterial } from '@kit.ArkUI';
import { MaterialPreferences } from '../data/MaterialPreferences';
import { I18n } from '../data/I18n';
import { Palette } from '../theme/Palette';
import { StoreMaterial } from '../theme/StoreMaterial';
import { StoreLayout } from '../theme/StoreDesign';

class RefreshNoticeMaterial implements AttributeModifier<CommonAttribute> {
  private material: uiMaterial.ImmersiveMaterial | undefined;
  private mode: string;
  private dark: boolean;
  constructor(mode: string, dark: boolean) {
    this.mode = mode; this.dark = dark;
    if (StoreMaterial.supported(mode)) {
      try {
        this.material = new uiMaterial.ImmersiveMaterial({ style: MaterialPreferences.style(mode),
          materialColor: '#00000000', colorInvert: true, applyShadow: false, interactive: false,
          lightEffect: { color: MaterialPreferences.lightColor(mode, Palette.forMode(dark).surface) } });
      } catch (_) { StoreMaterial.unavailable(); }
    }
  }
  applyNormalAttribute(instance: CommonAttribute): void {
    if (this.material && StoreMaterial.supported(this.mode)) {
      try { instance.backgroundColor(Color.Transparent).borderWidth(0).systemMaterial(this.material); return; }
      catch (_) { StoreMaterial.unavailable(); }
    }
    StoreMaterial.clearNative(instance);
    instance.backgroundBlurStyle(StoreMaterial.blurStyle(this.mode), {
      colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    }).backgroundColor(StoreMaterial.fallbackFill(this.dark))
      .borderWidth(0.5).borderColor(Palette.forMode(this.dark).border);
  }
}

/** Same readable width as app cards; native light and older-system glass share one content tree. */
@Component
export struct RefreshFailureNotice {
  @Prop message: string = '';
  @Prop darkMode: boolean = false;
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  retry: () => void = () => {};

  build() {
    Column({ space: 10 }) {
      Text(I18n.t('下拉或点按重试')).fontSize(12).maxLines(1)
        .width('100%').textAlign(TextAlign.Center)
        .fontColor(StoreMaterial.foreground(this.darkMode, false, this.materialMode))
      Text(this.message).fontSize(13).lineHeight(20).textAlign(TextAlign.Center)
        .fontColor(StoreMaterial.foreground(this.darkMode, true, this.materialMode))
    }.width('100%').padding({ left: 20, right: 20, top: 22, bottom: 22 })
      .borderRadius(StoreLayout.cardRadius).clip(true)
      .attributeModifier(new RefreshNoticeMaterial(this.materialMode, this.darkMode))
      .id('store-refresh-failure').onClick(() => this.retry())
  }
}
