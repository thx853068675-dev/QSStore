// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 首次使用引导 —— 登录与连接无线调试。
//
//   ① 登录华为开发者账号   → 自动生成本机唯一签名身份并申请证书
//   ② 连接无线调试         → 自动发现端口并连上，之后安装走这条通道
//
// 用户不需要接触任何文件、不需要 OpenSSL、不需要命令行。

import 'package:flutter/material.dart';

import '../state/signing_setup.dart';
import '../theme/tokens.dart';
import 'certificate_manager_sheet.dart';
import 'components/basic.dart';

class SetupGuidePage extends StatefulWidget {
  const SetupGuidePage({
    super.key,
    required this.controller,
  });

  final SigningSetupController controller;

  @override
  State<SetupGuidePage> createState() => _SetupGuidePageState();
}

class _SetupGuidePageState extends State<SetupGuidePage> {
  final _portController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final port = widget.controller.lastEnteredPort > 0
        ? widget.controller.lastEnteredPort
        : widget.controller.connectedPort;
    if (port > 0) _portController.text = '$port';
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _portController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.controller;

    return Scaffold(
      backgroundColor: c.backgroundGrouped,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              Space.pageGutter, Space.xl, Space.pageGutter, Space.xxl),
          children: [
            const SizedBox(height: Space.lg),
            Text('轻启·安装器', style: AppText.largeTitle(c)),
            const SizedBox(height: Space.xs),
            Text('完成登录和无线调试连接，即可一键安装应用',
                style: AppText.subhead(c)),
            const SizedBox(height: Space.xl),

            // ── ① 登录 ────────────────────────────────────────
            _StepCard(
              index: 1,
              title: '登录华为开发者账号',
              subtitle: '登录后复用或申请签名证书',
              state: s.loginState,
              expanded: s.loginState != SetupStepState.done,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '登录后自动复用账号已有签名身份；首次安装应用时，'
                    '再按该应用申请并缓存设备授权。',
                    style: AppText.footnote(c),
                  ),
                  if (s.loginMessage.isNotEmpty) ...[
                    const SizedBox(height: Space.sm),
                    _message(c, s.loginMessage,
                        s.loginState == SetupStepState.failed),
                  ],
                  const SizedBox(height: Space.md),
                  _actionButton(
                    context,
                    label: s.loginState == SetupStepState.done ? '重新登录' : '登录',
                    busy: s.loginState == SetupStepState.running,
                    onPressed: s.loginState == SetupStepState.running
                        ? null
                        : () => s.login(),
                  ),
                  if (s.materials.isSignedIn) ...[
                    const SizedBox(height: Space.sm),
                    AppButton(
                      label: '查看与管理 AGC 证书',
                      icon: Icons.verified_user_outlined,
                      tone: AppButtonTone.secondary,
                      expand: true,
                      onPressed: () =>
                          showCertificateManager(context, s.materials),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: Space.md),

            // ── ② 无线调试 ────────────────────────────────────
            _StepCard(
              index: 2,
              title: '连接无线调试',
              subtitle: '轻启·安装器通过它把应用安装到本机',
              state: s.debugState,
              expanded: s.loginState == SetupStepState.done &&
                  s.debugState != SetupStepState.done,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '打开「设置 → 系统 → 开发者选项 → 无线调试」，'
                    '把页面上的端口号填在下面。',
                    style: AppText.footnote(c),
                  ),
                  const SizedBox(height: Space.sm),
                  // 直达无线调试页：不用用户自己在设置里层层找
                  _actionButton(
                    context,
                    label: '打开无线调试设置',
                    busy: false,
                    onPressed: () => s.openWirelessSettings(),
                  ),
                  if (!s.settingsJumpOk) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      '若没跳转，请手动前往：设置 → 系统 → 开发者选项 → 无线调试',
                      style: AppText.caption(c),
                    ),
                  ],
                  if (s.debugMessage.isNotEmpty) ...[
                    const SizedBox(height: Space.sm),
                    _message(c, s.debugMessage,
                        s.debugState == SetupStepState.failed),
                  ],
                  const SizedBox(height: Space.md),
                  // 地址用**文字**样式（不可编辑，一眼看出是只读信息），
                  // 端口用**带边框的输入框**（一眼看出要在这里输入）。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('127.0.0.1:',
                          style: AppText.body(c).copyWith(
                              fontSize: FontSizes.callout,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          style: AppText.body(c)
                              .copyWith(fontSize: FontSizes.callout),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '在此输入端口号',
                            hintStyle: AppText.caption(c),
                            filled: true,
                            fillColor: c.card,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: Space.md, vertical: 13),
                            // 有边框 → 明显是个输入框
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.field),
                              borderSide:
                                  BorderSide(color: c.separator, width: 1),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.field),
                              borderSide:
                                  BorderSide(color: c.accent, width: 1.5),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.field),
                              borderSide:
                                  BorderSide(color: c.separator, width: 1),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  // 连接按钮：单独一行，主色实底
                  AppButton(
                    label: s.debugState == SetupStepState.running ? '连接中…' : '连接',
                    expand: true,
                    busy: s.debugState == SetupStepState.running,
                    onPressed: () {
                      final p0 = int.tryParse(_portController.text.trim());
                      if (p0 != null && p0 > 0 && p0 <= 65535) {
                        s.connectWireless(port: p0);
                      }
                    },
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }

  Widget _message(AppColors c, String text, bool isError) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.error_outline : Icons.info_outline,
          size: 15,
          color: isError ? c.redText : c.textSecondary,
        ),
        const SizedBox(width: Space.xs),
        Expanded(
          child: Text(
            text,
            style: AppText.caption(c).copyWith(color: isError ? c.redText : null),
          ),
        ),
      ],
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required String label,
    required bool busy,
    required VoidCallback? onPressed,
  }) {
    return AppButton(
      label: label,
      expand: true,
      busy: busy,
      onPressed: onPressed,
    );
  }
}

/// 步骤卡片。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.state,
    required this.expanded,
    required this.body,
  });

  final int index;
  final String title;
  final String subtitle;
  final SetupStepState state;
  final bool expanded;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final done = state == SetupStepState.done;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(
          color: done ? c.green.withOpacity(0.4) : Colors.transparent,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _badge(c, done, state),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.headline(c)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: AppText.caption(c)),
                  ],
                ),
              ),
              if (done)
                Icon(Icons.check_circle, size: 20, color: c.green)
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    children: [
                      const SizedBox(height: Space.md),
                      Divider(height: 0.5, thickness: 0.5, color: c.separator),
                      const SizedBox(height: Space.md),
                      body,
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _badge(AppColors c, bool done, SetupStepState state) {
    final color = done
        ? c.green
        : (state == SetupStepState.running ? c.accent : c.textTertiary);
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(Space.touch / 2 - 9),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          fontSize: FontSizes.footnote,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
