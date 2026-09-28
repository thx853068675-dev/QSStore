// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 「管理」页 —— 可更新列表、已获取列表与本人上架的应用。
//
// 版本比对用 versionCode 而不是 versionName：
// 设备安装时判定升降级用的就是 versionCode（实测确认，见 docs/SERVER-API.md §3）。
// 轻启的 versionCode 必须从 pack.info 读，采集器已处理。
//
// 「更新」按钮直接在行内触发安装（与列表页共享全局安装中心的进度），
// 不再绕详情页一圈。

import 'package:flutter/material.dart';
import 'package:ohos_adapter/ohos_adapter.dart';

import '../../model/store_models.dart';
import '../../net/api_client.dart';
import '../../state/install_center.dart';
import '../../state/install_coordinator.dart';
import '../../state/installed_store.dart';
import '../../theme/tokens.dart';
import '../components/basic.dart';
import '../detail/app_detail_page.dart';

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({
    super.key,
    required this.deps,
    this.installCenter,
    this.onExplore,
    this.isSignedIn = false,
    this.refreshRevision = 0,
  });

  final DetailDeps deps;

  /// 全局安装中心：有值时「更新」按钮可直接在行内安装并显示进度。
  final InstallCenter? installCenter;
  final VoidCallback? onExplore;
  final bool isSignedIn;
  final int refreshRevision;

  ApiClient get api => deps.api;
  InstalledStore get installed => deps.installed;

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  late Future<List<_UpdateItem>> _future;
  late Future<List<StoreApp>> _myAppsFuture;

  /// 上次见到的「安装成功」计数（用于感知行内更新完成后重查版本差）。
  int _lastDoneCounter = 0;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _myAppsFuture = _loadMyApps();
    _lastDoneCounter = widget.installCenter?.doneCounter ?? 0;
    widget.installCenter?.addListener(_onCenterChanged);
  }

  @override
  void didUpdateWidget(covariant UpdatesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSignedIn != widget.isSignedIn ||
        oldWidget.refreshRevision != widget.refreshRevision) {
      _future = _load();
      _myAppsFuture = _loadMyApps();
    }
  }

  Future<List<StoreApp>> _loadMyApps() =>
      widget.isSignedIn ? widget.api.myPublishedApps() : Future.value(const []);

  @override
  void dispose() {
    widget.installCenter?.removeListener(_onCenterChanged);
    super.dispose();
  }

  /// 行内安装完成后重查版本差（新 versionCode 已登记，该行应消失）。
  void _onCenterChanged() {
    final center = widget.installCenter;
    if (center == null || !mounted) return;
    if (center.doneCounter != _lastDoneCounter) {
      _lastDoneCounter = center.doneCounter;
      _refresh();
    }
  }

  Future<List<_UpdateItem>> _load() async {
    final records = widget.installed.records;
    if (records.isEmpty) return const [];

    final items = <_UpdateItem>[];
    for (final rec in records) {
      try {
        final releases = await widget.api.listReleases(rec.appId, pageSize: 10);
        // 找最新一个「含 HAP 且 versionCode 更大」的版本
        AppRelease? best;
        HapAsset? bestAsset;
        for (final r in releases.items) {
          if (!r.hasHap) continue;
          for (final a in r.installableAssets) {
            // 只比较同 bundle 的附件
            if (a.bundleName.isNotEmpty &&
                rec.bundleName.isNotEmpty &&
                a.bundleName != rec.bundleName) {
              continue;
            }
            if (a.versionCode > rec.installedVersionCode) {
              if (bestAsset == null || a.versionCode > bestAsset.versionCode) {
                best = r;
                bestAsset = a;
              }
            }
          }
        }
        if (best != null && bestAsset != null) {
          items.add(_UpdateItem(
            record: rec,
            release: best,
            asset: bestAsset,
          ));
        }
      } catch (_) {
        // 单个应用查询失败不影响整页
      }
    }
    items.sort((a, b) => b.asset.versionCode.compareTo(a.asset.versionCode));
    return items;
  }

  Future<void> _refresh() async {
    final f = _load();
    final myApps = _loadMyApps();
    if (mounted) setState(() { _future = f; _myAppsFuture = myApps; });
    await Future.wait([
      f.then((_) {}, onError: (Object _) {}),
      myApps.then((_) {}, onError: (Object _) {}),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.backgroundGrouped,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PageIntro(
              title: '管理',
              subtitle: '更新应用与管理自己上架的应用',
              trailing: IconButton(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新管理页',
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    return FutureBuilder<List<_UpdateItem>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.cloud_off,
            title: '检查更新失败',
            message: '${snap.error}',
            actionLabel: '重试',
            onAction: _refresh,
          );
        }

        final records = widget.installed.records;
        final items = snap.data ?? const <_UpdateItem>[];
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            children: [
              // ── 可更新 ──────────────────────────────────────────
              SectionHeader(
                title: '可更新',
                subtitle:
                    items.isEmpty ? '已安装的应用都是最新版' : '${items.length} 个应用有新版本',
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
                  child: GroupedCard(
                    children: [
                      GroupedRow(
                        title: '全部已是最新',
                        subtitle: '已安装的应用都没有可用更新',
                        leadingIcon: Icons.check_circle_outline,
                        showDivider: false,
                        onTap: null,
                      ),
                    ],
                  ),
                )
              else
                GroupedCard(
                  children: [
                    for (final item in items) _updateRow(item),
                  ],
                ),

              // ── 已获取 ────────────────────────────────────────────
              SectionHeader(
                title: '已获取',
                subtitle: '${records.length} 个应用 · 长按可移除记录',
              ),
              for (var i = 0; i < records.length; i++)
                AppRowCard(
                  app: records[i].asStoreApp(),
                  iconUrl: widget.api.resolve(records[i].iconUrl),
                  subtitle: '${records[i].bundleName}'
                      '${records[i].installedVersionName.isNotEmpty ? "  ·  ${records[i].installedVersionName}" : ""}',
                  showDivider: i != records.length - 1,
                  trailing: AppTextButton(
                    label: '打开',
                    onPressed: () => _open(records[i]),
                  ),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute(
                      builder: (_) => AppDetailPage(
                        deps: widget.deps,
                        appId: records[i].appId,
                        installCenter: widget.installCenter,
                      ),
                    ),
                  ),
                  onLongPress: () => _confirmForget(records[i]),
                ),
              if (records.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
                  child: GroupedCard(children: [GroupedRow(
                    title: '还没有获取应用',
                    subtitle: '从发现页安装应用后，这里会显示更新',
                    leadingIcon: Icons.download_done_outlined,
                    showDivider: false,
                    onTap: widget.onExplore,
                  )]),
                ),
              SectionHeader(title: '我上架的应用', subtitle: '用当前华为开发者账号管理'),
              _publishedSection(),
              const SizedBox(height: Space.xxl),
            ],
          ),
        );
      },
    );
  }

  Widget _publishedSection() {
    if (!widget.isSignedIn) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
        child: GroupedCard(children: [GroupedRow(
          title: '登录后查看', subtitle: '使用上架时的华为开发者账号登录',
          leadingIcon: Icons.person_outline, showDivider: false, onTap: null,
        )]),
      );
    }
    return FutureBuilder<List<StoreApp>>(
      future: _myAppsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(padding: EdgeInsets.all(Space.lg),
              child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
            child: GroupedCard(children: [GroupedRow(
              title: '上架记录加载失败', subtitle: '${snap.error}',
              leadingIcon: Icons.cloud_off_outlined, showDivider: false,
              onTap: _refresh,
            )]),
          );
        }
        final apps = snap.data ?? const <StoreApp>[];
        if (apps.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
            child: GroupedCard(children: [GroupedRow(
              title: '还没有上架应用', subtitle: '可从发现页右上角添加',
              leadingIcon: Icons.add_circle_outline, showDivider: false,
              onTap: widget.onExplore,
            )]),
          );
        }
        return Column(children: [
          for (var i = 0; i < apps.length; i++)
            AppRowCard(
              app: apps[i], iconUrl: widget.api.resolve(apps[i].iconUrl),
              subtitle: '${apps[i].category} · ${apps[i].repo}',
              showDivider: i != apps.length - 1,
              onTap: () => Navigator.of(context).push(AppPageRoute(
                builder: (_) => AppDetailPage(deps: widget.deps,
                  appId: apps[i].id, installCenter: widget.installCenter),
              )),
              trailing: AppTextButton(label: '删除', tone: AppButtonTone.destructive,
                onPressed: () => _confirmRemovePublished(apps[i])),
            ),
        ]);
      },
    );
  }

  Future<void> _confirmRemovePublished(StoreApp app) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: context.colors.backgroundGrouped,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.pageGutter, Space.xl, Space.pageGutter, Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('删除「${app.displayName}」？', style: AppText.headline(sheet.colors)),
              const SizedBox(height: Space.sm),
              Text('应用会从商店下架，现有安装和历史数据会保留。以后可重新上架。',
                style: AppText.footnote(sheet.colors)),
              const SizedBox(height: Space.lg),
              AppButton(label: '删除上架记录', tone: AppButtonTone.destructive,
                expand: true, onPressed: () => Navigator.pop(sheet, true)),
              const SizedBox(height: Space.sm),
              AppButton(label: '取消', tone: AppButtonTone.secondary,
                expand: true, onPressed: () => Navigator.pop(sheet, false)),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.removeMyPublishedApp(app.id);
      if (!mounted) return;
      await _refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已从商店删除')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')));
    }
  }


  Future<void> _open(InstalledRecord r) async {
    bool ok = false;
    try {
      ok = await OhosAdapter().openInstalledApp(r.bundleName,
          abilityName: r.mainAbility, moduleName: r.moduleName);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开应用，请确认应用仍在设备上')));
    }
  }

  /// 长按移除记录（只删本地记录，不卸载应用）。
  Future<void> _confirmForget(InstalledRecord r) async {
    final c = context.colors;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: c.backgroundGrouped,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Space.pageGutter, Space.xl, Space.pageGutter, Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('移除「${r.displayName}」的记录？', style: AppText.headline(sheet.colors)),
              const SizedBox(height: Space.sm),
              Text('只会从本页移除这条安装记录，不会卸载设备上的应用。',
                  style: AppText.footnote(sheet.colors)),
              const SizedBox(height: Space.lg),
              AppButton(
                label: '移除记录',
                tone: AppButtonTone.destructive,
                expand: true,
                onPressed: () => Navigator.of(sheet).pop(true),
              ),
              const SizedBox(height: Space.sm),
              AppButton(
                label: '取消',
                tone: AppButtonTone.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheet).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    await widget.installed.forget(r);
    if (mounted) await _refresh();
  }

  /// 可更新行：版本对比信息 + 行内「更新」按钮（实时进度）。
  Widget _updateRow(_UpdateItem item) {
    final rec = item.record;
    return AppRowCard(
      app: rec.asStoreApp(),
      iconUrl: widget.api.resolve(rec.iconUrl),
      // 只放版本跃迁。带上体积会让这行超宽，被 maxLines 截成 "18...."，
      // 把版本号本身吃掉——那才是用户唯一需要的信息。
      subtitle:
          '${rec.installedVersionName.isEmpty ? "" : "${rec.installedVersionName} → "}'
          '${item.asset.versionName.isNotEmpty ? item.asset.versionName : item.release.tag}',
      onTap: () => Navigator.of(context).push(
        AppPageRoute(
          builder: (_) => AppDetailPage(
            deps: widget.deps,
            appId: rec.appId,
            installCenter: widget.installCenter,
          ),
        ),
      ),
      trailing: _UpdateButton(
        center: widget.installCenter,
        deps: widget.deps,
        item: item,
      ),
    );
  }
}

/// 行内更新按钮：状态与进度来自全局安装中心。
class _UpdateButton extends StatelessWidget {
  const _UpdateButton({
    required this.center,
    required this.deps,
    required this.item,
  });

  final InstallCenter? center;
  final DetailDeps deps;
  final _UpdateItem item;

  @override
  Widget build(BuildContext context) {
    final c = center;
    if (c == null) {
      // 没有安装中心（未完成准备）时退化为跳详情页查看
      return GetButton(
        state: GetButtonState.idle,
        label: '更新',
        compact: true,
        onPressed: () => Navigator.of(context).push(
          AppPageRoute(
            builder: (_) => AppDetailPage(
              deps: deps,
              appId: item.record.appId,
            ),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final s = c.stateOf(item.record.appId);
        GetButtonState state;
        String label = '更新';

        if (s.busy) {
          state = s.stage == InstallStage.downloading ||
                  s.stage == InstallStage.probing ||
                  s.stage == InstallStage.verifying
              ? GetButtonState.downloading
              : GetButtonState.installing;
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
          compact: true,
          onPressed: s.busy
              ? null
              : () => c.installApp(
                    item.record.asStoreApp(),
                    asset: item.asset,
                  ),
        );
      },
    );
  }
}

class _UpdateItem {
  _UpdateItem({
    required this.record,
    required this.release,
    required this.asset,
  });

  final InstalledRecord record;
  final AppRelease release;
  final HapAsset asset;
}
