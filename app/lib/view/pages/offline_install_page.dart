// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 「离线安装」页 —— 安装手机本地的 HAP 文件。
//
// 与在线商店共用同一条签名安装链路（预检 → 重签 → 安装），只是省去下载：
//   · 通过系统文件选择器选一个 .hap
//   · 从包内 module.json 读出 bundleName / 权限（离线包没有服务端元数据）
//   · 用用户自己的证书在本机重签后安装
//
// 原始文件不动（只读），签名产物在沙箱临时目录中生成、用后即删。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ohos_adapter/ohos_adapter.dart';
import 'package:signing_core/signing_core.dart';

import '../../state/install_coordinator.dart';
import '../../theme/tokens.dart';
import '../components/basic.dart';
import '../detail/app_detail_page.dart';

class OfflineInstallPage extends StatefulWidget {
  const OfflineInstallPage({super.key, required this.deps});

  final DetailDeps deps;

  @override
  State<OfflineInstallPage> createState() => _OfflineInstallPageState();
}

class _OfflineInstallPageState extends State<OfflineInstallPage> {
  String? _pickedPath;
  int _pickedSize = 0;

  InstallProgress _progress = InstallProgress(stage: InstallStage.idle);
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.backgroundGrouped,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: Space.xxl),
          children: [
            const PageIntro(
              title: '本地安装',
              subtitle: '选择手机中的 HAP，在本机完成签名与安装',
            ),

            // ── 选择文件 ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.pageGutter),
              child: _PickCard(
                pickedPath: _pickedPath,
                pickedSize: _pickedSize,
                busy: _busy,
                onPick: _pickFile,
                onInstall: _install,
              ),
            ),

            // ── 进度 / 结果 ────────────────────────────────────────
            if (_busy || _progress.stage != InstallStage.idle)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(Space.pageGutter, Space.md, Space.pageGutter, 0),
                child: _ProgressCard(
                  progress: _progress,
                  onDismiss: _reset,
                ),
              ),

            // ── 说明 ───────────────────────────────────────────────
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(Space.pageGutter, Space.lg, Space.pageGutter, 0),
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
                        '离线安装同样会用你自己的证书与设备授权在本机重新签名，'
                        '再安装到这台设备。原文件不会被修改，全程不上传任何文件。',
                        style: AppText.caption(c),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 回到初始状态（结果卡片上的「再来一个」）。
  void _reset() {
    setState(() {
      _progress = InstallProgress(stage: InstallStage.idle);
      _pickedPath = null;
      _pickedSize = 0;
    });
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    try {
      final path = await ohosAdapter.selectFile(['hap']);
      if (path == null || path.isEmpty) return;
      final size = await File(path).length();
      setState(() {
        _pickedPath = path;
        _pickedSize = size;
        // 换了文件就清掉上一次的结果
        _progress = InstallProgress(stage: InstallStage.idle);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择文件失败：$e')));
      }
    }
  }

  Future<void> _install() async {
    final path = _pickedPath;
    if (path == null || _busy) return;

    setState(() {
      _busy = true;
      _progress =
          InstallProgress(stage: InstallStage.probing, stageDetail: '解析安装包…');
    });

    final coordinator = widget.deps.makeCoordinator((p) {
      if (mounted) setState(() => _progress = p);
    });

    await coordinator.runLocal(
      hap: File(path),
      signConfig: widget.deps.signConfig(),
    );

    if (mounted) setState(() => _busy = false);
  }
}

/// 选择文件 + 安装按钮卡片。
class _PickCard extends StatelessWidget {
  const _PickCard({
    required this.pickedPath,
    required this.pickedSize,
    required this.busy,
    required this.onPick,
    required this.onInstall,
  });

  final String? pickedPath;
  final int pickedSize;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onInstall;

  String get _sizeText {
    if (pickedSize <= 0) return '未知';
    if (pickedSize < 1024 * 1024) {
      return '${(pickedSize / 1024).toStringAsFixed(0)} KB';
    }
    return '${(pickedSize / 1048576).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final picked = pickedPath != null;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!picked) ...[
            Text('选择安装包', style: AppText.headline(c)),
            const SizedBox(height: 2),
            Text('从手机存储中选取一个 .hap 文件', style: AppText.caption(c)),
            const SizedBox(height: Space.lg),
            _bigButton(
              context,
              label: '选择 HAP 文件',
              icon: Icons.folder_open,
              onPressed: busy ? null : onPick,
            ),
          ] else ...[
            Row(
              children: [
                _fileIcon(context),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.headline(c),
                      ),
                      const SizedBox(height: 2),
                      Text(_sizeText, style: AppText.caption(c)),
                    ],
                  ),
                ),
                AppTextButton(
                  label: '重选',
                  onPressed: busy ? null : onPick,
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            _bigButton(
              context,
              label: '安装',
              icon: Icons.download_done,
              busyOverride: busy,
              onPressed: onInstall,
            ),
          ],
        ],
      ),
    );
  }

  String get _fileName {
    final parts = pickedPath!.split('/');
    return parts.isEmpty ? pickedPath! : parts.last;
  }

  Widget _fileIcon(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: c.fillSecondary,
        borderRadius: BorderRadius.circular(Radii.field),
      ),
      child: Icon(Icons.archive_outlined, size: 26, color: c.textSecondary),
    );
  }

  Widget _bigButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool busyOverride = false,
  }) {
    return AppButton(
      label: label,
      icon: icon,
      expand: true,
      busy: busyOverride,
      onPressed: onPressed,
    );
  }
}

/// 进度 / 结果卡片。
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.progress,
    required this.onDismiss,
  });

  final InstallProgress progress;
  final VoidCallback onDismiss;

  String get _stageText {
    switch (progress.stage) {
      case InstallStage.idle:
        return '';
      case InstallStage.probing:
        return '解析安装包…';
      case InstallStage.downloading:
        return '下载中';
      case InstallStage.verifying:
        return '校验文件完整性…';
      case InstallStage.preflight:
        return '检查签名材料…';
      case InstallStage.provisioning:
        return '更新设备授权…';
      case InstallStage.signing:
        return '重签中';
      case InstallStage.installing:
        return '安装中';
      case InstallStage.done:
        return '安装成功';
      case InstallStage.failed:
        return '安装失败';
    }
    // 覆盖全部枚举值后不可达，保留以获得新增枚举时的编译提示
    // ignore: dead_code
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stage = progress.stage;
    final done = stage == InstallStage.done;
    final failed = stage == InstallStage.failed;
    final busy = !done && !failed && stage != InstallStage.idle;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(
          color: done
              ? c.green.withOpacity(0.4)
              : (failed ? c.red.withOpacity(0.4) : Colors.transparent),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  done ? Icons.check_circle : Icons.error_outline,
                  size: 20,
                  color: done ? c.green : c.red,
                ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  failed ? (progress.error ?? '安装失败') : _stageText,
                  style: AppText.subhead(c).copyWith(
                    color: failed ? c.redText : c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (busy && progress.stageDetail.isNotEmpty) ...[
            const SizedBox(height: Space.xs),
            Text(progress.stageDetail, style: AppText.caption(c)),
          ],
          if (failed && progress.issues.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            for (final issue in progress.issues)
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
                      color:
                          issue.severity == Severity.error ? c.red : c.orange,
                    ),
                    const SizedBox(width: Space.xs),
                    Expanded(
                      child: Text(issue.message, style: AppText.caption(c)),
                    ),
                  ],
                ),
              ),
          ],
          if (done || failed) ...[
            const SizedBox(height: Space.md),
            AppButton(
              label: done ? '再装一个' : '重选文件',
              tone: AppButtonTone.secondary,
              expand: true,
              onPressed: onDismiss,
            ),
          ],
        ],
      ),
    );
  }
}
