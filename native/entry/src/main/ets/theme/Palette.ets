/**
 * 语义化调色板 —— 全应用唯一的颜色来源。
 *
 * 之前每个页面都把十六进制字面量写在组件上，一共约 30 个近似色
 * （#66758D / #758199 / #69778F / #64728A / #738096 …都是同一个"次要文字"），
 * 既无法切换深色，也没法统一调整。
 *
 * 用法：
 *   @StorageProp('darkMode') @Watch('syncPalette') darkMode: boolean = false;
 *   syncPalette(): void { Palette.dark = this.darkMode; }
 * 然后所有颜色写 Palette.xxx。`darkMode` 变化会触发 @Watch → 改静态标记 →
 * 组件重渲染时取到新值。
 */
export class Palette {
  /** 当前是否深色。由 EntryAbility 通过 AppStorage('darkMode') 驱动。 */
  static dark: boolean = false;

  private static pick(light: string, dark: string): string {
    return Palette.dark ? dark : light;
  }

  /** 页面底色 */
  static get bg(): string { return Palette.pick('#F9FAFD', '#0B1220'); }
  /** 卡片 / 浮层底色 */
  static get surface(): string { return Palette.pick('#FFFFFF', '#161F2E'); }
  /** 卡片内部的次级填充（条目底、输入框底） */
  static get fill(): string { return Palette.pick('#F5F7FB', '#131C2A'); }
  /** 详情页头部那种带色调的底 */
  static get hero(): string { return Palette.pick('#ECF3FF', '#16233A'); }
  /** 主色淡底（标签、次要按钮） */
  static get accentSoft(): string { return Palette.pick('#E8EEFF', '#1E2C45'); }

  /** 主文字 */
  static get text(): string { return Palette.pick('#17213A', '#EAF0F7'); }
  /** 正文 */
  static get textBody(): string { return Palette.pick('#465977', '#C3CEDD'); }
  /** 次要说明 */
  static get textSecondary(): string { return Palette.pick('#66758D', '#9FB0C7'); }
  /** 最弱：占位、脚注 */
  static get textTertiary(): string { return Palette.pick('#98A3B5', '#71829A'); }

  /** 主色 */
  static get accent(): string { return Palette.pick('#2463E9', '#6FA0FF'); }
  /** 压在主色实底上的前景 */
  static get onAccent(): string { return Palette.pick('#FFFFFF', '#08111F'); }

  /** 描边 / 分隔线 */
  static get border(): string { return Palette.pick('#EEF1F6', '#26344A'); }
  /** 选中描边 */
  static get borderStrong(): string { return Palette.pick('#C6D8FB', '#31527F'); }

  /** 危险 / 破坏性 */
  static get danger(): string { return Palette.pick('#B14848', '#FF8A80'); }
  static get dangerSoft(): string { return Palette.pick('#FFF0F0', '#3A1F22'); }
  /** 成功 */
  static get success(): string { return Palette.pick('#257B65', '#5DD3AE'); }
  static get successSoft(): string { return Palette.pick('#E7F5EF', '#14322A'); }
  /** 评分星 / 提示 */
  static get star(): string { return Palette.pick('#FFB431', '#FFC65C'); }

  /** 浮层遮罩 */
  static get scrim(): string { return Palette.pick('#660B1530', '#99060B14'); }

  /** 底部导航未选中图标 */
  static get tabIdle(): string { return Palette.pick('#66758D', '#8FA0B8'); }
}
