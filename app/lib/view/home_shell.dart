// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 应用外壳 —— 底部四个 Tab。
//
// 信息架构调整（原五个 Tab 的整合结果）：
//   在线商店 = 今日（精选）+ 应用（排行/分类）+ 搜索 合并为一个 Tab，
//   让出的位置给「离线安装」（安装本地 HAP，不需要商店与网络）。

import 'package:flutter/material.dart';

import '../state/install_center.dart';
import '../state/native_bottom_tabs.dart';
import '../state/signing_setup.dart';
import '../theme/tokens.dart';
import 'detail/app_detail_page.dart';
import 'pages/mine_page.dart';
import 'pages/offline_install_page.dart';
import 'pages/store_page.dart';
import 'pages/updates_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.deps,
    required this.setup,
    this.materialStatus,
    this.onManageMaterial,
    this.accountLabel = '未登录',
    this.accountAvatarUrl = '',
    this.isSignedIn = false,
    this.onLogin,
    this.onLogout,
    this.onFetchAvatar,
    this.installCenter,
  });

  final DetailDeps deps;
  final SigningSetupController setup;
  final String? materialStatus;
  final VoidCallback? onManageMaterial;
  final String accountLabel;
  final String accountAvatarUrl;
  final bool isSignedIn;
  final Future<void> Function()? onLogin;
  final Future<void> Function()? onLogout;
  final Future<String?> Function()? onFetchAvatar;

  /// 全局安装中心。为 null 时列表只展示、不提供安装按钮。
  final InstallCenter? installCenter;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// 浮动导航栏：选中态内圆角 = 外圆角 - 内边距，避免内层「顶角」。
const double _navMargin = 5;
const double _navPillRadius = Radii.button - _navMargin;
const double _navInkRadius = Radii.button - 6;

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _manageRefreshRevision = 0;

  @override
  void initState() {
    super.initState();
    NativeBottomTabs.attach(_selectTab);
  }

  @override
  void dispose() {
    NativeBottomTabs.detach();
    super.dispose();
  }

  void _selectTab(int index) {
    if (index < 0 || index > 3 || index == _index || !mounted) return;
    setState(() {
      _index = index;
      if (index == 2) _manageRefreshRevision++;
    });
    NativeBottomTabs.select(index);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // 用 IndexedStack 保留各 Tab 的滚动位置与状态（App Store 的行为）
    final pages = <Widget>[
      StorePage(deps: widget.deps, installCenter: widget.installCenter,
        isSignedIn: widget.isSignedIn, onLogin: widget.onLogin),
      OfflineInstallPage(deps: widget.deps),
      UpdatesPage(
        deps: widget.deps,
        installCenter: widget.installCenter,
        isSignedIn: widget.isSignedIn,
        refreshRevision: _manageRefreshRevision,
        onExplore: () => _selectTab(0),
      ),
      MinePage(
        api: widget.deps.api,
        setup: widget.setup,
        materialStatus: widget.materialStatus,
        onManageMaterial: widget.onManageMaterial,
        accountLabel: widget.accountLabel,
        accountAvatarUrl: widget.accountAvatarUrl,
        installed: widget.deps.installed,
        isSignedIn: widget.isSignedIn,
        onLogin: widget.onLogin,
        onLogout: widget.onLogout,
        onFetchAvatar: widget.onFetchAvatar,
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      // Reserve the native bar's hit area so the last list item stays tappable.
      bottomNavigationBar: NativeBottomTabs.isSupported
          ? const SizedBox(height: 86)
          : SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(Radii.button),
            border:
                Border.all(color: c.separator.withOpacity(0.75), width: 0.7),
            boxShadow: c.isDark
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFF192B4D).withOpacity(0.10),
                      blurRadius: 26,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58),
            child: Row(
              children: [
                _tab(0, Icons.explore_outlined, Icons.explore, '发现'),
                _tab(1, Icons.folder_open_outlined, Icons.folder_open, '本地'),
                _tab(2, Icons.dashboard_customize_outlined,
                    Icons.dashboard_customize, '管理'),
                _tab(3, Icons.person_outline, Icons.person, '我的'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(int i, IconData icon, IconData activeIcon, String label) {
    final c = context.colors;
    final selected = _index == i;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(_navInkRadius),
          onTap: () => _selectTab(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: _navMargin),
            decoration: BoxDecoration(
              color: selected ? c.fillSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(_navPillRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedScale(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  scale: selected ? 1 : 0.94,
                  child: Icon(
                    selected ? activeIcon : icon,
                    size: 22,
                    color: selected ? c.accent : c.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? c.accent : c.textSecondary,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}
