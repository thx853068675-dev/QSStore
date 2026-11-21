import { common } from '@kit.AbilityKit';
import { AppearanceMode, AppearancePreferences } from '../data/AppearancePreferences';
import { AppBackgroundPreferences } from '../data/AppBackgroundPreferences';
import { I18n } from '../data/I18n';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';
import { AppThemeArtwork } from './AppThemeBackground';

@CustomDialog
export struct AppBackgroundDialog {
  controller?: CustomDialogController;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('appearanceMode') private savedAppearance: string = 'system';
  @StorageProp('windowHeight') private windowHeight: number = 760;
  @State private theme: string = 'default';
  @State private fit: string = 'cover';
  @State private photo: string = '';
  @State private uri: string = '';
  @State private appearance: AppearanceMode = 'system';
  @State private containerOpacity: number = 100;
  @State private photoMaskOpacity: number = 0;
  @State private picking: boolean = false;
  @State private saving: boolean = false;
  @State private message: string = '';
  private disposed: boolean = false;
  private context?: common.UIAbilityContext;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    const state = AppBackgroundPreferences.current();
    this.theme = state.theme;
    this.fit = state.fit;
    this.photo = state.photo;
    this.uri = state.uri;
    this.appearance = AppearancePreferences.normalize(this.savedAppearance);
    this.containerOpacity = state.containerOpacity;
    this.photoMaskOpacity = state.photoMaskOpacity;
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.context && !this.saving) AppBackgroundPreferences.discard(this.context, this.photo);
  }

  private async pick(): Promise<void> {
    const context = this.context;
    if (!context || this.picking || this.saving) return;
    this.picking = true;
    this.message = '';
    try {
      const photo = await AppBackgroundPreferences.pickPhoto(context);
      if (!photo) return;
      if (this.disposed) {
        await AppBackgroundPreferences.discard(context, photo);
        return;
      }
      AppBackgroundPreferences.discard(context, this.photo);
      this.photo = photo;
      this.uri = AppBackgroundPreferences.photoUri(context, photo);
      this.theme = 'photo';
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
    } finally { if (!this.disposed) this.picking = false; }
  }

  private async save(): Promise<void> {
    const context = this.context;
    if (!context || this.picking || this.saving) return;
    this.saving = true;
    this.message = '';
    try {
      await AppBackgroundPreferences.save(context, this.theme, this.fit, this.photo, this.appearance, this.containerOpacity,
        this.photoMaskOpacity);
      this.controller?.close();
    } catch (error) {
      if (!this.disposed) this.message = errorText(error);
    } finally {
      this.saving = false;
      if (this.disposed) await AppBackgroundPreferences.discard(context, this.photo);
    }
  }

  @Builder
  private themeOption(theme: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 5 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          AppThemeArtwork({ theme: theme, darkMode: this.appearance === 'system' ? this.darkMode : this.appearance === 'dark',
            miniature: true })
          if (this.theme === theme) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(11).fontColor([this.colors().onAccent])
              .width(19).height(19).align(Alignment.Center).borderRadius(10)
              .backgroundColor(this.colors().accent).margin(4)
          }
        }.height(38).width('100%').borderRadius(8).clip(true)
          .border({ width: 1, color: this.colors().border, radius: 8 })
        Text(AppBackgroundPreferences.themeLabel(theme)).fontSize(12).maxLines(1)
          .fontColor(this.theme === theme ? this.colors().accent : this.colors().textSecondary)
      }.width('100%')
    }.layoutWeight(1).padding(2).backgroundColor(Color.Transparent).borderRadius(9)
      .accessibilitySelected(this.theme === theme).enabled(!this.picking && !this.saving)
      .id('background-preset-' + theme).onClick(() => { this.theme = theme; })
  }

  @Builder
  private appearanceOption(mode: AppearanceMode, label: string) {
    Button(I18n.t(label), { type: ButtonType.Normal }).layoutWeight(1).height(40)
      .fontSize(13).fontColor(this.appearance === mode ? this.colors().accent : this.colors().text)
      .backgroundColor(this.appearance === mode ? this.colors().accentSoft : this.colors().fill).borderRadius(11)
      .accessibilitySelected(this.appearance === mode).enabled(!this.saving)
      .id('background-appearance-' + mode).onClick(() => { this.appearance = mode; })
  }

  @Builder
  private preview(dark: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      AppThemeArtwork({ theme: this.theme, fit: this.fit, photoUri: this.uri,
        photoMaskOpacity: this.photoMaskOpacity, darkMode: dark })
      Column({ space: 7 }) {
        Row() {
          Text(I18n.t('发现')).fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor(Palette.forMode(dark).text).layoutWeight(1)
          if (this.appearance === 'system') {
            Text(I18n.t(dark ? '深色' : '浅色')).fontSize(10).fontColor(Palette.forMode(dark).textBody)
          }
        }.width('100%')
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(11).fontColor([Palette.forMode(dark).textSecondary])
          Text(I18n.t('搜索应用')).fontSize(10).maxLines(1).fontColor(Palette.forMode(dark).textSecondary)
        }.width('100%').height(24).padding({ left: 7 }).borderRadius(12).backgroundColor(Palette.forMode(dark).fill)
        Row({ space: 6 }) {
          Image($r('app.media.app_icon')).width(24).height(24).borderRadius(6)
          Text(I18n.t('轻启·安装器')).fontSize(11).fontWeight(FontWeight.Medium).fontColor(Palette.forMode(dark).text)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').height(36).padding({ left: 7, right: 7 }).borderRadius(9)
          .backgroundColor(Palette.containerPaint(Palette.forMode(dark).surface, this.containerOpacity))
      }.width('100%').padding(9)
    }.layoutWeight(1).height(115).borderRadius(13).clip(true).id(dark ? 'background-preview-dark' : 'background-preview-light')
      .border({ width: 1, color: Palette.forMode(dark).border, radius: 13 })
  }

  @Builder
  private opacityControl(label: string, controlId: string, photoMask: boolean) {
    Column({ space: 2 }) {
      Row() {
        Text(I18n.t(label)).fontSize(13).fontColor(this.colors().text).layoutWeight(1)
        Text((photoMask ? this.photoMaskOpacity : this.containerOpacity) + '%')
          .fontSize(12).fontColor(this.colors().textSecondary).id(controlId + '-value')
      }.width('100%')
      Slider({ value: photoMask ? this.photoMaskOpacity : this.containerOpacity, min: 0, max: 100, step: 1,
        style: SliderStyle.InSet }).width('100%').height(34).selectedColor(this.colors().accent)
        .trackColor(this.colors().border).enabled(!this.saving).id(controlId)
        .accessibilityText(I18n.t(label)).onChange((value: number) => {
          if (photoMask) this.photoMaskOpacity = value;
          else this.containerOpacity = value;
        })
    }.width('100%')
  }

  @Builder
  private photoLayout() {
    Row({ space: 6 }) {
      ForEach(['cover', 'fill', 'contain'], (fit: string) => {
        Button(AppBackgroundPreferences.fitLabel(fit), { type: ButtonType.Capsule }).layoutWeight(1).height(36)
          .fontSize(12).fontColor(this.fit === fit ? this.colors().accent : this.colors().textSecondary)
          .backgroundColor(this.fit === fit ? this.colors().accentSoft : this.colors().fill)
          .accessibilitySelected(this.fit === fit).enabled(!this.picking && !this.saving)
          .id('background-fit-' + fit).onClick(() => { this.fit = fit; })
      }, (fit: string) => fit)
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 13 }) {
        Row({ space: 8 }) {
          Text(I18n.t('主题背景')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.colors().text).layoutWeight(1)
          StoreIconButton({ controlSize: 38, active: !this.saving,
            action: (): void => { this.controller?.close(); } })
        }.width('100%')
        Row({ space: 7 }) {
          if (this.appearance === 'system') {
            this.preview(false)
            this.preview(true)
          } else {
            this.preview(this.appearance === 'dark')
          }
        }.width('100%')
        Row({ space: 6 }) {
          this.appearanceOption('system', '跟随系统')
          this.appearanceOption('light', '浅色')
          this.appearanceOption('dark', '深色')
        }.width('100%')
        Row({ space: 6 }) {
          ForEach(AppBackgroundPreferences.choices(), (theme: string) => { this.themeOption(theme) },
            (theme: string) => theme)
        }.width('100%')
        Row({ space: 8 }) {
          if (this.photo) {
            Button(I18n.t('自定义图片'), { type: ButtonType.Capsule }).layoutWeight(1).height(38)
              .fontSize(12).fontColor(this.theme === 'photo' ? this.colors().accent : this.colors().text)
              .backgroundColor(this.theme === 'photo' ? this.colors().accentSoft : this.colors().fill)
              .enabled(!this.picking && !this.saving).accessibilitySelected(this.theme === 'photo')
              .id('background-custom-select').onClick(() => { this.theme = 'photo'; })
          }
          Button(I18n.t(this.picking ? '正在处理图片…' : this.photo ? '更换图片' : '选择自定义图片'),
            { type: ButtonType.Capsule }).layoutWeight(1).height(38).fontSize(12)
            .fontColor(this.colors().accent).backgroundColor(this.colors().fill)
            .enabled(!this.picking && !this.saving).id('background-photo-picker').onClick(() => this.pick())
        }.width('100%')
        if (this.theme === 'photo') {
          this.photoLayout()
          this.opacityControl('图片遮罩不透明度', 'background-photo-opacity', true)
        }
        this.opacityControl('卡片不透明度', 'background-opacity', false)
        if (this.message) {
          Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%')
        }
        Button(I18n.t('应用主题'), { type: ButtonType.Capsule }).height(44).width('100%')
          .fontSize(14).fontColor(this.colors().onAccent).backgroundColor(this.colors().accent)
          .enabled(!this.picking && !this.saving && (this.theme !== 'photo' || !!this.uri))
          .id('background-apply').onClick(() => this.save())
      }.width('100%').padding(18)
    }.width('calc(100% - 40vp)').constraintSize({ maxWidth: StoreLayout.sheetWidth, maxHeight: Math.max(250, this.windowHeight - 56) })
      .scrollBar(BarState.Off).borderRadius(StoreLayout.dialogRadius).backgroundColor(this.colors().surface)
  }
}
