// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 「我的」页 —— 华为账号、签名材料状态、关于。
//
// 已获取的应用列表已移至「更新」Tab（与更新检查天然同源）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ohos_adapter/ohos_adapter.dart';

import '../../net/api_client.dart';
import '../../state/installed_store.dart';
import '../../state/signing_setup.dart';
import '../../theme/tokens.dart';
import '../components/basic.dart';

class MinePage extends StatefulWidget {
  const MinePage({
    super.key,
    required this.api,
    required this.setup,
    this.onChanged,
    this.materialStatus,
    this.onManageMaterial,
    this.accountLabel = '未登录',
    this.accountAvatarUrl = '',
    required this.installed,
    this.isSignedIn = false,
    this.onLogin,
    this.onLogout,
    this.onFetchAvatar,
  });

  final ApiClient api;
  final SigningSetupController setup;

  /// 数据变化时通知外层刷新
  final VoidCallback? onChanged;

  /// 签名材料状态文本（由平台层提供）
  final String? materialStatus;
  final VoidCallback? onManageMaterial;

  /// 华为账号状态（用于设备授权自动重建）
  final String accountLabel;
  final String accountAvatarUrl;
  final InstalledStore installed;
  final bool isSignedIn;
  final Future<void> Function()? onLogin;
  final Future<void> Function()? onLogout;
  final Future<String?> Function()? onFetchAvatar;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.backgroundGrouped,
      body: SafeArea(
        bottom: false,
        child: ListView(
          children: [
            const PageIntro(
              title: '我的',
              subtitle: '账号、签名与应用来源',
            ),

            // ── 华为账号（置顶：登录是设备授权自动重建的前提）──
            const SectionHeader(
              title: '华为账号',
              subtitle: '用于在换设备时自动重建本机设备授权',
            ),
            GroupedCard(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.lg, vertical: Space.sm),
                  leading: NetworkAvatar(
                    radius: 23,
                    imageUrl: widget.isSignedIn ? widget.accountAvatarUrl : '',
                    fallbackText: widget.isSignedIn ? widget.accountLabel : '',
                    onTap: widget.isSignedIn ? _fetchAvatar : null,
                  ),
                  title: Text(widget.isSignedIn ? widget.accountLabel : '未登录', style: AppText.headline(c)),
                  subtitle: Text(widget.isSignedIn
                      ? (widget.accountAvatarUrl.isEmpty ? '轻触头像获取华为帐号头像' : '华为开发者账号')
                      : '登录后可申请本机设备授权',
                    style: AppText.caption(c)),
                  trailing: AppTextButton(
                    label: widget.isSignedIn ? '退出' : '登录',
                    tone: widget.isSignedIn
                        ? AppButtonTone.destructive
                        : AppButtonTone.primary,
                    onPressed:
                        widget.isSignedIn ? widget.onLogout : widget.onLogin,
                  ),
                ),
              ],
            ),

            // ── 签名材料 ──────────────────────────────────────────
            const SectionHeader(
              title: '签名与设备授权',
              subtitle: '安装时用你自己的证书在本机重签',
            ),
            GroupedCard(
              children: [
                GroupedRow(
                  title: '无线调试',
                  subtitle: widget.setup.connectedPort > 0
                      ? '上次连接端口 ${widget.setup.connectedPort} · 轻触检查或更换'
                      : '轻触查看端口或重新连接',
                  leadingIcon: Icons.wifi_tethering_rounded,
                  onTap: _showWirelessReconnect,
                ),
                GroupedRow(
                  title: '签名材料',
                  subtitle: widget.materialStatus ?? '未检测',
                  leadingIcon: Icons.verified_user_outlined,
                  onTap: widget.onManageMaterial,
                ),
                GroupedRow(
                  title: '已安装的应用',
                  subtitle: '共 ${widget.installed.records.length} 个包 · 安装时按应用签发设备授权',
                  leadingIcon: Icons.apps_rounded,
                  onTap: _showInstalled,
                ),
              ],
            ),

            // ── 关于 ──────────────────────────────────────────────
            const SectionHeader(title: '关于'),
            GroupedCard(
              children: [
                GroupedRow(
                  title: '服务地址',
                  value: ApiClient.defaultBaseUrl
                      .replaceFirst('http://', '')
                      .replaceFirst('https://', ''),
                  showDivider: true,
                  onTap: null,
                ),
                const GroupedRow(
                  title: '应用来源',
                  value: 'GitHub Releases',
                  onTap: null,
                ),
                const GroupedRow(
                  title: '版本',
                  value: '0.1.0',
                  showDivider: false,
                  onTap: null,
                ),
              ],
            ),
            const SizedBox(height: Space.xxl),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchAvatar() async {
    final error = await widget.onFetchAvatar?.call();
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _showWirelessReconnect() {
    final portController = TextEditingController(
      text: widget.setup.connectedPort > 0 ? '${widget.setup.connectedPort}' : '',
    );
    var connecting = false;
    String? error;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.backgroundGrouped,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (sheet) => StatefulBuilder(builder: (sheet, update) {
        final c = sheet.colors;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheet).viewInsets.bottom),
          child: SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.xl, Space.pageGutter, Space.xxl),
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('重新连接无线调试', style: AppText.title2(c)),
                const SizedBox(height: 8),
                Text('若系统更换了调试端口，请在无线调试设置中查看新端口。',
                    style: AppText.footnote(c)),
                const SizedBox(height: 16),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '调试端口',
                      prefixText: '127.0.0.1:'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: AppText.footnote(c).copyWith(color: c.redText)),
                ],
                const SizedBox(height: 16),
                AppButton(
                  label: '连接',
                  expand: true,
                  busy: connecting,
                  onPressed: () async {
                    final port = int.tryParse(portController.text.trim());
                    if (port == null || port < 1 || port > 65535) {
                      update(() => error = '请输入 1–65535 之间的端口号');
                      return;
                    }
                    update(() { connecting = true; error = null; });
                    final failure = await widget.setup.reconnectForInstall(port);
                    if (!sheet.mounted) return;
                    if (failure == null) {
                      Navigator.pop(sheet);
                    } else {
                      update(() { connecting = false; error = failure; });
                    }
                  },
                ),
                AppButton(
                  label: '打开无线调试设置',
                  tone: AppButtonTone.secondary,
                  expand: true,
                  onPressed: () {
                    unawaited(widget.setup.openWirelessSettings());
                  },
                ),
              ],
            ),
          )),
        );
      }),
    ).whenComplete(portController.dispose);
  }

  void _showInstalled() {
    final c = context.colors;
    final records = widget.installed.records;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.backgroundGrouped,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
      builder: (sheet) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.xl, Space.pageGutter, Space.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('已安装的应用', style: AppText.title2(c)),
          const SizedBox(height: 5),
          Text('同一签名身份；安装时为每个包检查并更新授权', style: AppText.caption(c)),
          const SizedBox(height: 16),
          if (records.isEmpty) Text('尚未通过本店安装应用', style: AppText.callout(c)),
          // 不再用「行数 × 固定 64」推算高度：ListTile 的真实高度随字号变化，
          // 文本放大时会把最后一行裁掉。交给 maxHeight + shrinkWrap。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: ListView(shrinkWrap: true, children: [
              for (final record in records)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(record.displayName, style: AppText.headline(c)),
                  subtitle: Text(
                      '${record.bundleName} · ${record.installedVersionName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption(c)),
                  trailing: AppTextButton(
                    label: '打开',
                    onPressed: () async {
                      bool ok = false;
                      try {
                        ok = await OhosAdapter().openInstalledApp(
                            record.bundleName,
                            abilityName: record.mainAbility,
                            moduleName: record.moduleName);
                      } catch (_) {}
                      if (!ok && sheet.mounted) {
                        ScaffoldMessenger.of(sheet).showSnackBar(
                          const SnackBar(content: Text('无法打开应用，请确认应用仍在设备上')));
                      }
                    },
                  ),
                ),
            ]),
          ),
        ]),
      )),
    );
  }
}
