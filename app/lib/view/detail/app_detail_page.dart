// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 应用详情页 —— 对齐 App Store 的详情页信息架构。
//
// 与 App Store 的关键差异（必须让用户看得懂）：
//   App Store 的「获取」是下载即可用；这里的「安装」是
//   **下载 → 用你自己的证书在本机重签 → 安装到本机**。
//   之所以必须重签：HarmonyOS 的 HAP 需要含目标设备 UDID 的调试 Profile，
//   别人的签名包无法直接安装。这一点在页面上有明确说明。

import 'package:flutter/material.dart';
import 'package:ohos_adapter/ohos_adapter.dart';
import 'package:signing_core/signing_core.dart';

import '../../model/store_models.dart';
import '../../net/api_client.dart';
import '../../state/install_center.dart';
import '../../state/install_coordinator.dart';
import '../../state/installed_store.dart';
import '../../theme/tokens.dart';
import '../components/basic.dart';

/// 详情页所需的运行时依赖。
class DetailDeps {
  const DetailDeps({
    required this.api,
    required this.installed,
    required this.makeCoordinator,
    required this.signConfig,
  });

  final ApiClient api;
  final InstalledStore installed;

  /// 由外层构造协调器（注入平台能力与进度回调）
  final InstallCoordinator Function(void Function(InstallProgress))
      makeCoordinator;

  /// 当前签名材料
  final SignConfig Function() signConfig;
}

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({
    super.key,
    required this.deps,
    required this.appId,
    this.installCenter,
  });

  final DetailDeps deps;
  final int appId;

  /// 全局安装中心。有值时「安装」按钮与列表页共享同一份进度。
  final InstallCenter? installCenter;

  @override
  State<AppDetailPage> createState() => _AppDetailPageState();
}

class _AppDetailPageState extends State<AppDetailPage> {
  StoreApp? _app;
  List<AppRelease> _releases = const [];
  Object? _error;
  bool _loading = true;

  InstallProgress _progress = InstallProgress(stage: InstallStage.idle);
  int _selectedAssetIndex = 0;
  int _selectedReleaseIndex = 0;
  Future<List<AppReview>>? _reviews;

  @override
  void initState() {
    super.initState();
    _load();
    _reviews = widget.deps.api.listReviews(widget.appId);
    // 进度来自全局 InstallCenter（ChangeNotifier），页面必须监听它，
    // 否则安装过程中不会 rebuild，进度面板一直是点击前的旧状态。
    widget.installCenter?.addListener(_onCenterChanged);
  }

  @override
  void didUpdateWidget(AppDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.installCenter != widget.installCenter) {
      oldWidget.installCenter?.removeListener(_onCenterChanged);
      widget.installCenter?.addListener(_onCenterChanged);
    }
  }

  @override
  void dispose() {
    widget.installCenter?.removeListener(_onCenterChanged);
    super.dispose();
  }

  void _onCenterChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = await widget.deps.api.appDetail(widget.appId);
      final releases =
          await widget.deps.api.listReleases(widget.appId, pageSize: 30);
      if (!mounted) return;
      setState(() {
        _app = app;
        // 只展示含 HAP 的版本，最新的排前面
        _releases = releases.items.where((r) => r.hasHap).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 当前选中的 release / asset。
  AppRelease? get _currentRelease => _releases.isEmpty ? null
      : _releases[_selectedReleaseIndex.clamp(0, _releases.length - 1)];

  List<HapAsset> get _assetsOfLatest =>
      _currentRelease?.installableAssets ?? const [];

  HapAsset? get _selectedAsset {
    final list = _assetsOfLatest;
    if (list.isEmpty) return null;
    final i = _selectedAssetIndex.clamp(0, list.length - 1);
    return list[i];
  }

  bool get _isInstalled {
    final app = _app;
    final asset = _selectedAsset;
    if (app == null || asset == null) return false;
    final record = widget.deps.installed.findBundle(app.id, asset.bundleName);
    if (record == null) return false;
    return asset.versionCode > 0 && record.installedVersionCode == asset.versionCode;
  }

  Future<void> _openSelectedApp() async {
    final bundle = _selectedAsset?.bundleName ?? '';
    bool ok = false;
    if (bundle.isNotEmpty) {
      try {
        final record = widget.deps.installed.findBundle(_app!.id, bundle);
        ok = await OhosAdapter().openInstalledApp(bundle,
            abilityName: record?.mainAbility ?? '',
            moduleName: record?.moduleName ?? '');
      } catch (_) {}
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开应用，请确认应用仍在设备上')),
      );
    }
  }

  /// 当前生效的进度：优先用全局安装中心（与列表页共享）。
  InstallProgress get _effectiveProgress {
    final center = widget.installCenter;
    final app = _app;
    if (center == null || app == null) return _progress;
    final s = center.stateOf(app.id);
    return InstallProgress(
      stage: s.stage,
      stageDetail: s.detail,
      error: s.error,
      issues: s.issues,
    );
  }

  double get _effectiveRatio {
    final center = widget.installCenter;
    final app = _app;
    if (center == null || app == null) return _progress.overallRatio;
    return center.stateOf(app.id).ratio;
  }

  Future<void> _startInstall() async {
    final app = _app;
    final asset = _selectedAsset;
    if (app == null || asset == null) return;

    // 有全局中心时委托给它 —— 列表页与详情页共享同一份进度与登记逻辑
    final center = widget.installCenter;
    if (center != null) {
      await center.installApp(app, asset: asset);
      if (!mounted) return;
      final s = center.stateOf(app.id);
      _showResultDialog(
        ok: s.stage == InstallStage.done,
        message: s.stage == InstallStage.done
            ? (s.detail.isEmpty ? '安装成功。' : s.detail)
            : (s.error ?? '安装失败'),
      );
      return;
    }

    final coordinator = widget.deps.makeCoordinator((p) {
      if (mounted) setState(() => _progress = p);
    });

    final outcome = await coordinator.run(
      app: app,
      asset: asset,
      signConfig: widget.deps.signConfig(),
    );

    if (!mounted) return;

    if (outcome.ok) {
      // 登记已安装（用于「更新」页与「我的」）
      await widget.deps.installed.remember(InstalledRecord(
        appId: app.id,
        repo: app.repo,
        displayName: app.displayName,
        summary: app.summary,
        iconUrl: app.iconUrl,
        bundleName: outcome.bundleName.isNotEmpty ? outcome.bundleName : asset.bundleName,
        installedVersionCode: outcome.versionCode > 0 ? outcome.versionCode : asset.versionCode,
        installedVersionName: outcome.versionName.isNotEmpty ? outcome.versionName : asset.versionName,
        installedAt: DateTime.now().millisecondsSinceEpoch,
        mainAbility: outcome.mainAbility,
        moduleName: outcome.moduleName,
      ));
      if (!mounted) return;
      _showResultDialog(
        ok: true,
        message: outcome.didRegenerate ? '安装成功。已自动更新本机的设备授权。' : '安装成功。',
      );
    } else {
      _showResultDialog(ok: false, message: outcome.message ?? '安装失败');
    }
  }

  void _showResultDialog({required bool ok, required String message}) {
    final c = context.colors;
    // 预检问题来自全局安装中心或本地进度（取决于走的哪条路径），取当前生效的那份。
    final issues = _effectiveProgress.issues;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    ok ? Icons.check_circle : Icons.error_outline,
                    color: ok ? c.green : c.red,
                    size: 22,
                  ),
                  const SizedBox(width: Space.sm),
                  Text(ok ? '完成' : '未能完成', style: AppText.headline(c)),
                ],
              ),
              const SizedBox(height: Space.md),
              Text(message, style: AppText.callout(c)),
              if (!ok && issues.isNotEmpty) ...[
                const SizedBox(height: Space.md),
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          issue.severity == Severity.error
                              ? Icons.close
                              : Icons.info_outline,
                          size: 14,
                          color: issue.severity == Severity.error
                              ? c.red
                              : c.orange,
                        ),
                        const SizedBox(width: Space.xs),
                        Expanded(
                          child: Text(issue.message, style: AppText.caption(c)),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: Space.lg),
              AppButton(
                label: '好',
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      if (mounted) {
        setState(() => _progress = InstallProgress(stage: InstallStage.idle));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _app == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.cloud_off,
          title: '无法加载应用',
          message: '${_error ?? "未知错误"}',
          actionLabel: '重试',
          onAction: _load,
        ),
      );
    }

    final app = _app!;
    final busy = _effectiveProgress.isBusy;
    final assets = _assetsOfLatest;

    return Scaffold(
      backgroundColor: c.backgroundGrouped,
      extendBody: true,
      appBar: AppBar(
        title: Text(app.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          if (_releases.isNotEmpty)
            IconButton(
              tooltip: '在 GitHub 查看',
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => ohosAdapter.openUrl(_currentRelease!.htmlUrl),
            ),
        ],
      ),
      body: ListView(
        // 底部按钮（52 + 8 + 16）+ 安全区 + 一点余量。写死 124 在
        // 没有底部安全区的设备上会多留约 48pt 空白。
        padding: EdgeInsets.only(
            bottom: Sizes.buttonLg +
                Space.lg +
                Space.xl +
                MediaQuery.of(context).padding.bottom),
        children: [
          _header(app),
          if (assets.length > 1) _assetPicker(assets),
          if (_releases.isNotEmpty) ...[
            const SectionHeader(title: '版本更新'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(color: c.separator),
                ),
                  child: _ReleaseNotes(body: _currentRelease!.body),
              ),
            ),
          ],
          const SizedBox(height: Space.lg),
          _infoSection(app),
          _versionHistory(),
          _reviewSection(app),
          _signingNote(),
        ],
      ),
      bottomNavigationBar: _floatingInstallButton(busy),
    );
  }

  Widget _floatingInstallButton(bool busy) {
    final progress = _effectiveRatio.clamp(0.0, 1.0);
    final enabled = _selectedAsset != null && !busy;
    final tag = _currentRelease?.tag ?? '';
    // 版本号过长时不再塞进按钮（真实 tag 有 21 字符，窄屏必然截断），
    // 只保留「安装」；版本号在下方版本历史里可见。
    final label = busy
        ? '${_effectiveProgress.stage.label}  ${(progress * 100).round()}%'
        : _isInstalled
            ? '打开'
            : (tag.isNotEmpty && tag.length <= 12 ? '安装 $tag' : '安装');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            Space.pageGutter, Space.sm, Space.pageGutter, Space.lg),
        child: AppButton(
          label: label,
          size: Sizes.buttonLg,
          expand: true,
          busy: busy,
          progress: busy ? progress : null,
          onPressed: enabled ? (_isInstalled ? _openSelectedApp : _startInstall) : null,
        ),
      ),
    );
  }

  Widget _header(StoreApp app) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.md, Space.pageGutter, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIconTile(
                  size: 72,
                  imageUrl: widget.deps.api.resolve(app.iconUrl),
                  fallbackText: app.displayName,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.category.isEmpty ? 'HARMONYOS 应用' : app.category,
                          style: AppText.caption(c).copyWith(
                            color: c.accent,
                            fontWeight: FontWeight.w700,
                          )),
                      const SizedBox(height: 5),
                      Text(
                        app.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title2(c),
                      ),
                      const SizedBox(height: 4),
                      Text(app.publisherName.isEmpty ? '上架者未记录' : '由 ${app.publisherName} 上架',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption(c)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(app.summary, style: AppText.callout(c)),
            const SizedBox(height: 12),
            Text('${app.stars} ★  ·  ${app.releasesCount} 个版本  ·  本机签名安装',
                style: AppText.caption(c)),
          ],
        ),
      ),
    );
  }

  /// 多 HAP 附件选择器。
  ///
  /// 轻启的 release 同时挂着主包与助手包（两个不同 bundle），
  /// 因此必须让用户明确选择装哪个，而不是替他猜。
  Widget _assetPicker(List<HapAsset> assets) {
    final c = context.colors;
    final selected = _selectedAsset;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.pageGutter, 10, Space.pageGutter, 0),
      child: Material(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
        child: ListTile(
          title: Text('安装包', style: AppText.body(c)),
          subtitle: Text(selected?.name ?? '请选择 HAP',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.subhead(c)),
          trailing: Icon(Icons.chevron_right_rounded, color: c.textTertiary),
          onTap: _effectiveProgress.isBusy ? null : () async {
            final index = await showModalBottomSheet<int>(
              context: context,
              backgroundColor: c.backgroundGrouped,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
              ),
              builder: (sheet) => SafeArea(child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.pageGutter, Space.pageGutter, Space.xl),
                child: Column(mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('选择要安装的 HAP', style: AppText.title2(c)),
                  const SizedBox(height: 12),
                  for (var i = 0; i < assets.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(i == _selectedAssetIndex
                          ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: i == _selectedAssetIndex ? c.accent : c.textSecondary),
                      title: Text(assets[i].name, style: AppText.footnote(c)),
                      subtitle: Text('${assets[i].sizeText} · ${assets[i].bundleName}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppText.caption(c)),
                      onTap: () => Navigator.of(sheet).pop(i),
                    ),
                ]),
              )),
            );
            if (mounted && index != null) setState(() => _selectedAssetIndex = index);
          },
        ),
      ),
    );
  }

  Widget _infoSection(StoreApp app) {
    return GroupedCard(
      children: [
        GroupedRow(
          title: '来源仓库',
          subtitle: app.repo,
          trailing: Icon(Icons.open_in_new_rounded, size: 18, color: context.colors.accent),
          onTap: () => ohosAdapter.openUrl('https://github.com/${app.repo}'),
        ),
        GroupedRow(
          title: '授权状态',
          value: app.verified ? '已验证' : '未验证',
          subtitle: app.verified ? '作者已证明对该仓库的所有权' : '尚未验证仓库归属，安装前请自行确认来源可信',
          showDivider: false,
          onTap: null,
        ),
      ],
    );
  }

  Widget _versionHistory() {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: '版本历史',
          subtitle: '可选择安装任意历史版本',
        ),
        for (var i = 0; i < _releases.length; i++) ...[
          InkWell(
          onTap: _effectiveProgress.isBusy ? null : () => setState(() {
            _selectedReleaseIndex = i;
            _selectedAssetIndex = 0;
          }),
          child: Container(
            color: c.card,
            padding: const EdgeInsets.symmetric(
                horizontal: Space.pageGutter, vertical: Space.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(_releases[i].name.isEmpty ? _releases[i].tag : _releases[i].name,
                              style: AppText.headline(c)),
                          if (_releases[i].prerelease) ...[
                            const SizedBox(width: Space.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: c.orange.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(Radii.chip),
                              ),
                              child: Text('测试版',
                                  style: AppText.caption(c)
                                      .copyWith(color: c.orange)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_releases[i].dateText}  ·  ${_releases[i].installableAssets.length} 个 HAP',
                        style: AppText.caption(c),
                      ),
                    ],
                  ),
                ),
                if (i == _selectedReleaseIndex)
                  Icon(Icons.check_circle_rounded, color: c.accent, size: 20)
                else if (i == 0)
                  Text('最新', style: AppText.caption(c).copyWith(color: c.greenText)),
              ],
            ),
          )),
          // 通栏行之间补 hairline，否则相邻版本会连成一块白板
          if (i != _releases.length - 1)
            Padding(
              padding: const EdgeInsets.only(left: Space.pageGutter),
              child: Divider(height: 0.5, thickness: 0.5, color: c.separator),
            ),
        ],
      ],
    );
  }

  Widget _reviewSection(StoreApp app) {
    final c = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: '评分与评论',
        subtitle: app.ratingCount == 0 ? '还没有评分' : '${app.ratingAverage.toStringAsFixed(1)} 分 · ${app.ratingCount} 条评分'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
        child: Row(children: [
          if (app.ratingCount > 0) ...[
            Text(app.ratingAverage.toStringAsFixed(1),
              style: AppText.largeTitle(c).copyWith(color: c.accent)),
            const SizedBox(width: 8),
            Icon(Icons.star_rounded, color: c.orange, size: 24),
          ],
          const Spacer(),
          TextButton.icon(onPressed: _writeReview,
            icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('写评价')),
        ])),
      FutureBuilder<List<AppReview>>(
        future: _reviews,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppTextButton(
                  label: '评论加载失败，点此重试',
                  onPressed: () => setState(
                      () => _reviews = widget.deps.api.listReviews(widget.appId)),
                ),
              ),
            );
          }
          final reviews = snap.data ?? const <AppReview>[];
          if (reviews.isEmpty) {
            return Padding(padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
              child: Text('成为第一个评价这款应用的人', style: AppText.subhead(c)));
          }
          return Padding(padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
            child: Column(children: [for (final review in reviews)
              Container(width: double.infinity, margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: c.card,
                  borderRadius: BorderRadius.circular(Radii.card)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    NetworkAvatar(
                      radius: 16,
                      imageUrl: review.avatarUrl,
                      fallbackText: review.displayName),
                    const SizedBox(width: 8),
                    Expanded(child: Text(review.displayName, style: AppText.headline(c))),
                    Text('${review.stars} ★', style: AppText.subhead(c).copyWith(color: c.orange)),
                  ]),
                  if (review.body.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(review.body, style: AppText.footnote(c)),
                  ],
                ]),
              ),
            ]));
        },
      ),
    ]);
  }

  void _writeReview() {
    if ((widget.deps.api.authTokenProvider?.call() ?? '').isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「我的」登录华为开发者账号')));
      return;
    }
    final controller = TextEditingController();
    var stars = 5;
    var busy = false;
    String? error;
    final c = context.colors;
    showModalBottomSheet<void>(
      context: context, isScrollControlled: true,
      backgroundColor: c.backgroundGrouped,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
      builder: (sheet) => StatefulBuilder(builder: (sheet, update) => SafeArea(
        child: Padding(padding: EdgeInsets.fromLTRB(Space.pageGutter, Space.xl, Space.pageGutter,
          MediaQuery.of(sheet).viewInsets.bottom + 24),
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('评价应用', style: AppText.title2(c)),
              const SizedBox(height: 12),
              Row(children: [for (var i = 1; i <= 5; i++)
                IconButton(onPressed: busy ? null : () => update(() => stars = i),
                  icon: Icon(i <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: c.orange, size: 32))]),
              TextField(controller: controller, minLines: 2, maxLines: 4, maxLength: 2000,
                decoration: InputDecoration(
                  hintText: '说说你的使用体验（可选）',
                  filled: true,
                  fillColor: c.card,
                  contentPadding: const EdgeInsets.all(15),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.card),
                    borderSide: BorderSide.none,
                  ),
                )),
              const SizedBox(height: 12),
              if (error != null) Text(error!, style: AppText.caption(c).copyWith(color: c.redText)),
              AppButton(
                label: busy ? '提交中…' : '提交评分与评论',
                size: Sizes.buttonLg,
                expand: true,
                busy: busy,
                onPressed: () async {
                  update(() { busy = true; error = null; });
                  try {
                    await widget.deps.api.putReview(widget.appId, stars, controller.text.trim());
                    final nextApp = await widget.deps.api.appDetail(widget.appId);
                    if (!mounted) return;
                    setState(() {
                      _app = nextApp;
                      _reviews = widget.deps.api.listReviews(widget.appId);
                    });
                    if (sheet.mounted) Navigator.of(sheet).pop();
                  } catch (e) {
                    if (sheet.mounted) update(() => error = e is ApiException ? e.message : '$e');
                  } finally {
                    if (sheet.mounted) update(() => busy = false);
                  }
                },
              ),
            ],
          ))),
      )),
    ).whenComplete(controller.dispose);
  }

  /// 必须让用户理解「为什么要重签」——否则会把等待当成卡死。
  Widget _signingNote() {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.lg, Space.pageGutter, 0),
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: c.fillSecondary,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 15, color: c.textSecondary),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                'HarmonyOS 的安装包必须包含本机设备标识才能安装。'
                '因此「安装」会在下载后，用你自己的证书与设备授权在本机重新签名，'
                '再安装到这台设备。全程不上传任何文件。',
                style: AppText.caption(c),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Release 文本中的常见标题和列表标记做轻量排版。
class _ReleaseNotes extends StatefulWidget {
  const _ReleaseNotes({required this.body});

  final String body;

  @override
  State<_ReleaseNotes> createState() => _ReleaseNotesState();
}

class _ReleaseNotesState extends State<_ReleaseNotes> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_ReleaseNotes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.body.trim().isEmpty) {
      return Text('开发者未提供更新说明', style: AppText.subhead(c));
    }
    final lines = widget.body.split('\n').where((line) => line.trim().isNotEmpty).toList();
    final visible = _expanded ? lines : lines.take(5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final raw in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text(
                _displayLine(raw.trim()),
                style: raw.trimLeft().startsWith('#')
                    ? AppText.subhead(c).copyWith(fontWeight: FontWeight.w600)
                    : AppText.footnote(c),
              ),
            ),
        if (lines.length > 5)
          AppTextButton(
            label: _expanded ? '收起更新说明' : '展开全部更新说明',
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
      ],
    );
  }

  String _displayLine(String line) {
    final heading = RegExp(r'^#{1,6}\s+');
    if (heading.hasMatch(line)) line = line.replaceFirst(heading, '');
    final bullet = RegExp(r'^[-*]\s+');
    if (bullet.hasMatch(line)) line = '•  ${line.replaceFirst(bullet, '')}';
    return line
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (match) => match[1] ?? '')
        .replaceAll('**', '')
        .replaceAll('`', '');
  }
}
