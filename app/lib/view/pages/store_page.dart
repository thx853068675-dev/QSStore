// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
// 发现页：搜索与按 GitHub 星数排序的单一应用流。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/store_models.dart';
import '../../net/api_client.dart';
import '../../state/install_center.dart';
import '../../theme/tokens.dart';
import '../components/basic.dart';
import '../components/submit_sheet.dart';
import '../detail/app_detail_page.dart';

class StorePage extends StatefulWidget {
  const StorePage({super.key, required this.deps, this.installCenter,
    this.isSignedIn = false, this.onLogin});

  final DetailDeps deps;
  final InstallCenter? installCenter;
  final bool isSignedIn;
  final Future<void> Function()? onLogin;
  ApiClient get api => deps.api;

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  Future<Paged<StoreApp>>? _results;
  Future<Paged<StoreApp>>? _feed;
  final List<StoreApp> _more = [];
  bool _loadingMore = false;
  List<String> _recent = const [];
  File? _recentFile;
  static const _hot = ['轻启', '工具', '效率', 'Flutter', '笔记', '播放器'];

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    _loadRecent();
    _feed = widget.api.listApps(sort: 'stars', pageSize: 30);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() { if (mounted) setState(() {}); }

  Future<void> _refresh() async {
    _more.clear();
    final next = widget.api.listApps(sort: 'stars', pageSize: 30);
    setState(() => _feed = next);
    await next;
  }

  Future<void> _loadMore(Paged<StoreApp> first) async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = 2 + (_more.length ~/ 30);
      final next = await widget.api.listApps(sort: 'stars', page: page, pageSize: 30);
      if (mounted) setState(() => _more.addAll(next.items));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败：$e')));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadRecent() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/recent_search.json');
      _recentFile = f;
      if (await f.exists()) {
        final list = (jsonDecode(await f.readAsString()) as List).cast<String>();
        if (mounted) setState(() => _recent = list);
      }
    } catch (_) {}
  }

  Future<void> _remember(String q) async {
    final next = <String>[q, ..._recent.where((e) => e != q)].take(10).toList();
    if (mounted) setState(() => _recent = next);
    try { await _recentFile?.writeAsString(jsonEncode(next)); } catch (_) {}
  }

  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _focus.unfocus();
    _controller.text = query;
    setState(() { _query = query; _results = widget.api.listApps(query: query, pageSize: 100); });
    _remember(query);
  }

  void _clearSearch() {
    _controller.clear();
    setState(() { _query = ''; _results = null; });
  }

  void _showSubmit() {
    final c = context.colors;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.backgroundGrouped,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
      builder: (sheet) => SafeArea(child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheet).viewInsets.bottom),
        child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.xl, Space.pageGutter, Space.xxl),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('上架应用', style: AppText.title2(c)),
            const SizedBox(height: 5),
            Text('填写含 HAP 的 GitHub 仓库地址', style: AppText.subhead(c)),
            const SizedBox(height: 20),
            if (!widget.isSignedIn) ...[
              Text('请先登录华为开发者账号，上架者姓名会显示在应用页面。', style: AppText.callout(c)),
              const SizedBox(height: 12),
              AppTextButton(
                label: '登录账号',
                onPressed: widget.onLogin == null
                    ? null
                    : () async {
                        await widget.onLogin!();
                        if (sheet.mounted) Navigator.of(sheet).pop();
                      },
              ),
            ] else SubmitCard(api: widget.api, onSubmitted: () {
              Navigator.of(sheet).pop();
              _refresh();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('上架成功，应用已加入发现页')));
            }),
          ]),
        )),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final searching = _query.isNotEmpty;
    final suggesting = !searching && _focus.hasFocus && _controller.text.isEmpty;
    return Scaffold(
      backgroundColor: c.backgroundGrouped,
      body: SafeArea(bottom: false, child: Column(children: [
        PageIntro(title: '发现', subtitle: '从 GitHub 发现 HarmonyOS 应用',
          trailing: IconButton(onPressed: _showSubmit, tooltip: '上架应用',
            icon: Icon(Icons.add_circle_outline_rounded, color: c.accent, size: 30))),
        Padding(padding: const EdgeInsets.fromLTRB(Space.pageGutter, 0, Space.pageGutter, Space.md), child: _searchField()),
        Expanded(child: searching ? _resultList() : suggesting ? _suggestions() : _feedList()),
      ])),
    );
  }

  Widget _searchField() {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.field),
        border: Border.all(color: c.separator),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Row(children: [
        Icon(Icons.search_rounded, size: 21, color: c.textSecondary),
        const SizedBox(width: Space.sm),
        Expanded(child: TextField(
          controller: _controller, focusNode: _focus,
          textInputAction: TextInputAction.search, onSubmitted: _search,
          onChanged: (_) { if (mounted) setState(() {}); },
          style: AppText.body(c).copyWith(fontSize: FontSizes.callout),
          decoration: InputDecoration(isDense: true, border: InputBorder.none,
            hintText: '应用名、仓库或关键词', hintStyle: AppText.subhead(c).copyWith(fontSize: FontSizes.callout)),
        )),
        if (_controller.text.isNotEmpty)
          SizedBox(
            width: Space.touch,
            height: Space.touch,
            child: GestureDetector(
              onTap: _clearSearch,
              behavior: HitTestBehavior.opaque,
              child: Icon(Icons.cancel, size: 18, color: c.textSecondary),
            ),
          ),
      ]),
    );
  }

  Widget _feedList() => FutureBuilder<Paged<StoreApp>>(
    future: _feed,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) return EmptyState(icon: Icons.cloud_off, title: '无法连接商店',
        message: '${snap.error}', actionLabel: '重试', onAction: _refresh);
      final first = snap.data!;
      final items = [...first.items, ..._more];
      if (items.isEmpty) return EmptyState(icon: Icons.storefront_outlined, title: '商店还没有应用',
        message: '点击右上角加号，添加 GitHub 仓库', actionLabel: '刷新', onAction: _refresh);
      // 精选位至多一个：优先服务端标记的 featured，否则让星数最高的那张上榜。
      // 之前是「星数 > 100 就渲染大卡」，一屏里可能连续出现好几张大卡，
      // 列表节奏完全被数据打断。
      final int heroIndex = items.indexWhere((a) => a.featured);
      final int? hero = heroIndex >= 0
          ? heroIndex
          : (items.isNotEmpty && items.first.stars >= 100 ? 0 : null);
      return RefreshIndicator(onRefresh: _refresh, child: ListView(children: [
        Padding(padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.sm, Space.pageGutter, Space.sm),
          child: Text('应用', style: AppText.title2(context.colors))),
        for (var i = 0; i < items.length; i++) _appItem(items[i], hero: i == hero),
        if (items.length < first.total) Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter, vertical: Space.lg),
          child: Center(
            child: AppTextButton(
              label: _loadingMore ? '加载中…' : '加载更多',
              onPressed: _loadingMore ? null : () => _loadMore(first),
            ),
          )),
        const SizedBox(height: 32),
      ]));
    },
  );

  Widget _appItem(StoreApp app, {bool hero = false}) {
    if (hero) {
      return _TodayCard(app: app, api: widget.api,
        installCenter: widget.installCenter, onTap: _openDetail(app.id));
    }
    return AppRowCard(app: app, iconUrl: widget.api.resolve(app.iconUrl),
      subtitle: app.publisherName.isEmpty
          ? '${app.stars} ★ · ${app.releasesCount} 个版本'
          : '由 ${app.publisherName} 上架 · ${app.stars} ★',
      trailing: widget.installCenter == null ? null : InstallActionButton(center: widget.installCenter!, app: app),
      onTap: _openDetail(app.id));
  }

  Widget _suggestions() => ListView(children: [
    if (_recent.isNotEmpty) ...[
      const SectionHeader(title: '最近搜索'),
      // 放进 GroupedCard：裸用 GroupedRow 会落在 16pt 上，与 20pt 的
      // 分组标题和卡片左边缘对不齐。
      GroupedCard(children: [
        for (var i = 0; i < _recent.length; i++)
          GroupedRow(
            title: _recent[i],
            leadingIcon: Icons.history,
            showDivider: i != _recent.length - 1,
            onTap: () => _search(_recent[i]),
          ),
      ]),
      const SizedBox(height: Space.lg),
    ],
    const SectionHeader(title: '热门搜索'),
    Padding(padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
      child: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
        for (final q in _hot) GestureDetector(onTap: () => _search(q),
          child: Container(padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            decoration: BoxDecoration(color: context.colors.card, borderRadius: BorderRadius.circular(Radii.field)),
            child: Text(q, style: AppText.subhead(context.colors)))),
      ])),
  ]);

  Widget _resultList() => FutureBuilder<Paged<StoreApp>>(
    future: _results,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) return EmptyState(icon: Icons.cloud_off, title: '搜索失败',
        message: '${snap.error}', actionLabel: '重试', onAction: () => _search(_query));
      final items = snap.data?.items ?? const <StoreApp>[];
      if (items.isEmpty) return EmptyState(icon: Icons.search_off,
        title: '没有找到「$_query」', message: '试试换关键词，或点击右上角加号添加应用');
      return ListView(children: [for (final app in items) _appItem(app)]);
    },
  );

  VoidCallback _openDetail(int appId) => () => Navigator.of(context).push(
    AppPageRoute(builder: (_) => AppDetailPage(deps: widget.deps,
      appId: appId, installCenter: widget.installCenter)));
}

/// 精选卡以应用自身信息为主，图形只做衬底。
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.app,
    required this.api,
    this.onTap,
    this.installCenter,
  });

  final StoreApp app;
  final ApiClient api;
  final VoidCallback? onTap;
  final InstallCenter? installCenter;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.sm, Space.pageGutter, Space.lg),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - value)),
            child: child,
          ),
        ),
        child: Material(
          color: c.card,
          borderRadius: BorderRadius.circular(Radii.sheet),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 168),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: c.isDark
                          ? const [Color(0xFF243C62), Color(0xFF121F38)]
                          : const [Color(0xFF244F96), Color(0xFF142A53)],
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        right: -62,
                        top: -56,
                        child: Container(
                          width: 214,
                          height: 214,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.white.withOpacity(0.12),
                                width: 34),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.category.isEmpty
                                  ? 'HARMONYOS 应用'
                                  : app.category,
                              style: const TextStyle(
                                color: Color(0xFFD7E6FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        app.displayName,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 28,
                                          height: 1.12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 16),
                                AppIconTile(
                                  size: 74,
                                  imageUrl: api.resolve(app.iconUrl),
                                  fallbackText: app.displayName,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(app.publisherName.isEmpty
                                ? '${app.stars} ★ · ${app.releasesCount} 个版本'
                                : '由 ${app.publisherName} 上架 · ${app.stars} ★',
                                style: AppText.caption(c)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (installCenter != null)
                        InstallActionButton(center: installCenter!, app: app)
                      else
                        Icon(Icons.arrow_forward_ios_rounded,
                            size: 18, color: c.accent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
