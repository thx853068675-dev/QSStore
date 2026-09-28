// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 华为账号登录（DevEco 授权流程）。
//
// ── 流程 ──────────────────────────────────────────────────────────────
//   1. 本机起临时 HTTP 服务，监听回调端口
//   2. 用系统浏览器打开华为授权页，回调地址指向该端口
//   3. 用户在浏览器完成登录，华为带着 tempToken 回调本机服务
//   4. 用 tempToken 换取 jwtToken 与 userInfo（见 AgcService）
//   5. 关闭临时服务
//
// ── 为什么要监听多个端口 ──────────────────────────────────────────────
// 授权页通过 URL 里的 `port` 参数得知该回调到哪里。实测中曾出现
// 「浏览器登录后应用毫无反应」——即回调没打到我们监听的端口。
//
// 可能的原因有两类：授权页未尊重我们传的 port，或它固定回调到
// DevEco 惯用的 8888。这两种情况我们都无法从客户端控制，但可以
// **两个端口都监听**，从结果上消除该分支：无论它打到哪个端口都能收到。
//
// 8888 是主选：它是 DevEco 的惯用端口，也更可能是授权页的默认目标。
// 被占用时退回随机端口。
//
// ── 关于诊断 ──────────────────────────────────────────────────────────
// `print` 在鸿蒙上不保证进入系统日志，因此这里统一走 ohosAdapter.log
// （原生侧写 hilog，标签 StarHub）。排查真机问题时：
//     hdc shell hilog -x | grep StarHub

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ohos_adapter/ohos_adapter.dart';

import 'agc_models.dart';
import 'agc_service.dart';

/// 华为授权页。`8888` 是「回调端口」占位符，会被替换为实际监听端口。
const String kDevEcoAuthUrl =
    'https://cn.devecostudio.huawei.com/console/DevEcoIDE/apply'
    '?port=8888&appid=1007&code=20698961dd4f420c8b44f49010c6f0cc';

/// AGC 控制台（用户可能需要在这里完成实名/开发者认证）。
const String kAgcConsoleUrl =
    'https://developer.huawei.com/consumer/cn/service/josp/agc/index.html'
    '#/harmonyOSDevPlatform/9249519184596237889';

/// DevEco 惯用的回调端口，优先使用。
const int kPreferredCallbackPort = 8888;

enum LoginOutcome { success, timeout, cancelled, failed }

class LoginResult {
  LoginResult({
    required this.outcome,
    this.authInfo,
    this.message = '',
    this.port = 0,
  });

  final LoginOutcome outcome;
  final AuthInfo? authInfo;
  final String message;

  /// 实际收到回调的端口（0 表示没收到）。
  final int port;

  bool get ok => outcome == LoginOutcome.success && authInfo != null;

  /// 面向用户的一句话说明。
  String get describe {
    switch (outcome) {
      case LoginOutcome.success:
        return '登录成功';
      case LoginOutcome.timeout:
        return message.isNotEmpty
            ? message
            : '登录超时：请在浏览器里完成登录后重试';
      case LoginOutcome.cancelled:
        return '已取消登录';
      case LoginOutcome.failed:
        return message.isEmpty ? '登录失败' : message;
    }
  }
}

class HuaweiLogin {
  HuaweiLogin({required this.agc, int? port})
      : port = port ?? (3333 + Random().nextInt(1000));

  final AgcService agc;

  /// 首选回调端口（8888 被占用时会退回随机端口）。
  final int port;

  /// 当前实际监听的端口列表。
  final List<int> listeningPorts = [];

  final List<HttpServer> _servers = [];
  bool _cancelled = false;

  /// 写系统日志（hilog）。真机排查用。
  Future<void> _log(String msg) async {
    try {
      await ohosAdapter.log('[login] $msg');
    } catch (_) {
      // 日志失败不影响流程
    }
  }

  Future<void> openUrl(String url) async {
    if (ohosAdapter.isOhos) {
      await ohosAdapter.openUrl(url);
      return;
    }
    throw UnsupportedError('当前平台不支持自动打开浏览器：$url');
  }

  /// 打开授权页。用 [onPort] 指定回调端口。
  Future<void> openAuthPage({int? onPort}) {
    final p = onPort ?? port;
    // 只替换 port 参数，避免误伤 URL 中其它位置的数字。
    final url = kDevEcoAuthUrl.replaceFirst('port=8888', 'port=$p');
    return openUrl(url);
  }

  /// 执行完整登录。超时或取消都会返回明确结果，不抛异常。
  ///
  /// 会同时监听 [port] 与 [kPreferredCallbackPort]（若可用），
  /// 因此无论授权页回调到哪个端口都能收到。
  Future<LoginResult> login({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    _cancelled = false;
    _servers.clear();
    listeningPorts.clear();

    // ── 1. 绑定回调端口 ──────────────────────────────────────────
    final wantPorts = <int>[];
    if (port != kPreferredCallbackPort) wantPorts.add(kPreferredCallbackPort);
    wantPorts.add(port);

    for (final p in wantPorts) {
      try {
        final s = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _servers.add(s);
        listeningPorts.add(p);
        await _log('已监听端口 $p');
      } on SocketException catch (e) {
        await _log('端口 $p 绑定失败：${e.osError?.message ?? e.message}');
      }
    }

    if (_servers.isEmpty) {
      return LoginResult(
        outcome: LoginOutcome.failed,
        message: '无法监听回调端口（$wantPorts 都被占用）。'
            '请关闭其它正在登录的应用后重试。',
      );
    }

    // 浏览器要打开的端口：优先 8888（若已监听到），否则用首选端口。
    final advertisePort =
        listeningPorts.contains(kPreferredCallbackPort) ? kPreferredCallbackPort : port;
    await _log('将向授权页声明回调端口 $advertisePort');

    final completer = Completer<LoginResult>();
    _active = completer;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(LoginResult(
          outcome: LoginOutcome.timeout,
          message: '等待登录回调超时。'
              '若浏览器里已显示登录成功，说明回执没有送达本机，请重试。',
        ));
      }
    });

    // ── 2. 挂上请求处理 ─────────────────────────────────────────
    for (final server in _servers) {
      server.listen(
        _handle,
        onError: (e) => _log('监听出错：$e'),
      );
    }

    // ── 3. 打开授权页 ───────────────────────────────────────────
    try {
      await openAuthPage(onPort: advertisePort);
      await _log('已打开授权页');
    } catch (e) {
      timer.cancel();
      await _shutdown();
      return LoginResult(
        outcome: LoginOutcome.failed,
        message: '无法打开授权页：$e',
      );
    }

    final result = await completer.future;
    timer.cancel();
    await _shutdown();
    await _log('登录结束：${result.outcome} ${result.message}');
    return result;
  }

  /// 处理一个回调请求。
  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final q = request.uri.query;
    await _log('收到请求 ${request.method} $path'
        '${q.isEmpty ? '' : '?$q'}'
        '（来自 ${request.connectionInfo?.remoteAddress.address}）');

    // 浏览器从 HTTPS 页面跳到 http://localhost 时可能先发 CORS 预检
    // （Private Network Access）。必须回应，否则真正的回调被浏览器拦下。
    if (request.method == 'OPTIONS') {
      try {
        final h = request.response.headers;
        h.set('Access-Control-Allow-Origin', '*');
        h.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        h.set('Access-Control-Allow-Headers', '*');
        h.set('Access-Control-Allow-Private-Network', 'true');
        h.set('Access-Control-Max-Age', '600');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      } catch (_) {}
      await _log('已回应 CORS 预检');
      return;
    }

    if (_cancelled) {
      _respond(request, HttpStatus.serviceUnavailable, '已取消');
      return;
    }

    // 回调路径可能不是 /callback（授权页版本差异），因此带 tempToken 的
    // 请求一律当作回调处理，避免因路径不符白白丢掉回执。
    final body = await utf8.decoder.bind(request).join();
    final params = request.uri.queryParameters;
    final hasToken =
        body.contains('tempToken') || params.containsKey('tempToken');

    // 授权页在用户点「取消」时会带 quit=quit 回调
    if (params['quit'] != null) {
      await _log('用户在授权页点了取消');
      _respond(request, HttpStatus.ok, '已取消授权');
      _finish(LoginResult(
        outcome: LoginOutcome.cancelled,
        message: '你在授权页取消了登录',
      ));
      return;
    }

    if (path != '/callback' && !hasToken) {
      _respond(request, HttpStatus.notFound, '404 Not Found');
      return;
    }

    await _log('回调内容长度 ${body.length}');

    // 有些实现把参数放在查询串而非 body，两种都试。
    final payload = body.isNotEmpty
        ? body
        : request.uri.query;

    try {
      final info = await agc.getAuthInfoBytempToken(payload);
      if (info == null || !info.isComplete) {
        _respond(request, HttpStatus.ok, '登录信息不完整，请返回应用重试');
        _finish(LoginResult(
          outcome: LoginOutcome.failed,
          message: '未取得完整的登录信息',
        ));
        return;
      }
      _respond(request, HttpStatus.ok, '登录成功，请返回应用');
      _finish(LoginResult(outcome: LoginOutcome.success, authInfo: info));
    } on AgcException catch (e) {
      await _log('换取登录信息失败：${e.message}');
      _respond(request, HttpStatus.ok, '登录失败：${e.message}');
      _finish(LoginResult(outcome: LoginOutcome.failed, message: e.message));
    } catch (e) {
      await _log('换取登录信息异常：$e');
      _respond(request, HttpStatus.ok, '登录失败，请返回应用重试');
      _finish(LoginResult(outcome: LoginOutcome.failed, message: '$e'));
    }
  }

  Completer<LoginResult>? _active;

  void _finish(LoginResult r) {
    final c = _active;
    if (c != null && !c.isCompleted) c.complete(r);
  }

  /// 主动取消（UI 上的「取消」按钮）。
  Future<void> cancel() async {
    _cancelled = true;
    await _shutdown();
  }

  Future<void> _shutdown() async {
    for (final s in _servers) {
      try {
        await s.close(force: true);
      } catch (_) {
        // 已关闭
      }
    }
    _servers.clear();
  }

  void _respond(HttpRequest request, int status, String message) {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..write('''
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>华为账号登录</title>
<style>
 body{margin:0;background:#f2f2f7;color:#000;
   font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
   display:flex;align-items:center;justify-content:center;height:100vh}
 .card{background:#fff;border-radius:14px;padding:32px 28px;max-width:320px;
   text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.08)}
 h1{font-size:19px;margin:0 0 8px}
 p{font-size:15px;color:#8e8e93;margin:0;line-height:1.6}
</style></head><body><div class="card">
<h1>$message</h1><p>此页面可以关闭</p>
</div></body></html>''')
        ..close();
    } catch (_) {
      // 浏览器可能已断开
    }
  }
}
