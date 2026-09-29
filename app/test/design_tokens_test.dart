// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 设计令牌与布局栅格的回归测试。
//
// 这些断言锁的是「容易被无意改回去」的约定：
//   · 主题必须显式关闭 Material 3，并把 colorScheme 接到应用主色上
//   · 页面级左边缘只允许一条（Space.pageGutter）
//   · 文本样式必须带行高
//
// 起因见 docs/DESIGN-REVIEW-UI.md：之前只设了 primaryColor、没设
// colorScheme，导致所有没写 style: 的 Material 控件（TextButton、
// 进度条、Radio 等）全部回落到框架自带的紫色。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hapstore/model/store_models.dart';
import 'package:hapstore/theme/tokens.dart';
import 'package:hapstore/view/components/basic.dart';

/// WCAG 2.1 相对对比度。
double _contrast(Color a, Color b) {
  double channel(int v) {
    final double c = v / 255.0;
    return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  double luminance(Color c) =>
      0.2126 * channel((c.value >> 16) & 0xFF) +
      0.7152 * channel((c.value >> 8) & 0xFF) +
      0.0722 * channel(c.value & 0xFF);

  final double l1 = luminance(a);
  final double l2 = luminance(b);
  return l1 > l2 ? (l1 + 0.05) / (l2 + 0.05) : (l2 + 0.05) / (l1 + 0.05);
}

StoreApp _app() => StoreApp(
      id: 1,
      repo: 'thx853068675-dev/starstore-harmonyos',
      owner: 'thx853068675-dev',
      name: 'starstore-harmonyos',
      displayName: '轻启·安装器',
      summary: '从 GitHub 发现 HAP 应用',
      description: '',
      iconUrl: '',
      category: '工具',
      tags: const <String>[],
      stars: 42,
      verified: true,
      featured: false,
      releasesCount: 12,
    );

void main() {
  group('主题层', () {
    test('显式关闭 Material 3，避免随 SDK 版本漂移', () {
      expect(buildAppTheme(AppColors.light).useMaterial3, isFalse);
      expect(buildAppTheme(AppColors.dark).useMaterial3, isFalse);
    });

    test('视觉密度锁定为 standard，避免桌面平台把控件缩小 8pt', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        expect(buildAppTheme(c).visualDensity, VisualDensity.standard);
      }
    });

    test('colorScheme 跟随应用主色（只设 primaryColor 是不够的）', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        final ThemeData t = buildAppTheme(c);
        expect(t.colorScheme.primary, c.accent);
        expect(t.colorScheme.secondary, c.accent);
        expect(t.colorScheme.surface, c.card);
        expect(t.colorScheme.onSurface, c.text);
        expect(t.colorScheme.error, c.red);
      }
    });

    test('主色按钮的前景与主色对比度不低于 4.5:1', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        final ThemeData t = buildAppTheme(c);
        expect(
          _contrast(t.colorScheme.primary, t.colorScheme.onPrimary),
          greaterThanOrEqualTo(4.5),
          reason: '${c.isDark ? "深色" : "浅色"}下 FilledButton 的字压不出对比',
        );
      }
    });
  });

  group('Material 默认色', () {
    testWidgets('未加 style 的 TextButton 用应用主色，不是框架紫色', (tester) async {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(c),
          home: Scaffold(
            body: TextButton(onPressed: () {}, child: const Text('加载更多')),
          ),
        ));
        await tester.pump();
        // MaterialApp 的主题切换有 200ms 动画，必须等它结束再取色。
        await tester.pumpAndSettle();
        final RenderParagraph p =
            tester.renderObject<RenderParagraph>(find.text('加载更多'));
        expect(p.text.style?.color, c.accent,
            reason: '${c.isDark ? "深色" : "浅色"}下 TextButton 回落到了框架默认色');
      }
    });

    testWidgets('未指定颜色的进度条落到 colorScheme.primary', (tester) async {
      final ThemeData t = buildAppTheme(AppColors.light);
      await tester.pumpWidget(MaterialApp(
        theme: t,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      ));
      final CircularProgressIndicator cpi = tester
          .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      // valueColor 为 null 时框架取 colorScheme.primary。
      expect(cpi.valueColor, isNull);
      expect(t.colorScheme.primary, AppColors.light.accent);
    });
  });

  group('页面栅格', () {
    testWidgets('页面标题 / 分组标题 / 卡片 / 通栏行共用一条左边缘', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: ListView(children: <Widget>[
            const PageIntro(title: '我的', subtitle: '账号、签名与应用来源'),
            const SectionHeader(title: '签名与设备授权'),
            GroupedCard(children: <Widget>[
              GroupedRow(
                title: '无线调试',
                subtitle: '上次连接端口 41235',
                leadingIcon: Icons.wifi_tethering_rounded,
                showDivider: false,
                onTap: () {},
              ),
            ]),
            AppRowCard(app: _app(), subtitle: '42 ★'),
          ]),
        ),
      ));
      await tester.pump();

      const double gutter = Space.pageGutter;
      expect(tester.getTopLeft(find.text('我的')).dx, gutter,
          reason: 'PageIntro 页面标题');
      expect(tester.getTopLeft(find.text('签名与设备授权')).dx, gutter,
          reason: 'SectionHeader 分组标题');
      // GroupedCard 的最外层盒子含 margin，取真正绘制卡片底色的裁剪节点。
      final Rect cardRect = tester.getRect(find
          .descendant(of: find.byType(GroupedCard), matching: find.byType(ClipPath))
          .first);
      expect(cardRect.left, gutter, reason: 'GroupedCard 卡片可见左边缘');
      expect(cardRect.right, tester.getSize(find.byType(GroupedCard)).width - gutter,
          reason: 'GroupedCard 卡片可见右边缘');
      expect(tester.getTopLeft(find.byType(AppRowCard)).dx, 0,
          reason: 'AppRowCard 是通栏行，盒子本身贴边');
      expect(tester.getTopLeft(find.byType(AppIconTile)).dx, gutter,
          reason: 'AppRowCard 的图标应落在页面栅格上');
    });

    testWidgets('卡片内部是第二层：行内容 = 栅格 + Space.lg', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: GroupedCard(children: <Widget>[
            GroupedRow(
              title: '无线调试',
              leadingIcon: Icons.wifi_tethering_rounded,
              showDivider: false,
              onTap: () {},
            ),
          ]),
        ),
      ));
      await tester.pump();
      // 卡片有 0.7 的描边，Container 会把描边宽度算进子节点的内边距。
      expect(tester.getTopLeft(find.byIcon(Icons.wifi_tethering_rounded)).dx,
          closeTo(Space.pageGutter + Space.lg, 1.0));
    });
  });

  group('GroupedRow', () {
    testWidgets('value 与 chevron 之间必须有间距', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: GroupedCard(children: <Widget>[
            GroupedRow(title: '签名材料', value: '已就绪', onTap: () {}),
          ]),
        ),
      ));
      await tester.pump();

      final double valueRight = tester.getTopRight(find.text('已就绪')).dx;
      final double chevronLeft =
          tester.getTopLeft(find.byIcon(Icons.chevron_right)).dx;
      expect(chevronLeft - valueRight, greaterThanOrEqualTo(Space.sm),
          reason: '「已就绪」和右箭头贴在一起了');
    });
  });

  group('令牌完整性', () {
    test('颜色语义已拆分，不再有「一个 fill 扛五种用途」', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        // 五个填充语义必须彼此独立可取（编译期即保证），且都不能等于强调色本身
        expect(c.fillAction == c.accent, isFalse);
        expect(c.fillDisabled == c.accent, isFalse);
        expect(c.fillPlaceholder == c.accent, isFalse);
        expect(c.onAccent == c.accent, isFalse);
        // 文字用状态色必须比图标用状态色更深（浅色）/ 更亮（深色）
        expect(c.greenText == c.green, isFalse);
        expect(c.redText == c.red, isFalse);
      }
    });

    test('圆角刻度收敛为 4 档', () {
      expect(Radii.field, 12);
      expect(Radii.card, 20);
      expect(Radii.button, 22);
      expect(Radii.sheet, 28);
      expect(Radii.chip, Radii.field);
    });
  });

  group('排版', () {
    test('每个文本样式都带行高', () {
      final AppColors c = AppColors.light;
      final Map<String, TextStyle> styles = <String, TextStyle>{
        'largeTitle': AppText.largeTitle(c),
        'title1': AppText.title1(c),
        'title2': AppText.title2(c),
        'title3': AppText.title3(c),
        'headline': AppText.headline(c),
        'body': AppText.body(c),
        'callout': AppText.callout(c),
        'subhead': AppText.subhead(c),
        'footnote': AppText.footnote(c),
        'caption': AppText.caption(c),
      };
      styles.forEach((String name, TextStyle style) {
        expect(style.height, isNotNull, reason: '$name 没有行高');
      });
    });

    test('字阶单调：标题不小于正文', () {
      final AppColors c = AppColors.light;
      expect(AppText.largeTitle(c).fontSize!,
          greaterThan(AppText.title2(c).fontSize!));
      expect(AppText.title2(c).fontSize!,
          greaterThan(AppText.headline(c).fontSize!));
      expect(AppText.headline(c).fontSize!,
          greaterThan(AppText.footnote(c).fontSize!));
      expect(AppText.footnote(c).fontSize!,
          greaterThan(AppText.caption(c).fontSize!));
    });
  });

  group('颜色对比度', () {
    test('文字色在两种底色上都不低于 4.5:1', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        final List<List<Color>> pairs = <List<Color>>[
          <Color>[c.text, c.card],
          <Color>[c.text, c.backgroundGrouped],
          <Color>[c.textSecondary, c.card],
          <Color>[c.textSecondary, c.backgroundGrouped],
          <Color>[c.accent, c.card],
          <Color>[c.accent, c.fillAction],
          <Color>[c.onAccent, c.accent],
          <Color>[c.greenText, c.card],
          <Color>[c.redText, c.card],
          <Color>[c.redText, c.fillAction],
        ];
        for (final List<Color> pair in pairs) {
          expect(_contrast(pair[0], pair[1]), greaterThanOrEqualTo(4.5),
              reason: '${c.isDark ? "深色" : "浅色"} '
                  '${pair[0]} on ${pair[1]} 不到 4.5:1');
        }
      }
    });

    test('图标色（textTertiary）不低于 3:1', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        expect(_contrast(c.textTertiary, c.card), greaterThanOrEqualTo(3.0));
        expect(_contrast(c.textTertiary, c.backgroundGrouped),
            greaterThanOrEqualTo(3.0));
      }
    });

    test('分隔线在卡片上可见（>= 1.4:1）', () {
      for (final AppColors c in <AppColors>[AppColors.light, AppColors.dark]) {
        expect(_contrast(c.separator, c.card), greaterThanOrEqualTo(1.4));
      }
    });
  });

  group('控件尺寸', () {
    testWidgets('AppButton 只有两档高度，圆角统一', (tester) async {
      for (final double size in <double>[Sizes.buttonMd, Sizes.buttonLg]) {
        await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(AppColors.light),
          home: Scaffold(
            body: Center(
              child: AppButton(label: '安装', size: size, onPressed: () {}),
            ),
          ),
        ));
        await tester.pump();
        final Size s = tester.getSize(find.byType(AppButton));
        expect(s.height, size);
        final Material m = tester.widget<Material>(find.descendant(
            of: find.byType(AppButton), matching: find.byType(Material)).first);
        final BorderRadius r = m.borderRadius! as BorderRadius;
        expect(r.topLeft.x, Radii.button);
      }
    });

    testWidgets('GetButton 视觉高度小于 44，但命中区补到 Space.touch', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: Center(
            child: GetButton(
                state: GetButtonState.idle, label: '安装', compact: true),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.getSize(find.byType(GetButton)).height,
          greaterThanOrEqualTo(Space.touch));
    });

    testWidgets('AppButton 的文字在水平和垂直方向都居中', (tester) async {
      // 回归：Stack 默认 alignment 是 topStart，非定位子节点 shrink-wrap，
      // 曾经导致按钮里的文字被顶到左上角。
      for (final bool expand in <bool>[true, false]) {
        for (final double sz in <double>[Sizes.buttonMd, Sizes.buttonLg]) {
          await tester.pumpWidget(MaterialApp(
            theme: buildAppTheme(AppColors.light),
            home: Scaffold(
              body: Center(
                child: AppButton(
                    label: '安装', size: sz, expand: expand, onPressed: () {}),
              ),
            ),
          ));
          await tester.pump();
          final Offset buttonCenter =
              tester.getCenter(find.byType(AppButton));
          final Offset textCenter = tester.getCenter(find.text('安装'));
          expect((textCenter.dx - buttonCenter.dx).abs(),
              lessThanOrEqualTo(0.5),
              reason: 'expand=$expand size=$sz 文字水平不居中');
          expect((textCenter.dy - buttonCenter.dy).abs(),
              lessThanOrEqualTo(0.5),
              reason: 'expand=$expand size=$sz 文字垂直不居中');
        }
      }
    });

    testWidgets('AppButton 带图标时整体居中', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: Center(
            child: AppButton(
                label: '选择 HAP 文件',
                icon: Icons.folder_open,
                size: Sizes.buttonLg,
                expand: true,
                onPressed: () {}),
          ),
        ),
      ));
      await tester.pump();
      final Rect button = tester.getRect(find.byType(AppButton));
      final Rect row = tester.getRect(find.byIcon(Icons.folder_open));
      final Rect label = tester.getRect(find.text('选择 HAP 文件'));
      // 图标 + 文字作为一个整体应当水平居中
      final double groupCenter = (row.left + label.right) / 2;
      expect((groupCenter - button.center.dx).abs(), lessThanOrEqualTo(0.5),
          reason: '图标+文字整体不水平居中');
      expect((row.center.dy - button.center.dy).abs(), lessThanOrEqualTo(0.5),
          reason: '图标不垂直居中');
    });

    testWidgets('GetButton 的文字同样居中', (tester) async {
      for (final bool compact in <bool>[true, false]) {
        await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(AppColors.light),
          home: Scaffold(
            body: Center(
              child: GetButton(
                  state: GetButtonState.idle,
                  label: '安装',
                  compact: compact,
                  onPressed: () {}),
            ),
          ),
        ));
        await tester.pump();
        final Offset pill = tester.getCenter(find.byType(AnimatedContainer));
        final Offset text = tester.getCenter(find.text('安装'));
        expect((text.dx - pill.dx).abs(), lessThanOrEqualTo(0.5),
            reason: 'compact=$compact 水平不居中');
        expect((text.dy - pill.dy).abs(), lessThanOrEqualTo(0.5),
            reason: 'compact=$compact 垂直不居中');
      }
    });

    testWidgets('AppTextButton 命中区也补到 Space.touch', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(
          body: Center(
            child: AppTextButton(label: '加载更多', onPressed: () {}),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.getSize(find.byType(AppTextButton)).height, Space.touch);
    });

    testWidgets('AppRowCard 默认带分隔线，且从文字列开始缩进', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(AppColors.light),
        home: Scaffold(body: AppRowCard(app: _app(), subtitle: 'x')),
      ));
      await tester.pump();
      final Finder divider = find.descendant(
          of: find.byType(AppRowCard), matching: find.byType(Divider));
      expect(divider, findsOneWidget);
      // 缩进 = 栅格 + 图标 + 间距
      final Rect d = tester.getRect(divider);
      expect(d.left, Space.pageGutter + Sizes.rowIcon + Space.md);
    });
  });

  group('GetButton 状态可分', () {
    testWidgets('已安装是纯文字，可安装是有底药丸', (tester) async {
      Widget wrap(GetButtonState st) => MaterialApp(
            theme: buildAppTheme(AppColors.light),
            home: Scaffold(
              body: Center(
                child: GetButton(state: st, label: '安装', onPressed: () {}),
              ),
            ),
          );
      await tester.pumpWidget(wrap(GetButtonState.idle));
      await tester.pump();
      BoxDecoration deco() => tester
          .widget<AnimatedContainer>(find.byType(AnimatedContainer))
          .decoration! as BoxDecoration;
      expect(deco().color, AppColors.light.fillAction);

      await tester.pumpWidget(wrap(GetButtonState.installed));
      await tester.pump();
      final BoxDecoration installed = deco();
      expect(installed.color, Colors.transparent);
      expect(installed.border, isNotNull);
    });
  });
}
