import { Palette } from './Palette';

/** 四个主页面和浮层共用的布局尺度，宽屏保留舒适的阅读宽度。 */
export class StoreLayout {
  static readonly contentWidth: number = 720;
  static readonly sheetWidth: number = 520;

  static inset(width: number): number { return width > 0 && width < 360 ? 16 : 24; }
}

/** 原生按钮提供按压与焦点反馈；符号、触摸区域和读屏名称始终一致。 */
@Component
export struct StoreIconButton {
  symbol: Resource = $r('sys.symbol.xmark');
  label: string = '关闭';
  @Prop active: boolean = true;
  action: () => void = () => {};
  @StorageProp('darkMode') private darkMode: boolean = false;

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.symbol).fontSize(18)
        .fontColor([Palette.forMode(this.darkMode).textSecondary])
    }.width(44).height(44)
      .backgroundColor(Palette.forMode(this.darkMode).fill)
      .enabled(this.active).stateEffect(true)
      .accessibilityText(this.label)
      .onClick(() => this.action())
  }
}
