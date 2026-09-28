// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 基础组件 —— 对齐 App Store 的视觉语言。
//
// 设计要点：
//   · 图标圆角 = 边长 × Radii.iconCornerPercent（App Store 的连续圆角观感）
//   · 所有填充按钮走 [AppButton]，尺寸只有 md(44) / lg(52) 两档，圆角只有 Radii.button
//   · 视觉尺寸可以小于 44pt，但命中区一律包到 Space.touch（iOS HIG）
//   · 状态色分「图标用」与「文字用」两组，文字必须 ≥ 4.5:1

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../model/store_models.dart';
import '../../net/api_client.dart';
import '../../state/install_center.dart';
import '../../state/install_coordinator.dart';
import '../../theme/tokens.dart';

/// 按钮语气。
enum AppButtonTone {
  /// 主操作：主色实底
  primary,

  /// 次操作：浅色实底 + 主色文字
  secondary,

  /// 危险操作：红色文字
  destructive,
}

/// 全站唯一的填充按钮。
///
/// 收敛之前散在各页的 6 种高度（36/40/44/46/50/52）、3 种圆角
/// （16/20/22）和 4 种实现（TextButton / FilledButton / Material+InkWell / 手搓）。
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.tone = AppButtonTone.primary,
    this.size = Sizes.buttonMd,
    this.busy = false,
    this.expand = false,
    this.progress,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppButtonTone tone;

  /// [Sizes.buttonMd] 或 [Sizes.buttonLg]
  final double size;
  final bool busy;

  /// 占满可用宽度
  final bool expand;

  /// 0..1；有值时按钮内叠加进度填充层
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final disabled = onPressed == null && !busy;

    final Color bg;
    final Color fg;
    switch (tone) {
      case AppButtonTone.primary:
        bg = disabled ? c.fillDisabled : c.accent;
        fg = disabled ? c.textSecondary : c.onAccent;
        break;
      case AppButtonTone.secondary:
        bg = c.fillAction;
        fg = disabled ? c.textSecondary : c.accent;
        break;
      case AppButtonTone.destructive:
        bg = c.fillAction;
        fg = disabled ? c.textSecondary : c.redText;
        break;
    }

    Widget content;
    if (busy) {
      content = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: fg),
      );
    } else if (icon == null) {
      content = Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: fg,
          fontSize: FontSizes.callout,
          fontWeight: FontWeight.w600,
        ),
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: FontSizes.callout,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }

    // 固定高度会让文本缩放时被裁切，改用 minHeight。
    final button = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: size,
        minWidth: expand ? double.infinity : 0,
      ),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.button),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: disabled || busy ? null : onPressed,
          // alignment 必须显式写成 center：Stack 默认是 topStart，而它的
          // 非定位子节点是 shrink-wrap 的，结果是内容被顶到左上角，
          // 外层 ConstrainedBox 撑出来的宽高全浪费掉。
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (progress != null && busy)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress!.clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: ColoredBox(color: fg.withOpacity(0.22)),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg, vertical: Space.md),
                // heightFactor 必须写：Center 默认会撑满父级的高度，
                // 放在有界高度的容器里按钮会变成整屏高。
                child: Center(widthFactor: 1, heightFactor: 1, child: content),
              ),
            ],
          ),
        ),
      ),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 纯文字动作按钮（「打开」「加载更多」「重试」这类）。
///
/// 与 [AppButton] 同一套尺寸与命中区约定，只是没有底色。
class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.tone = AppButtonTone.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final Color fg;
    if (onPressed == null) {
      fg = c.textSecondary;
    } else if (tone == AppButtonTone.destructive) {
      fg = c.redText;
    } else {
      fg = c.accent;
    }

    final TextStyle style = TextStyle(
      color: fg,
      fontSize: FontSizes.subhead,
      fontWeight: FontWeight.w500,
    );

    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: fg,
        // 命中区一律 44，视觉高度交给内容
        minimumSize: const Size(0, Space.touch),
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.field),
        ),
      ),
      child: icon == null
          ? Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: Space.xs + 2),
                Flexible(
                  child: Text(label,
                      style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
    );
  }
}

/// 四个主页面共用的标题区。副标题负责解释当前页面的用途。
class PageIntro extends StatelessWidget {
  const PageIntro({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Space.pageGutter, 22, Space.pageGutter, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.largeTitle(c)),
                const SizedBox(height: 5),
                Text(subtitle, style: AppText.subhead(c)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 详情页采用可侧滑返回的页面转场。
class AppPageRoute<T> extends CupertinoPageRoute<T> {
  AppPageRoute({required WidgetBuilder builder}) : super(builder: builder);
}

/// App 图标：圆角方块 + 首字母兜底。
///
/// 不引入 cached_network_image：多一个依赖，而这里只需要简单的
/// 加载失败兜底。Flutter 自身的 Image.network 已带内存缓存。
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    required this.size,
    this.imageUrl,
    this.fallbackText = '',
    this.showBorder = true,
  });

  final double size;
  final String? imageUrl;
  final String fallbackText;
  final bool showBorder;

  static final Map<String, Future<Uint8List?>> _images = {};

  /// 带证书固定与体积上限的取图。头像等其它地方复用同一条路径，
  /// 避免各处自己 new NetworkImage（既不固定证书，也没有失败兜底）。
  static Future<Uint8List?> fetchBytes(String url) =>
      _images.putIfAbsent(url, () => _fetch(url));

  static Future<Uint8List?> _fetch(String url) async {
    final client = HttpClient();
    final pin = ApiClient.pinnedCertSha256.toLowerCase();
    final apiHost = Uri.parse(ApiClient.defaultBaseUrl).host;
    client.badCertificateCallback = (cert, host, port) =>
        host == apiHost &&
        pin.isNotEmpty &&
        sha256.convert(cert.der).toString() == pin;
    try {
      var uri = Uri.parse(url);
      for (var redirect = 0; redirect < 4; redirect++) {
        if (uri.scheme != 'https') return null;
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        final cert = response.certificate;
        if (uri.host == apiHost &&
            pin.isNotEmpty &&
            (cert == null || sha256.convert(cert.der).toString() != pin)) {
          await response.drain<void>();
          return null;
        }
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) return null;
          uri = uri.resolve(location);
          continue;
        }
        final type = response.headers.contentType?.mimeType ?? '';
        if (response.statusCode != 200 ||
            !type.startsWith('image/') ||
            response.contentLength > 2 * 1024 * 1024) {
          await response.drain<void>();
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytes.add(chunk);
          if (bytes.length > 2 * 1024 * 1024) return null;
        }
        return bytes.takeBytes();
      }
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final radius = size * Radii.iconCornerPercent / 100;

    Widget fallback() {
      final text = fallbackText.isNotEmpty
          ? fallbackText.characters.first.toUpperCase()
          : '?';
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: c.isDark
                ? const [Color(0xFF3A3A3C), Color(0xFF2C2C2E)]
                : const [Color(0xFFE5E5EA), Color(0xFFD1D1D6)],
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontSize: size * 0.34,
            fontWeight: FontWeight.w600,
            color: c.textSecondary,
          ),
        ),
      );
    }

    if (_images.length > 200) _images.clear();
    final child = (imageUrl == null || imageUrl!.isEmpty)
        ? fallback()
        : FutureBuilder<Uint8List?>(
            future: fetchBytes(imageUrl!),
            builder: (context, snapshot) => snapshot.data == null
                ? fallback()
                : Image.memory(snapshot.data!,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => fallback()),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        decoration: showBorder
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: c.separator.withOpacity(0.35),
                  width: 0.5,
                ),
              )
            : null,
        child: child,
      ),
    );
  }
}

/// 圆形头像。
///
/// 复用 [AppIconTile] 的取图路径（证书固定 + 体积上限 + 失败兜底），
/// 不要再直接用 `CircleAvatar(foregroundImage: NetworkImage(...))`——
/// 那条路径既绕过证书固定，URL 失效时也没有兜底。
class NetworkAvatar extends StatelessWidget {
  const NetworkAvatar({
    super.key,
    required this.radius,
    this.imageUrl = '',
    this.fallbackText = '',
    this.onTap,
  });

  final double radius;
  final String imageUrl;
  final String fallbackText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final letter =
        fallbackText.isEmpty ? '' : fallbackText.characters.first.toUpperCase();

    Widget placeholder() => Container(
          width: radius * 2,
          height: radius * 2,
          color: c.fillPlaceholder,
          alignment: Alignment.center,
          child: letter.isEmpty
              ? Icon(Icons.person_rounded, color: c.accent, size: radius)
              : Text(
                  letter,
                  style: TextStyle(
                    fontSize: radius * 0.85,
                    fontWeight: FontWeight.w600,
                    color: c.textSecondary,
                  ),
                ),
        );

    Widget child = placeholder();
    if (imageUrl.isNotEmpty && Uri.tryParse(imageUrl)?.scheme == 'https') {
      child = FutureBuilder<Uint8List?>(
        future: AppIconTile.fetchBytes(imageUrl),
        builder: (context, snap) => snap.data == null
            ? placeholder()
            : Image.memory(
                snap.data!,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder(),
              ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipOval(
        child: SizedBox(width: radius * 2, height: radius * 2, child: child),
      ),
    );
  }
}

/// 「获取」按钮的四种状态。
enum GetButtonState { idle, downloading, installing, installed }

/// App Store 风格的圆形药丸按钮。
class GetButton extends StatefulWidget {
  const GetButton({
    super.key,
    required this.state,
    this.label = '获取',
    this.progress = 0,
    this.onPressed,
    this.compact = false,
  });

  final GetButtonState state;
  final String label;

  /// 0..1，整个下载、签名和安装流程的总进度
  final double progress;
  final VoidCallback? onPressed;

  /// 紧凑模式用于列表行
  final bool compact;

  @override
  State<GetButton> createState() => _GetButtonState();
}

class _GetButtonState extends State<GetButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final busy = widget.state == GetButtonState.downloading ||
        widget.state == GetButtonState.installing;

    final text = widget.state == GetButtonState.installed ? '打开' : widget.label;

    // 四种状态必须一眼可分。之前 idle 与 installed 都渲染成
    // 「淡色药丸 + 主色文字」，实测底色对比度只有 1.02:1，等于没有区别。
    // 现在照 App Store 的做法：可安装 = 有底药丸；已安装 = 纯文字。
    final Color bg;
    final Color fg;
    final bool outlined;
    switch (widget.state) {
      case GetButtonState.installed:
        bg = Colors.transparent;
        fg = c.accent;
        outlined = true;
        break;
      case GetButtonState.downloading:
      case GetButtonState.installing:
        bg = c.fillAction;
        fg = c.textSecondary;
        outlined = false;
        break;
      case GetButtonState.idle:
        bg = c.fillAction;
        fg = c.accent;
        outlined = false;
        break;
    }

    final h = widget.compact ? 34.0 : 38.0;
    final minW = widget.compact ? 78.0 : 92.0;

    return Semantics(
      button: true,
      label: busy ? '$text（进行中）' : text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: busy ? null : (_) => setState(() => _pressed = true),
        onTapUp: busy ? null : (_) => setState(() => _pressed = false),
        onTapCancel: busy ? null : () => setState(() => _pressed = false),
        onTap: busy ? null : widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 90),
          // 视觉高度可以小于 44，但命中区必须包到 Space.touch。
          child: Container(
            constraints: const BoxConstraints(minHeight: Space.touch),
            alignment: Alignment.center,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: BoxConstraints(minWidth: minW, minHeight: h),
              padding: EdgeInsets.symmetric(
                horizontal: busy ? Space.sm : Space.lg,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Radii.button),
                border: outlined
                    ? Border.all(color: c.accent.withOpacity(0.35), width: 1)
                    : null,
              ),
              alignment: Alignment.center,
              child: busy
                  ? _BusyContent(
                      progress: widget.progress,
                      state: widget.state,
                      color: fg,
                      height: h,
                    )
                  : Text(
                      text,
                      style: TextStyle(
                        color: fg,
                        fontSize: FontSizes.subhead,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BusyContent extends StatelessWidget {
  const _BusyContent({
    required this.progress,
    required this.state,
    required this.color,
    required this.height,
  });

  final double progress;
  final GetButtonState state;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    // 圆环进度 + 中心方块（App Store 的下载中样式）
    final d = height - 12;
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            backgroundColor: color.withOpacity(0.18),
          ),
          Container(
            width: d * 0.32,
            height: d * 0.32,
            decoration: BoxDecoration(
              color: color,
              // 下载方块是个图形，不属于圆角刻度
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表行：图标 + 标题 + 副标题 + 尾部按钮。
class AppRowCard extends StatelessWidget {
  const AppRowCard({
    super.key,
    required this.app,
    this.iconUrl,
    this.onTap,
    this.trailing,
    this.subtitle,
    this.rank,
    this.showDivider = true,
    this.onLongPress,
  });

  final StoreApp app;
  final String? iconUrl;
  final VoidCallback? onTap;

  /// 次级操作（如「移除记录」）走长按，避免 trailing 塞两个按钮把标题挤变形。
  final VoidCallback? onLongPress;
  final Widget? trailing;

  /// 覆盖默认副标题
  final String? subtitle;

  /// 排行榜序号（有值时显示在图标左侧）
  final int? rank;

  /// 行与行之间的 hairline。发现页是通栏白底列表，没有分隔线时
  /// 相邻两行会连成一块白板，看不出边界。
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // 分隔线从文字列开始（缩进 = 栅格 + 序号列 + 图标 + 间距），
    // 这是 iOS 列表的做法。
    final double indent = Space.pageGutter +
        (rank != null ? _rankWidth : 0) +
        Sizes.rowIcon +
        Space.md;

    final row = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: c.card,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.pageGutter,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            if (rank != null) ...[
              SizedBox(
                width: _rankWidth,
                child: Text(
                  '$rank',
                  style: TextStyle(
                    fontSize: FontSizes.headline,
                    fontWeight: FontWeight.w600,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
            AppIconTile(
              size: Sizes.rowIcon,
              imageUrl: iconUrl,
              fallbackText: app.displayName,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          app.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.headline(c),
                        ),
                      ),
                      if (app.verified) ...[
                        const SizedBox(width: Space.xs),
                        Icon(Icons.verified, size: 14, color: c.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle ?? app.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption(c),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );

    if (!showDivider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Padding(
          padding: EdgeInsets.only(left: indent),
          child: Divider(height: 0.5, thickness: 0.5, color: c.separator),
        ),
      ],
    );
  }
}

/// 排行榜序号列的宽度。
const double _rankWidth = 28;

/// 分组标题（App Store 的「全部」右侧链接样式）。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.pageGutter,
        Space.lg,
        Space.md,
        Space.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppText.title2(c)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppText.caption(c)),
                ],
              ],
            ),
          ),
          if (actionLabel != null)
            AppTextButton(label: actionLabel!, onPressed: onAction),
        ],
      ),
    );
  }
}

/// 分组容器（圆角卡片，用于「我的」等设置页）。
class GroupedCard extends StatelessWidget {
  const GroupedCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: margin ??
          const EdgeInsets.symmetric(
              horizontal: Space.pageGutter, vertical: Space.xs),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: c.separator.withOpacity(0.7), width: 0.7),
        boxShadow: c.isDark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF192B4D).withOpacity(0.035),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// 分组内的一行（可点、可带尾部说明）。
class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leadingIcon,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final IconData? leadingIcon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = destructive ? c.red : c.text;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.md,
            ),
            child: Row(
              children: [
                if (leadingIcon != null) ...[
                  Icon(leadingIcon, size: 20, color: c.accent),
                  const SizedBox(width: Space.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: AppText.body(c).copyWith(color: color),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: AppText.caption(c)),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: Space.sm),
                  Text(value!, style: AppText.subhead(c)),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: Space.sm),
                  trailing!,
                ],
                if (onTap != null && trailing == null) ...[
                  const SizedBox(width: Space.sm),
                  Icon(Icons.chevron_right, size: 18, color: c.textTertiary),
                ],
              ],
            ),
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: Space.lg),
            child: Divider(height: 0.5, thickness: 0.5, color: c.separator),
          ),
      ],
    );
  }
}

/// 评分星（支持半星）。
class RatingStars extends StatelessWidget {
  const RatingStars({
    super.key,
    required this.rating,
    this.size = 12,
    this.showValue = true,
    this.count,
  });

  final double rating;
  final double size;
  final bool showValue;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final full = rating.floor();
    final half = (rating - full) >= 0.25 && (rating - full) < 0.75;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            i < full
                ? Icons.star
                : (i == full && half ? Icons.star_half : Icons.star_border),
            size: size,
            color: i < full || (i == full && half) ? c.star : c.textTertiary,
          ),
        if (showValue) ...[
          const SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(
              fontSize: size,
              color: c.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (count != null) ...[
          const SizedBox(width: 4),
          Text(
            '($count)',
            style: TextStyle(fontSize: size, color: c.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// 空状态 / 错误状态占位。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: c.fillPlaceholder,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: Icon(icon, size: 34, color: c.accent),
            ),
            const SizedBox(height: Space.xl),
            Text(title,
                style: AppText.headline(c), textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                message!,
                style: AppText.footnote(c),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: Space.xl),
              AppButton(
                label: actionLabel!,
                onPressed: onAction,
                expand: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分段控件（iOS Segmented Control）。
class SegmentedControl extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.fillSecondary,
        borderRadius: BorderRadius.circular(Radii.field),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  // iOS 原生分段控件就是 32pt 轨道高（平台约定，我们不自创），
                  // 用 minHeight 是为了文本放大时不被裁切。
                  constraints: const BoxConstraints(minHeight: 32),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? c.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.field - 2),
                    boxShadow: i == selectedIndex
                        ? [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    segments[i],
                    style: TextStyle(
                      fontSize: FontSizes.footnote,
                      fontWeight: i == selectedIndex
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: i == selectedIndex ? c.text : c.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表项里的一键安装按钮。
///
/// 与详情页的「获取」按钮共用 [GetButton] 的视觉，但状态来自全局的
/// [InstallCenter] —— 这样同一应用在列表与详情页显示的是同一份进度。
class InstallActionButton extends StatelessWidget {
  const InstallActionButton({
    super.key,
    required this.center,
    required this.app,
    this.compact = true,
  });

  final InstallCenter center;
  final StoreApp app;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 监听安装中心，进度变化时重建
    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        final s = center.stateOf(app.id);
        final installed = center.isInstalled(app.id);

        GetButtonState state;
        String label = '安装';

        if (s.busy) {
          // 下载阶段显示环形进度，其余阶段显示不确定进度
          state = s.stage == InstallStage.downloading ||
                  s.stage == InstallStage.probing ||
                  s.stage == InstallStage.verifying
              ? GetButtonState.downloading
              : GetButtonState.installing;
        } else if (installed) {
          state = GetButtonState.installed;
        } else if (s.stage == InstallStage.failed) {
          state = GetButtonState.idle;
          label = '重试';
        } else {
          state = GetButtonState.idle;
        }

        return GetButton(
          state: state,
          label: label,
          progress: s.ratio,
          compact: compact,
          onPressed: () {
            if (installed && !s.busy) {
              center.openApp(app.id).then((ok) {
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('无法打开 ${app.displayName}，请确认应用仍在设备上')),
                  );
                }
              });
              return;
            }
            center.installApp(app);
          },
        );
      },
    );
  }
}
