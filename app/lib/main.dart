// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 应用入口。
//
// 启动顺序有意设计为「先让用户能用」：
//   1. 加载已安装记录与签名材料（本地，快）
//   2. 材料不全时展示引导，但**不阻断浏览商店**
//   3. 材料齐全才允许「安装」触发安装链路

import 'dart:async';

import 'package:flutter/material.dart';

import 'net/api_client.dart';
import 'net/downloader.dart';
import 'state/install_coordinator.dart';
import 'state/installed_store.dart';
import 'state/ohos_platform.dart';
import 'state/install_center.dart';
import 'state/native_bottom_tabs.dart';
import 'state/signing_setup.dart';
import 'state/sign_material_store.dart';
import 'theme/tokens.dart';
import 'view/detail/app_detail_page.dart';
import 'view/components/basic.dart';
import 'view/home_shell.dart';
import 'view/setup_guide_page.dart';
import 'view/certificate_manager_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBottomTabs.initialize();
  runApp(const HapStoreApp());
}

class _NativeTabsRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    NativeBottomTabs.routeAtRoot(previousRoute == null);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    NativeBottomTabs.routeAtRoot(previousRoute?.isFirst ?? true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    NativeBottomTabs.routeAtRoot(previousRoute?.isFirst ?? true);
  }
}

class HapStoreApp extends StatefulWidget {
  const HapStoreApp({super.key});

  @override
  State<HapStoreApp> createState() => _HapStoreAppState();
}

class _HapStoreAppState extends State<HapStoreApp> {
  final _api = ApiClient();
  final _downloader = MirrorDownloader();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _nativeTabsRouteObserver = _NativeTabsRouteObserver();
  Future<bool>? _pendingReconnect;

  InstalledStore? _installed;
  SignMaterialStore? _materials;
  SigningSetupController? _setup;
  String _materialStatus = '正在检测…';
  InstallCenter? _installCenter;

  /// 上一次 setup.ready 的值（用于在「首次就绪」时刷新材料状态）。
  bool _wasReady = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _api.dispose();
    _downloader.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final installed = await InstalledStore.load();
    final materials = await SignMaterialStore.load();
    _api.authTokenProvider = () => materials.agc?.authInfo?.jwtToken;
    _api.authAccessTokenProvider = () => materials.agc?.authInfo?.accessToken;

    final setup = SigningSetupController(
      materials: materials,
      platform: OhosInstallPlatform(materials: materials),
      api: _api,
    );
    // main 必须监听 setup：否则准备完成后主界面不会切过去
    // （引导页的按钮是空实现，之前因此卡在引导页出不来）。
    setup.addListener(() {
      if (!mounted) return;
      // 登录与连接首次完成时刷新材料状态——Profile 是登录后才生成的，
      // 启动时算的那份必然过期。
      final ready = setup.ready;
      if (ready && !_wasReady) _refreshMaterialStatus();
      _wasReady = ready;
      setState(() {});
    });
    // 已登录且材料齐全时直接认为第一步完成
    await setup.refresh();

    if (!mounted) return;
    setState(() {
      _installed = installed;
      _materials = materials;
      _setup = setup;
    });
    await _refreshMaterialStatus();
    unawaited(setup.syncIdentityToCloud());
    if (materials.isSignedIn &&
        (materials.accountAvatarUrl.isEmpty ||
         materials.agc?.authInfo?.nickName?.contains('*') == true)) {
      materials.refreshDeveloperAvatar().then((ok) {
        unawaited(setup.syncIdentityToCloud());
        if (ok && mounted) setState(() {});
      });
    }
  }

  /// 重算「材料状态」文本（登录 / 登出 / 连接完成后调用）。
  Future<void> _refreshMaterialStatus() async {
    final materials = _materials;
    if (materials == null) return;
    String status;
    try {
      status = await materials.describe();
    } catch (e) {
      status = '材料检测失败：$e';
    }
    if (mounted) setState(() => _materialStatus = status);
  }

  Future<bool> _requestReconnect() {
    if (_pendingReconnect != null) return _pendingReconnect!;
    final future = _showReconnectDialog();
    _pendingReconnect = future.whenComplete(() => _pendingReconnect = null);
    return _pendingReconnect!;
  }

  Future<bool> _showReconnectDialog() async {
    final context = _navigatorKey.currentContext;
    final setup = _setup;
    if (context == null || setup == null) return false;
    final c = context.colors;
    final portController = TextEditingController(text:
        setup.lastEnteredPort > 0 ? '${setup.lastEnteredPort}' :
        setup.connectedPort > 0 ? '${setup.connectedPort}' : '');
    var busy = false;
    String? error;
    try {
      // 全站其余确认面板都是半屏浮层，这里原本是唯一的 Material AlertDialog。
      final result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: c.backgroundGrouped,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        ),
        builder: (sheet) => StatefulBuilder(builder: (sheet, update) {
          final sc = sheet.colors;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(Space.pageGutter, Space.xl,
                  Space.pageGutter, MediaQuery.of(sheet).viewInsets.bottom + Space.xl),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('连接无线调试以继续安装', style: AppText.title2(sc)),
                    const SizedBox(height: Space.sm),
                    Text('调试端口可能已变化。查看系统设置中的新端口，连接后安装会继续。',
                        style: AppText.footnote(sc)),
                    const SizedBox(height: Space.lg),
                    TextField(
                      controller: portController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '调试端口',
                        prefixText: '127.0.0.1:',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.field),
                        ),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: Space.sm),
                      Text(error!, style: AppText.footnote(sc).copyWith(color: sc.redText)),
                    ],
                    const SizedBox(height: Space.lg),
                    AppButton(
                      label: '连接并继续',
                      expand: true,
                      busy: busy,
                      onPressed: () async {
                        final port = int.tryParse(portController.text.trim());
                        if (port == null || port < 1 || port > 65535) {
                          update(() => error = '请输入 1–65535 之间的端口号');
                          return;
                        }
                        update(() { busy = true; error = null; });
                        final failure = await setup.reconnectForInstall(port);
                        if (!sheet.mounted) return;
                        if (failure == null) {
                          Navigator.pop(sheet, true);
                        } else {
                          update(() { busy = false; error = failure; });
                        }
                      },
                    ),
                    const SizedBox(height: Space.sm),
                    AppButton(
                      label: '查看端口',
                      tone: AppButtonTone.secondary,
                      expand: true,
                      onPressed: () => setup.openWirelessSettings(),
                    ),
                    const SizedBox(height: Space.sm),
                    AppButton(
                      label: '取消安装',
                      tone: AppButtonTone.secondary,
                      expand: true,
                      onPressed: () => Navigator.pop(sheet, false),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      );
      return result ?? false;
    } finally {
      portController.dispose();
    }
  }

  /// 构造详情页依赖。
  DetailDeps _deps() {
    final materials = _materials!;
    return DetailDeps(
      api: _api,
      installed: _installed!,
      signConfig: () => materials.config,
      makeCoordinator: (onProgress) => InstallCoordinator(
        downloader: _downloader,
        platform: OhosInstallPlatform(materials: materials,
            requestReconnect: _requestReconnect),
        onProgress: onProgress,
      ),
    );
  }






  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [_nativeTabsRouteObserver],
      title: '轻启·安装器',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(AppColors.light),
      darkTheme: buildAppTheme(AppColors.dark),
      themeMode: ThemeMode.system,
      home: Builder(
        builder: (context) {
          final c = context.colors;
          final installed = _installed;
          final materials = _materials;
          final setup = _setup;
          if (installed == null || materials == null || setup == null) {
            return Scaffold(
              backgroundColor: c.backgroundGrouped,
              body: const Center(child: CircularProgressIndicator()),
            );
          }

          // 登录或无线调试连接未完成时显示引导；完成后进入主界面。
          // 允许跳过（浏览商店不需要准备），但不跳过就无法安装。
          // 准备没走完就不给进商店：连接没有意义，
          // 进去也装不了应用（安装依赖签名身份 + 无线调试通道）。
          if (!setup.ready) {
            return SetupGuidePage(
              controller: setup,
            );
          }

          return HomeShell(
            deps: _deps(),
            setup: setup,
            installCenter: _installCenter ??= InstallCenter(
              api: _api,
              downloader: _downloader,
              installed: installed,
              signConfig: () => materials.config,
              makeCoordinator: (onProgress) => InstallCoordinator(
                downloader: _downloader,
                platform: OhosInstallPlatform(materials: materials,
                    requestReconnect: _requestReconnect),
                onProgress: onProgress,
              ),
            ),
            materialStatus: _materialStatus,
            onManageMaterial: () => showCertificateManager(context, materials),
            accountLabel: materials.accountLabel,
            accountAvatarUrl: materials.accountAvatarUrl,
            onFetchAvatar: () async {
              final error = await materials.fetchAccountAvatar();
              if (mounted) setState(() {});
              return error;
            },
            isSignedIn: materials.isSignedIn,
            onLogin: () async {
              await setup.login();
              await _refreshMaterialStatus();
              if (mounted) setState(() {});
              if (materials.isSignedIn &&
                  (materials.accountAvatarUrl.isEmpty ||
                   materials.agc?.authInfo?.nickName?.contains('*') == true)) {
                materials.refreshDeveloperAvatar().then((ok) {
                  unawaited(setup.syncIdentityToCloud());
                  if (ok && mounted) setState(() {});
                });
              }
            },
            onLogout: () async {
              await materials.signOut();
              await _refreshMaterialStatus();
              if (mounted) setState(() {});
            },
          );
        },
      ),
    );
  }

}
