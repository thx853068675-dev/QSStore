// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 登录与无线调试连接的状态机。
//
//   ① 登录华为开发者账号   → 生成密钥对 → CSR → 证书
//   ② 连接无线调试         → 自动发现端口并连上
//
// 把编排逻辑放在这里（而不是页面里），是为了：
//   · 状态可测试：不依赖 Widget 就能验证登录与连接的推进和失败处理
//   · 页面只管展示与触发

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ohos_adapter/ohos_adapter.dart';

import '../net/api_client.dart';
import 'agc/huawei_login.dart';
import 'identity_generator.dart';
import 'ohos_platform.dart';
import 'sign_material_store.dart';
import 'wireless_debug.dart';

enum SetupStepState { pending, running, done, failed }

/// 准备流程控制器。
///
/// 需注入 [platform]：真实运行时是 [OhosInstallPlatform]，
/// 测试时可注入替身。
class SigningSetupController extends ChangeNotifier {
  SigningSetupController({
    required this.materials,
    required this.platform,
    required this.api,
    HuaweiLogin Function()? loginFactory,
  }) : _loginFactory = loginFactory;

  final SignMaterialStore materials;
  final ApiClient api;

  /// 平台能力。真实运行时是 [OhosInstallPlatform]。
  final SetupPlatform platform;
  final HuaweiLogin Function()? _loginFactory;

  // ── ① 登录 ──
  SetupStepState loginState = SetupStepState.pending;
  String loginMessage = '';

  // ── ② 无线调试 ──
  SetupStepState debugState = SetupStepState.pending;

  /// 上次跳转设置页是否成功（用于决定是否展示文字指引）。
  bool settingsJumpOk = true;
  String debugMessage = '';
  List<int> debugCandidates = const [];
  int connectedPort = 0;
  int lastEnteredPort = 0;
  String deviceTarget = '';

  /// 登录与无线调试连接是否都完成。
  bool get ready =>
      loginState == SetupStepState.done && debugState == SetupStepState.done;

  @override
  void dispose() {
    // 无内部资源需要释放
    super.dispose();
  }

  // ────────────────── ① 登录 + 身份准备 ──────────────────

  /// 登录 → 生成密钥对 → 生成 CSR → 申请证书。
  /// 设备授权在无线调试接通后申请，因为读取本机 UDID 依赖 HDC。
  Future<void> login() async {
    await _log('login() 被调用；当前登录态=${materials.isSignedIn} '
        '材料完整=${materials.isComplete}');
    if (loginState == SetupStepState.running) {
      await _log('已有登录在进行中，忽略本次点击');
      return;
    }
    _setLogin(SetupStepState.running, '检查登录状态…');

    // 0) 已有可用登录态就不必再走浏览器 —— 用户可能只是要做后面的步骤。
    if (materials.isSignedIn) {
      try {
        final stillValid = await materials.ensureAgc().checkSignedIn();
        await _log('已有登录态，有效性=$stillValid');
        if (stillValid) {
          await _log('复用已有登录态，跳过浏览器');
          await _afterLogin();
          return;
        }
      } catch (e) {
        await _log('校验登录态出错：$e');
      }
    }

    _setLogin(SetupStepState.running, '正在打开授权页…');

    // 1) 登录
    final login = _loginFactory?.call() ??
        HuaweiLogin(agc: materials.ensureAgc());

    final result = await login.login();
    await _log('登录结果：${result.outcome} ${result.message}');
    if (!result.ok) {
      _setLogin(SetupStepState.failed, result.describe);
      return;
    }
    await materials.saveAuth(result.authInfo!);
    await _log('登录态已保存，账号 ${materials.accountLabel}');
    await _afterLogin();
  }

  /// 登录之后生成身份并申请证书；设备授权在无线调试连接后申请。
  ///
  /// 抽出来是为了让「已有登录态」的路径也能复用，不必重复走浏览器。
  Future<void> _afterLogin() async {
    _setLogin(SetupStepState.running, '已登录 ${materials.accountLabel}，正在准备签名身份…');

    // 新设备先取回同一账号既有身份，避免重复申请 AGC 调试证书。
    if (!materials.hasCertificate) {
      try {
        final result = await api.signingIdentity();
        final cloud = result['identity'];
        if (cloud is Map<String, dynamic>) {
          final pem = cloud['private_key_pem'];
          if (pem is! String) {
            _setLogin(SetupStepState.failed, '云端签名身份格式异常');
            return;
          }
          final error = await materials.restoreExistingIdentity(pem);
          if (error != null) {
            _setLogin(SetupStepState.failed, '无法复用账号现有证书：$error');
            return;
          }
          await _log('已自动复用同一账号的签名证书');
        }
      } on ApiException catch (e) {
        await _log('签名身份同步暂不可用：${e.code}');
        _setLogin(SetupStepState.failed, '账号签名身份同步暂不可用，请稍后重试');
        return;
      } catch (e) {
        await _log('签名身份同步失败：$e');
        _setLogin(SetupStepState.failed, '账号签名身份同步暂不可用，请稍后重试');
        return;
      }
    }

    // 2) 生成唯一密钥对 + CSR（本机完成，不需要 OpenSSL）
    // 身份由纯 Dart 生成（设备内签名器的 keypair/csr 子命令有缺陷），
    // 因此这里不再注入原生实现。
    final idErr = await materials.ensureIdentity();
    await _log('身份生成：${idErr ?? "成功"}');
    if (idErr != null) {
      _setLogin(SetupStepState.failed, idErr);
      return;
    }
    _setLogin(SetupStepState.running, '正在向华为申请调试证书…');

    // 3) 申请证书
    final certErr = await materials.ensureCertificate(allowLastSlot: true);
    await _log('证书申请：${certErr ?? "成功"}');
    if (certErr != null) {
      _setLogin(SetupStepState.failed, certErr);
      return;
    }

    await syncIdentityToCloud();

    _setLogin(SetupStepState.done, '证书已就绪：${materials.accountLabel}');
    notifyListeners();
  }

  /// 后台尽力而为上传本机已配对的签名身份。首次写入后云端保持不变。
  Future<void> syncIdentityToCloud() async {
    if (!materials.isSignedIn || !materials.hasCertificate ||
        materials.certId.isEmpty) return;
    try {
      final pem = await File(materials.config.keystoreFile).readAsString();
      final cert = await File(materials.config.certPath).readAsBytes();
      if (isKeyCertPaired(privateKeyPem: pem, certificate: cert) != true) return;
      await api.publishSigningIdentity(materials.certId, pem);
      await _log('账号签名身份已自动同步');
    } catch (e) {
      await _log('账号签名身份后台同步失败：$e');
    }
  }

  // ────────────────── ② 无线调试 ──────────────────



  /// 跳转系统的「无线调试」设置页。
  ///
  /// 实现照搬轻启 0.9.51 的 `openSystemSettings`
  /// （`entry/src/main/ets/pages/Index.ets`）。要点是**四个字段都要给**：
  ///
  ///   bundleName  = com.huawei.hmos.settings
  ///   abilityName = com.huawei.hmos.settings.MainAbility
  ///   uri         = system_wireless_commissioning
  ///   action      = ohos.want.action.viewData
  ///
  /// 少给 bundle/ability 时系统会回 "start ability successfully"
  /// 但实际不打开任何页面（踩过这个坑）；已在设备上验证加上后
  /// 前台会变成 `com.huawei.hmos.settings:phone_settings:...MainAbility`。
  ///
  /// 相关坐标不必猜：用户从页面上读到端口后回来填。
  Future<void> openWirelessSettings() async {
    final ok = await platform.openSystemSettings('wireless');
    settingsJumpOk = ok;
    // Opening Settings from "My" must not discard a still-live connection.
    if (debugState == SetupStepState.done) return;
    if (ok) {
      _setDebug(SetupStepState.pending,
          '已打开无线调试页，记下端口号后回来填写');
    } else {
      _setDebug(SetupStepState.failed,
          '未能打开设置页，请手动前往：设置 → 系统 → 开发者选项 → 无线调试');
    }
  }

  /// Reconnect without changing the main page. Installation waits for this
  /// result, then resumes from the point where it needed the device channel.
  Future<String?> reconnectForInstall(int port) async {
    lastEnteredPort = port;
    await platform.startHdcServer();
    final wd = platform.wireless();
    if (connectedPort > 0 && connectedPort != port) {
      await wd.disconnect(connectedPort);
    }
    final res = await wd.connectToPort(port,
        trustWait: const Duration(seconds: 60));
    if (!res.ok) return res.message;
    connectedPort = res.port;
    deviceTarget = res.target;
    debugMessage = '已连接（端口 $port）';
    notifyListeners();
    return null;
  }

  /// 连接无线调试。传入 [port] 时跳过自动发现。
  Future<void> connectWireless({int? port}) async {
    if (debugState == SetupStepState.running) return;
    if (port != null) lastEnteredPort = port;
    _setDebug(SetupStepState.running, '正在查找本机调试端口…');

    await platform.startHdcServer();
    final wd = platform.wireless(onProgress: (m) {
      // 把「正在试第 N 个端口」显示出来，避免长时间无反馈
      _setDebug(SetupStepState.running, m);
    });

    final WirelessResult res;
    if (port != null) {
      if (connectedPort > 0 && connectedPort != port) {
        await wd.disconnect(connectedPort);
      }
      // 首次连接会弹系统「信任」对话框；把等待状态显示出来，
      // 否则用户点完信任会觉得"没反应"。
      // 用户手填端口这条路径会触发系统「信任」弹窗，给足 60 秒作答时间。
      res = await wd.connectToPort(
        port,
        trustWait: const Duration(seconds: 60),
        onWait: (m) => _setDebug(SetupStepState.running, m),
      );
    } else {
      res = await wd.connect();
    }

    if (res.ok) {
      connectedPort = res.port;
      deviceTarget = res.target;
      _setDebug(
        SetupStepState.done,
        res.port > 0 ? '已连接（端口 ${res.port}）' : '已连接',
      );
      return;
    }

    debugCandidates = res.candidates;
    _setDebug(SetupStepState.failed, res.message);
  }

  /// 重新检测已完成的步骤（启动时用）。
  Future<void> refresh() async {
    await _log('refresh()：登录态=${materials.isSignedIn} '
        '材料完整=${materials.isComplete} 账号=${materials.accountLabel}');
    if (materials.isSignedIn && materials.hasCertificate) {
      loginState = SetupStepState.done;
      loginMessage = '证书已就绪：${materials.accountLabel}';
      // The actual HDC channel is checked lazily when installation reaches
      // device authorization. Do not block browsing after an app restart.
      debugState = SetupStepState.done;
      debugMessage = '安装时检查无线调试连接';
    }
    notifyListeners();
  }

  // ────────────────── 内部 ──────────────────

  /// 写系统日志，便于真机排查（hilog 标签 StarHub）。
  Future<void> _log(String msg) async {
    try {
      await ohosAdapter.log('[setup] $msg');
    } catch (_) {}
  }

  void _setLogin(SetupStepState s, String msg) {
    loginState = s;
    loginMessage = msg;
    notifyListeners();
  }

  void _setDebug(SetupStepState s, String msg) {
    debugState = s;
    debugMessage = msg;
    notifyListeners();
  }
}
