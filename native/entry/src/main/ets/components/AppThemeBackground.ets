import { AppBackground } from '../data/AppBackgroundPreferences';
import { Palette } from '../theme/Palette';

@Component
export struct AppThemeArtwork {
  @Prop theme: string = 'default';
  @Prop fit: string = 'cover';
  @Prop photoUri: string = '';
  @Prop photoMaskOpacity: number = 0;
  @Prop darkMode: boolean = false;
  @Prop miniature: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  private mesh(): Resource {
    if (this.theme === 'fern') return this.darkMode ? $r('app.media.mesh_fern_dark') : $r('app.media.mesh_fern_light');
    if (this.theme === 'violet') return this.darkMode ? $r('app.media.mesh_violet_dark') : $r('app.media.mesh_violet_light');
    return this.darkMode ? $r('app.media.mesh_fog_dark') : $r('app.media.mesh_fog_light');
  }

  build() {
    Stack() {
      if (this.theme === 'photo' && this.photoUri) {
        Image(this.photoUri).width('100%').height('100%')
          .objectFit(this.fit === 'fill' ? ImageFit.Fill : this.fit === 'contain' ? ImageFit.Contain : ImageFit.Cover)
          .opacity(1 - this.photoMaskOpacity / 100)
      } else if (this.theme !== 'default' && this.theme !== 'photo') {
        if (this.miniature) {
          Image(this.mesh()).sourceSize({ width: 144, height: 180 })
            .width('100%').height('100%').objectFit(ImageFit.Cover)
        } else {
          Image(this.mesh()).width('100%').height('100%').objectFit(ImageFit.Cover)
        }
      }
    }.width('100%').height('100%').backgroundColor(this.colors().bg)
      .clip(true).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}

@Component
export struct AppThemeBackground {
  @StorageProp('appBackground') private themeState: AppBackground = new AppBackground();
  @StorageProp('darkMode') private darkMode: boolean = false;

  build() {
    if (this.themeState.theme !== 'default') {
      AppThemeArtwork({ theme: this.themeState.theme, fit: this.themeState.fit,
        photoUri: this.themeState.uri, photoMaskOpacity: this.themeState.photoMaskOpacity, darkMode: this.darkMode })
    }
  }
}
