/**
 * 语义化调色板 —— 全应用唯一的颜色来源。
 *
 * 之前每个页面都把十六进制字面量写在组件上，一共约 30 个近似色
 * （#66758D / #758199 / #69778F / #64728A / #738096 …都是同一个"次要文字"），
 * 既无法切换深色，也没法统一调整。
 *
 * 页面通过 this.colors().xxx 取色。colors() 方法 读取 @StorageProp darkMode，
 * 因而颜色使用点会订阅主题变化；不再靠修改静态全局标记期待页面自动重绘。
 */
export class Palette {
  /** 每个主题一份不可变颜色；页面通过自身 darkMode 取值，建立渲染依赖。 */
  private static light?: Palette;
  private static night?: Palette;
  private dark: boolean;

  private constructor(dark: boolean) { this.dark = dark; }

  static forMode(dark: boolean): Palette {
    if (dark) {
      if (Palette.night === undefined) Palette.night = new Palette(true);
      return Palette.night;
    }
    if (Palette.light === undefined) Palette.light = new Palette(false);
    return Palette.light;
  }

  private pick(light: string, dark: string): string { return this.dark ? dark : light; }

  /** 页面底色 */
  get bg(): string { return this.pick('#F7F9FC', '#0B1220'); }
  /** 卡片 / 浮层底色 */
  get surface(): string { return this.pick('#FFFFFF', '#161F2E'); }
  /** 卡片内部的次级填充（条目底、输入框底） */
  get fill(): string { return this.pick('#F5F7FB', '#131C2A'); }
  /** 详情页头部那种带色调的底 */
  get hero(): string { return this.pick('#ECF3FF', '#16233A'); }
  /** 主色淡底（标签、次要按钮） */
  get accentSoft(): string { return this.pick('#E8EEFF', '#1E2C45'); }

  /** 主文字 */
  get text(): string { return this.pick('#17213A', '#EAF0F7'); }
  /** 正文 */
  get textBody(): string { return this.pick('#465977', '#C3CEDD'); }
  /** 次要说明 */
  get textSecondary(): string { return this.pick('#5F6E85', '#A6B5CB'); }
  /** 最弱：占位、脚注 */
  get textTertiary(): string { return this.pick('#64728A', '#8D9DB5'); }

  /** 主色 */
  get accent(): string { return this.pick('#2463E9', '#6FA0FF'); }
  /** 压在主色实底上的前景 */
  get onAccent(): string { return this.pick('#FFFFFF', '#08111F'); }
  /**
   * 主色实底上的次级文字（摘要、星数这类小字）。
   *
   * 不能直接用 `borderStrong`：那是给浅色卡片画描边用的浅蓝，压在主色底上只有
   * 3.6:1，12px 的小字读起来发虚。这里用带透明度的前景色，既压得住又比正文弱。
   */
  get onAccentSecondary(): string { return this.pick('#EBFFFFFF', '#B308111F'); }
  /** 主色实底上更弱的文字（角标、计数）。 */
  get onAccentTertiary(): string { return this.pick('#BFFFFFFF', '#9908111F'); }

  /** 描边 / 分隔线 */
  get border(): string { return this.pick('#EEF1F6', '#26344A'); }
  /** 选中描边 */
  get borderStrong(): string { return this.pick('#C6D8FB', '#31527F'); }

  /** 危险 / 破坏性 */
  get danger(): string { return this.pick('#B14848', '#FF8A80'); }
  get dangerSoft(): string { return this.pick('#FFF0F0', '#3A1F22'); }
  /** 成功 */
  get success(): string { return this.pick('#257B65', '#5DD3AE'); }
  get successSoft(): string { return this.pick('#E7F5EF', '#14322A'); }
  /** 评分星 / 提示 */
  get star(): string { return this.pick('#A5690F', '#FFC65C'); }

  /** 浮层遮罩 */
  get scrim(): string { return this.pick('#660B1530', '#99060B14'); }

  /** 底部导航未选中图标 */
  get tabIdle(): string { return this.pick('#66758D', '#8FA0B8'); }
}
