// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 设计令牌 —— 对齐 iOS / App Store 的视觉规范。
//
// 说明：本项目使用 Flutter 3.7.12-ohos（Dart 2.19.6），因此：
//   · 不使用 Dart 3 语法
//   · 不使用 Material 3 的较新 API
// 所有颜色同时给出浅色与深色两套，由 Theme 层选择。

import 'package:flutter/material.dart';

/// 间距刻度（8pt 网格）。
class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 44;

  /// 页面级水平内边距（唯一的"页面左边缘"）。
  ///
  /// 页面标题、分组标题、卡片外边距、通栏列表行的左右内边距全部用它，
  /// 否则同一屏上会出现 16 / 20 两条不同的左边缘——这是最容易被看成
  /// 「没对齐」的一类问题。
  ///
  /// 注意区分：卡片**内部**的内边距仍然用 [lg]，那是另一层。
  static const double pageGutter = 20;

  /// 最小可点区域（iOS HIG 44pt）。
  ///
  /// 视觉尺寸可以更小（药丸按钮 36、分段控件 32），但**命中区**要包到
  /// 这个尺寸，见 [AppButton] / [GetButton] / [SegmentedControl。
  static const double touch = 44;
}

/// 圆角刻度。取值范围收敛到 4 档 + 图标百分比，不允许再出现刻度外的字面量。
class Radii {
  /// 卡片
  static const double card = 20;

  /// 药丸按钮
  static const double button = 22;

  /// 半屏面板顶部
  static const double sheet = 28;

  /// 输入框 / 搜索框 / 标签
  static const double field = 12;

  /// 兼容旧名（与 [field] 同值）
  static const double chip = 12;

  /// App Store 图标圆角 = **边长 × 22.5%**。
  /// 这是百分比而不是绝对圆角，所以单独放在这里并在使用时乘边长。
  static const double iconCornerPercent = 22.5;
}

/// 控件尺寸。
class Sizes {
  /// 按钮：常规
  static const double buttonMd = 44;

  /// 按钮：页面主操作
  static const double buttonLg = 52;

  /// 列表行图标
  static const double rowIcon = 60;

  /// 详情页头图图标
  static const double detailIcon = 72;
}

/// 字号刻度（对齐 iOS Dynamic Type 的关键档位）。
class FontSizes {
  static const double largeTitle = 34;
  static const double title1 = 28;
  static const double title2 = 22;
  static const double title3 = 20;
  static const double headline = 17;
  static const double body = 17;
  static const double callout = 16;
  static const double subhead = 15;
  static const double footnote = 13;
  static const double caption = 12;
  static const double caption2 = 11;
}

/// 浅色 / 深色两套颜色。
///
/// 填充色按**语义**拆分，不再用一个 `fill` 扛五种用途：
/// [fillAction]（「获取」按钮）、[fillSelected]（选中态）、
/// [fillDisabled]（禁用态）、[fillPlaceholder]（头像/图标占位）、
/// [fillSecondary]（卡片内的次级底）。改其中一个不会连带影响其余。
class AppColors {
  const AppColors({
    required this.isDark,
    required this.background,
    required this.backgroundGrouped,
    required this.card,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.separator,
    required this.accent,
    required this.onAccent,
    required this.fillAction,
    required this.fillSelected,
    required this.fillDisabled,
    required this.fillPlaceholder,
    required this.fillSecondary,
    required this.green,
    required this.greenText,
    required this.red,
    required this.redText,
    required this.orange,
    required this.star,
  });

  final bool isDark;

  /// 页面底色
  final Color background;

  /// 分组列表底色（比 background 略深）
  final Color backgroundGrouped;

  /// 卡片 / 列表行底色
  final Color card;

  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color separator;

  /// 主色调（iOS systemBlue）
  final Color accent;

  /// 压在 [accent] 实底上的前景色。
  /// 深色下 accent 是亮蓝，白字只有 2.3:1，必须用深色前景。
  final Color onAccent;

  /// 「获取 / 安装」药丸按钮的底（iOS 用中性灰，不用主色淡染）
  final Color fillAction;

  /// 选中态底（底部导航、分段控件）
  final Color fillSelected;

  /// 禁用态按钮底
  final Color fillDisabled;

  /// 头像 / 图标占位底
  final Color fillPlaceholder;

  /// 卡片内的次级底（进度卡、说明条、分段控件轨道）
  final Color fillSecondary;

  /// 状态色：图标 / 描边用
  final Color green;
  final Color red;
  final Color orange;

  /// 状态色：**文字**用。浅色下 [green]/[red] 压白底只有 2.2 / 3.5:1，
  /// 达不到 4.5:1，所以文字单独给一组更深的。
  final Color greenText;
  final Color redText;

  /// 评分星色
  final Color star;

  static const AppColors light = AppColors(
    isDark: false,
    background: Color(0xFFFFFFFF),
    backgroundGrouped: Color(0xFFF6F7FB),
    card: Color(0xFFFFFFFF),
    text: Color(0xFF142033),
    textSecondary: Color(0xFF667085),
    textTertiary: Color(0xFF828C9E),
    separator: Color(0xFFD0D7E2),
    accent: Color(0xFF1769E0),
    onAccent: Color(0xFFFFFFFF),
    fillAction: Color(0xFFF0F3F8),
    fillSelected: Color(0xFFEDF1F7),
    fillDisabled: Color(0xFFEDF1F7),
    fillPlaceholder: Color(0xFFEDF1F7),
    fillSecondary: Color(0xFFF1F4F9),
    green: Color(0xFF34C759),
    greenText: Color(0xFF11763A),
    red: Color(0xFFFF3B30),
    redText: Color(0xFFC0271C),
    orange: Color(0xFFFF9500),
    star: Color(0xFFFF9500),
  );

  static const AppColors dark = AppColors(
    isDark: true,
    background: Color(0xFF000000),
    backgroundGrouped: Color(0xFF101722),
    card: Color(0xFF1A2431),
    text: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA8B4C5),
    textTertiary: Color(0xFF8494A9),
    separator: Color(0xFF334154),
    accent: Color(0xFF78ACFF),
    onAccent: Color(0xFF08111F),
    fillAction: Color(0xFF28313F),
    fillSelected: Color(0xFF28313F),
    fillDisabled: Color(0xFF28313F),
    fillPlaceholder: Color(0xFF28313F),
    fillSecondary: Color(0xFF253143),
    green: Color(0xFF30D158),
    greenText: Color(0xFF4CD964),
    red: Color(0xFFFF453A),
    redText: Color(0xFFFF6B61),
    orange: Color(0xFFFF9F0A),
    star: Color(0xFFFF9F0A),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 便捷扩展：`context.colors.accent`
extension AppColorsContext on BuildContext {
  AppColors get colors => AppColors.of(this);
}

/// 常用文本样式。
///
/// 每条都显式给出 [TextStyle.height]（行高倍数）。中文字形的默认行距
/// 比拉丁字母紧，不写死行高会让同一屏里的段落各用各的节奏——之前
/// 调用点里散着 1.12 / 1.35 / 1.45 / 1.5 四种临时值，就是从缺省值
/// 补出来的。统一在这里定，调用点不要再 copyWith(height:)。
class AppText {
  static TextStyle largeTitle(AppColors c) => TextStyle(
        fontSize: FontSizes.largeTitle,
        height: 1.18,
        fontWeight: FontWeight.w700,
        color: c.text,
        letterSpacing: 0.37,
      );

  static TextStyle title1(AppColors c) => TextStyle(
        fontSize: FontSizes.title1,
        height: 1.21,
        fontWeight: FontWeight.w700,
        color: c.text,
      );

  static TextStyle title2(AppColors c) => TextStyle(
        fontSize: FontSizes.title2,
        height: 1.27,
        fontWeight: FontWeight.w700,
        color: c.text,
      );

  static TextStyle title3(AppColors c) => TextStyle(
        fontSize: FontSizes.title3,
        height: 1.30,
        fontWeight: FontWeight.w600,
        color: c.text,
      );

  static TextStyle headline(AppColors c) => TextStyle(
        fontSize: FontSizes.headline,
        height: 1.29,
        fontWeight: FontWeight.w600,
        color: c.text,
      );

  static TextStyle body(AppColors c) => TextStyle(
        fontSize: FontSizes.body,
        height: 1.45,
        color: c.text,
      );

  static TextStyle callout(AppColors c) => TextStyle(
        fontSize: FontSizes.callout,
        height: 1.45,
        color: c.text,
      );

  static TextStyle subhead(AppColors c) => TextStyle(
        fontSize: FontSizes.subhead,
        height: 1.40,
        color: c.textSecondary,
      );

  static TextStyle footnote(AppColors c) => TextStyle(
        fontSize: FontSizes.footnote,
        height: 1.38,
        color: c.textSecondary,
      );

  static TextStyle caption(AppColors c) => TextStyle(
        fontSize: FontSizes.caption,
        height: 1.33,
        color: c.textSecondary,
      );
}

/// 全局主题构造。
ThemeData buildAppTheme(AppColors c) {
  // useMaterial3 必须显式传：ThemeData.light()/dark() 的默认值随 Flutter
  // 版本变化（3.7 是 M2，3.16 起变成 M3），不写死会让真机（鸿蒙工具链
  // 3.7.12）与开发机渲染出两套控件形状。
  final base = c.isDark
      ? ThemeData.dark(useMaterial3: false)
      : ThemeData.light(useMaterial3: false);

  // ★ 关键：Material 控件的默认色全部取自 colorScheme，**不是** primaryColor。
  // 只设 primaryColor 时，所有没写 style: 的 TextButton、CircularProgressIndicator、
  // LinearProgressIndicator、RadioListTile、输入框焦点色都会回落到框架自带的
  // 紫色（M2 #6200EE / M3 #6750A4），与本项目的蓝色主色冲突。
  final scheme = base.colorScheme.copyWith(
    primary: c.accent,
    // 深色下 accent 是亮蓝，白字压上去只有 2.3:1；用深色前景才可读。
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    surface: c.card,
    onSurface: c.text,
    background: c.backgroundGrouped,
    onBackground: c.text,
    error: c.red,
    onError: Colors.white,
  );

  return base.copyWith(
    colorScheme: scheme,
    // 锁死视觉密度。默认值 VisualDensity.adaptivePlatformDensity 在桌面
    // 平台是 compact，会把 Material 控件的 minSize 减 8pt（44 -> 36），
    // 于是同一个按钮在真机（移动端 standard）和开发机上高度不一样。
    // 这是纯移动端应用，统一用 standard。
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: c.backgroundGrouped,
    canvasColor: c.background,
    primaryColor: c.accent,
    dividerColor: c.separator,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: c.backgroundGrouped,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: AppText.headline(c).copyWith(fontSize: 17),
      iconTheme: IconThemeData(color: c.accent, size: 22),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: c.text,
      displayColor: c.text,
    ),
    iconTheme: IconThemeData(color: c.textSecondary),
  );
}
