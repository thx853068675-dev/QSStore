// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
import 'package:flutter/material.dart';

import '../../net/api_client.dart';
import '../../theme/tokens.dart';
import 'basic.dart';

/// 上架卡片：服务预处理 → 用户选择 HAP 与分类 → 确认上架。
class SubmitCard extends StatefulWidget {
  const SubmitCard({required this.api, this.onSubmitted});

  final ApiClient api;
  final VoidCallback? onSubmitted;

  @override
  State<SubmitCard> createState() => SubmitCardState();
}

class SubmitCardState extends State<SubmitCard> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _success;
  Map<String, dynamic>? _draft;
  String? _selectedAsset;
  String? _category;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写 GitHub 仓库地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final data = await widget.api.prepareSubmit(url);
      final choices = (data['choices'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _draft = data;
        _selectedAsset = choices.length == 1
            ? (choices.first as Map)['name'] as String?
            : null;
        _category = data['suggested_category'] as String?;
      });
    } on ApiException catch (e) {
      setState(() =>
          _error = e.hint != null ? '${e.message}\n${e.hint}' : e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final draft = _draft;
    if (draft == null || _selectedAsset == null || _category == null) {
      setState(() => _error = '请选择要上架的 HAP 和分类');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final data = await widget.api.confirmSubmit(
          draft['draft_token'] as String, _selectedAsset!, _category!);
      if (!mounted) return;
      final app = data['app'];
      setState(() {
        _success = '已上架：${app is Map ? app['display_name'] : _controller.text}';
        _draft = null;
        _selectedAsset = null;
        _controller.clear();
      });
      widget.onSubmitted?.call();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.hint != null
          ? '${e.message}\n${e.hint}' : e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            enabled: !_busy && _draft == null,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) { if (_draft == null) _prepare(); },
            style: AppText.body(c).copyWith(fontSize: FontSizes.callout),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://github.com/作者/仓库',
              hintStyle:
                  AppText.subhead(c).copyWith(fontSize: FontSizes.callout),
              filled: true,
              fillColor: c.fillSecondary,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.md, vertical: Space.md),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.field),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 15, color: c.redText),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Text(_error!,
                      style: AppText.caption(c).copyWith(color: c.redText)),
                ),
              ],
            ),
          ],
          if (_success != null) ...[
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 15, color: c.greenText),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Text(_success!,
                      style: AppText.caption(c).copyWith(color: c.greenText)),
                ),
              ],
            ),
          ],
          if (_draft != null) ...[
            const SizedBox(height: Space.md),
            Text('${_draft!['repo']}',
                style: AppText.headline(c)),
            const SizedBox(height: Space.xs),
            Text('选择要上架的 HAP', style: AppText.subhead(c)),
            for (final raw in (_draft!['choices'] as List))
              RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: (raw as Map)['name'] as String,
                groupValue: _selectedAsset,
                onChanged: _busy ? null : (v) => setState(() => _selectedAsset = v),
                title: Text(((raw['display_name'] as String?)?.isNotEmpty ?? false)
                    ? raw['display_name'] as String : raw['name'] as String, maxLines: 1,
                    overflow: TextOverflow.ellipsis, style: AppText.footnote(c)),
                subtitle: Text(
                  '${raw['name']} · ${raw['version_name'] ?? ''}\n${raw['bundle_name'] ?? ''}',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: AppText.caption(c)),
              ),
            const SizedBox(height: Space.sm),
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(labelText: '应用分类'),
              items: [for (final item in (_draft!['categories'] as List))
                DropdownMenuItem(value: item as String, child: Text(item))],
              onChanged: _busy ? null : (v) => setState(() => _category = v),
            ),
            const SizedBox(height: Space.sm),
            AppButton(
              label: '修改仓库地址',
              tone: AppButtonTone.secondary,
              expand: true,
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _draft = null;
                        _selectedAsset = null;
                      }),
            ),
          ],
          const SizedBox(height: Space.md),
          AppButton(
            label: _draft == null ? '检查仓库' : '确认上架',
            expand: true,
            busy: _busy,
            onPressed: _busy ? null : (_draft == null ? _prepare : _confirm),
          ),
          const SizedBox(height: Space.sm),
          Text(
            '要求：仓库 public，且 Release 里至少有一个 .hap 附件。',
            style: AppText.caption(c),
          ),
        ],
      ),
    );
  }
}
