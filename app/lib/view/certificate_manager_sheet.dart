// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
// 用户自行核对 AGC 证书。删除会影响仍使用该证书的应用，绝不自动清理。

import 'package:flutter/material.dart';

import '../state/agc/agc_models.dart';
import '../state/sign_material_store.dart';
import '../theme/tokens.dart';
import 'components/basic.dart';

Future<void> showCertificateManager(
    BuildContext context, SignMaterialStore materials) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.backgroundGrouped,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => _CertificateManagerSheet(materials: materials),
  );
}

class _CertificateManagerSheet extends StatefulWidget {
  const _CertificateManagerSheet({required this.materials});

  final SignMaterialStore materials;

  @override
  State<_CertificateManagerSheet> createState() =>
      _CertificateManagerSheetState();
}

class _CertificateManagerSheetState extends State<_CertificateManagerSheet> {
  List<CertInfo>? _certs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final certs = await widget.materials.ensureAgc().getCertList();
      if (mounted) setState(() => _certs = certs);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(CertInfo cert) async {
    if (cert.id == widget.materials.certId) return;
    final c = context.colors;
    // 与全站其余确认面板一致，用半屏面板而不是 Material AlertDialog。
    final confirmed = await showModalBottomSheet<bool>(
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
              Text('删除这张调试证书？', style: AppText.headline(sheet.colors)),
              const SizedBox(height: Space.sm),
              Text(
                '「${cert.certName}」可能仍用于其他应用或 DevEco 项目。'
                '删除后，用它签名的应用可能无法继续更新。请先确认对应私钥及项目已不再使用。',
                style: AppText.footnote(sheet.colors),
              ),
              const SizedBox(height: Space.lg),
              AppButton(
                label: '确认删除',
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
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.materials.ensureAgc().deleteCertList([cert.id]);
      final certs = await widget.materials.ensureAgc().getCertList();
      if (mounted) setState(() => _certs = certs);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final debug = _certs?.where((cert) => cert.isDebug).toList() ?? const <CertInfo>[];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.pageGutter, Space.xl, Space.pageGutter, Space.pageGutter),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.62,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AGC 调试证书', style: AppText.title2(c)),
              const SizedBox(height: 8),
              Text('当前账号：${widget.materials.accountLabel} · '
                  '${_certs == null ? '读取中' : '${debug.length}/3 张'}',
                  style: AppText.footnote(c)),
              const SizedBox(height: 8),
              Text('轻启·安装器会复用与本机私钥配对的证书。若三张都不配对，'
                  '请核对哪张已不再使用，再手动删除并重新点击登录。',
                  style: AppText.footnote(c)),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: AppText.footnote(c).copyWith(color: c.redText)),
              ],
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: ListView(children: [
                  if (_certs != null && debug.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.md),
                      child: Text('账号下没有调试证书', style: AppText.footnote(c)),
                    )
                  else
                    GroupedCard(
                      margin: EdgeInsets.zero,
                      children: [
                        for (var i = 0; i < debug.length; i++)
                          GroupedRow(
                            title: debug[i].certName,
                            subtitle: 'ID ${debug[i].id} · '
                                '${debug[i].expireEpochSeconds > 0 ? '到期 ${DateTime.fromMillisecondsSinceEpoch(debug[i].expireEpochSeconds * 1000).toLocal().toString().substring(0, 10)}' : '到期时间未知'}'
                                '${debug[i].id == widget.materials.certId ? ' · 本机正在使用' : ''}',
                            leadingIcon: debug[i].id == widget.materials.certId
                                ? Icons.check_circle_outline
                                : Icons.badge_outlined,
                            showDivider: i != debug.length - 1,
                            trailing: debug[i].id == widget.materials.certId
                                ? Icon(Icons.check_circle, color: c.green)
                                : null,
                            onTap: debug[i].id == widget.materials.certId || _busy
                                ? null
                                : () => _delete(debug[i]),
                          ),
                      ],
                    ),
                ]),
              ),
              AppButton(
                label: '刷新列表',
                tone: AppButtonTone.secondary,
                expand: true,
                onPressed: _busy ? null : _refresh,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
