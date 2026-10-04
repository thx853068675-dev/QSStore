import { SymbolGlyphModifier } from '@kit.ArkUI';
import { Palette } from './Palette';

/** 版本和分类共用的选择框，菜单与收起状态跟随页面主题。 */
@Component
export struct StoreSelect {
  @Prop options: SelectOption[] = [];
  @Prop selectedIndex: number = 0;
  @Prop selectedValue: string = '';
  @Prop active: boolean = true;
  controlId: string = '';
  action: (index: number) => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode); }

  @Builder
  private selectControl() {
    Select(this.options)
      .selected(this.selectedIndex).value(this.selectedValue)
      .font({ size: 14 }).fontColor(this.colors().text)
      .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
      .optionFont({ size: 13 }).optionFontColor(this.colors().text)
      .selectedOptionFontColor(this.colors().accent)
      .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
        .fontColor([this.colors().textSecondary]).fontSize(14))
      .selectedOptionBgColor(this.colors().accentSoft).optionBgColor(this.colors().surface)
      .menuBackgroundColor(this.colors().surface).menuBackgroundBlurStyle(BlurStyle.NONE)
      .divider({ strokeWidth: 0.5, color: this.colors().border })
      .backgroundColor(this.colors().fill).borderRadius(12).clip(true)
      .border({ width: 1, color: this.colors().border, radius: 12 })
      .width('100%').height(44).id(this.controlId).enabled(this.active)
      .onSelect((index: number) => this.action(index))
  }

  build() {
    WithTheme({ colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
      // 主题切换时重建原生菜单，选中值由调用页面保存。
      if (this.darkMode) {
        this.selectControl()
      } else {
        this.selectControl()
      }
    }
  }
}
