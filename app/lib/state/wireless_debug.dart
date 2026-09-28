// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 无线调试连接。
//
// ── 自连接（self-debug）是怎么回事 ────────────────────────────────────
// 星仓运行在**要安装应用的那台设备本机**上。它安装应用走设备自己的
// 调试通道：系统在某个端口上监听，`hdc tconn` 连上去后目标就是本机自己。
//
// ── 为什么必须让用户手填端口（两次修正后的结论）──────────────────────
//
// 第一版假设：读 `/proc/net/tcp` 取出本机监听端口，逐个试连。
// **这个前提是错的** —— HarmonyOS 沙箱不允许普通应用读该文件：
//
//     读取 /proc/net/tcp    失败：Permission denied, errno = 13
//     读取 /proc/net/tcp6   失败：Permission denied
//     读取 /proc/self/net/tcp   失败：Permission denied
//     读取 /proc/self/net/tcp6  失败：Permission denied
//
// （用 `hdc shell` 能读，因为 shell 权限更高 —— 这曾让我误判可行。）
//
// 第二版假设：退一步只认 loopback。**也是错的** —— 实测调试端口绑在
// WiFi 网卡与 0.0.0.0 上，loopback 上的几个端口都与调试无关。
//
// 结论：**应用侧无法自动发现调试端口**。原「小白」也是让用户手填
// （它硬编码 `port = "12345"`，由 `connectDevice(ip, port)` 接收输入）。
//
// 因此现在的策略是：
//   · 自动探测仍会尝试（万一将来沙箱放开），但**失败时如实说明原因**
//   · 主路径是**让用户填端口**，并给出在哪看到的准确指引
//
// ── 用户从哪里拿到端口 ────────────────────────────────────────────────
// 「设置 → 系统 → 开发者选项 → 无线调试」，页面上会显示 IP 与端口。
// 设备本机连自己用 `127.0.0.1:<端口>` 即可。

import 'dart:async';
import 'dart:io';

/// 无线调试连接结果。
class WirelessResult {
  WirelessResult({
    required this.ok,
    this.port = 0,
    this.target = '',
    this.message = '',
    this.candidates = const [],
    this.tried = const [],
  });

  final bool ok;
  final int port;

  /// `hdc list targets` 返回的目标标识
  final String target;
  final String message;

  /// 发现的本机监听端口（便于排错展示）
  final List<int> candidates;

  /// 实际尝试过的端口
  final List<int> tried;

  String get describe => ok ? '已连接（端口 $port）' : message;
}

/// 无线调试连接器。
class WirelessDebugger {
  WirelessDebugger({
    required this.runHdc,
    this.excludedPorts = const {},
    this.log,
    this.onProgress,
  });

  /// 执行 hdc 命令的回调（由平台层接到 ohosAdapter.hdcCmd）
  final Future<String> Function(String cmd) runHdc;

  /// 已知的非调试端口（如本应用自己的服务端口）
  final Set<int> excludedPorts;

  /// 诊断日志（真机排查用）
  final Future<void> Function(String msg)? log;

  /// 进度回调（供 UI 显示「正在试第 N 个端口」）
  final void Function(String msg)? onProgress;

  /// 单次 `hdc tconn` 的超时。端口多时避免整体卡住。
  static const Duration perPortTimeout = Duration(seconds: 4);

  /// 内置 hdc 服务是否已确认就绪（避免每次连接都重复探测）。
  bool _serverReady = false;

  /// 是否已经探测过（失败也只探一次，避免每个端口都白等）。
  bool _serverProbed = false;

  Future<void> _log(String m) async {
    try {
      await log?.call(m);
    } catch (_) {}
  }

  /// 等内置 hdc 服务就绪（只探一次）。
  ///
  /// `hdcServer(tempDir)` 是在**新的分离线程**里启动的（见原生 `hdcServer`）。
  /// 调用后立刻发命令，客户端可能还连不上服务器，于是 `hdc tconn` 秒失败、
  /// 表现就是「点了连接没反应、信任弹窗一直不出现」。
  ///
  /// 用 `hdc list targets` 探测：只要能拿到输出（哪怕是 `[Empty]`），
  /// 就说明服务端已经在应答。
  Future<bool> _ensureServerReady({Duration maxWait = const Duration(seconds: 6)}) async {
    if (_serverReady || _serverProbed) return _serverReady;
    _serverProbed = true;

    final cap = const Duration(seconds: 6);
    final timeout = maxWait < cap ? maxWait : cap;
    final deadline = DateTime.now().add(timeout);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      String out;
      try {
        out = await runHdc('hdc list targets');
      } catch (e) {
        out = 'error: $e';
      }
      final t = out.trim();
      await _log(
          '内置 hdc 探测 #$attempt → ${t.isEmpty ? "(无输出)" : t.replaceAll("\n", " ")}');
      if (t.contains('[Empty]') || parseTargets(t).isNotEmpty) {
        _serverReady = true;
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    await _log('内置 hdc 服务在 $timeout 内未就绪');
    return false;
  }

  /// 读取 `/proc/net/tcp`，取出本机所有处于 LISTEN 的端口。
  ///
  /// **不再按地址过滤**：调试端口可能绑在 loopback、`0.0.0.0` 或某块网卡上。
  /// 返回按「更可能是调试端口」排过序的列表：
  ///   · 先 `0.0.0.0`（监听所有接口，最典型）
  ///   · 再具体网卡地址
  ///   · 最后 loopback
  /// 端口号大于 1024 的优先（调试端口不会是特权端口）。
  static Future<List<int>> listenPorts({
    Future<String?> Function(String path)? readFile,
    Future<void> Function(String msg)? log,
  }) async {
    final reader = readFile ?? _defaultRead;

    // 依次尝试多个来源。HarmonyOS 上 `/proc/net/tcp` 对普通应用可能不可读，
    // 需要退回进程自己的 net 命名空间（`/proc/self/net/tcp`）等路径。
    String? raw;
    final triedPaths = <String>[];
    for (final path in const [
      '/proc/net/tcp',
      '/proc/net/tcp6',
      '/proc/self/net/tcp',
      '/proc/self/net/tcp6',
    ]) {
      triedPaths.add(path);
      try {
        final content = await reader(path);
        if (content != null && content.trim().isNotEmpty) {
          // 只要有一份带 LISTEN 的就够了
          if (content.contains('0A')) {
            raw = content;
            await log?.call('端口来源：$path');
            break;
          }
          raw ??= content;
        }
      } catch (e) {
        await log?.call('读取 $path 失败：$e');
      }
    }

    if (raw == null) {
      await log?.call('无法读取监听端口（试过：$triedPaths）');
      return const [];
    }

    final anyAddr = <int>{}; // 0.0.0.0
    final specific = <int>{}; // 具体地址
    final loopback = <int>{}; // 127.0.0.1

    for (final line in raw.split('\n').skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final local = parts[1];
      final state = parts[3];
      if (state.toUpperCase() != '0A') continue; // 0A = LISTEN

      final idx = local.lastIndexOf(':');
      if (idx <= 0) continue;
      final addr = local.substring(0, idx).toUpperCase();
      final port = int.tryParse(local.substring(idx + 1), radix: 16);
      if (port == null || port <= 0) continue;

      if (addr == '00000000') {
        anyAddr.add(port);
      } else if (addr == '0100007F') {
        loopback.add(port);
      } else {
        specific.add(port);
      }
    }

    List<int> sorted(Set<int> s) {
      final l = s.toList()..sort();
      // 高位端口优先：调试端口不会是特权端口
      final high = l.where((p) => p > 1024).toList();
      final low = l.where((p) => p <= 1024).toList();
      return [...high, ...low];
    }

    return [...sorted(anyAddr), ...sorted(specific), ...sorted(loopback)];
  }

  static Future<String?> _defaultRead(String path) async {
    // 不吞异常：读不到的原因（权限/不存在）是排查的关键信息。
    return await File(path).readAsString();
  }





  /// 尝试自动连接。全部候选失败时返回失败结果（含候选列表供 UI 展示）。
  Future<WirelessResult> connect({bool autoDiscover = true}) async {
    // 先看是否已经连上（用户可能刚连过）
    final existing = await _currentTargets();
    if (existing.isNotEmpty && await hasLiveConnection()) {
      await _log('已有连接目标：${existing.first}');
      return WirelessResult(
        ok: true,
        target: existing.first,
        message: '已连接',
      );
    }

    if (!autoDiscover) {
      return WirelessResult(ok: false, message: '需要手动指定调试端口');
    }

    final all = await listenPorts(log: _log);
    final ports =
        all.where((p) => !excludedPorts.contains(p)).toList(growable: false);

    await _log('发现本机监听端口 ${all.length} 个：${all.take(20).toList()}'
        '${all.length > 20 ? ' …' : ''}');

    if (ports.isEmpty) {
      return WirelessResult(
        ok: false,
        message: '系统不允许应用读取本机端口列表（沙箱限制），'
            '因此无法自动发现调试端口。\n'
            '请打开「设置 → 系统 → 开发者选项 → 无线调试」，'
            '把页面上的**端口号**填到下面。',
      );
    }

    final tried = <int>[];
    for (final port in ports) {
      tried.add(port);
      onProgress?.call('正在试端口 $port（${tried.length}/${ports.length}）');
      final res = await connectToPort(port);
      if (res.ok) {
        await _log('端口 $port 连接成功，目标 ${res.target}');
        return WirelessResult(
          ok: true,
          port: port,
          target: res.target,
          candidates: all,
          tried: tried,
        );
      }
      await _log('端口 $port 不是调试端口：${res.message}');
    }

    return WirelessResult(
      ok: false,
      message: '试过 ${ports.length} 个本机端口，都没连上调试通道。\n'
          '请在「设置 → 系统 → 开发者选项 → 无线调试」里查看端口号并手填。',
      candidates: all,
      tried: tried,
    );
  }

  /// 连接指定端口。
  ///
  /// **首次连接会弹出系统「是否信任此设备」对话框。** 该对话框会阻塞
  /// `hdc tconn` 直到用户作答，因此这里**等待 tconn 返回**（与参考实现
  /// 小白一致），而不是「发出去就去轮询」——
  ///
  /// ── 为什么不能「发射后不管 + 轮询」──────────────────────────────────
  /// 原生 `hdcCmd` 把输出写到一个**固定文件**（`<tempDir>/hdc.out`）并在每次
  /// 调用前 unlink。若一边挂着未完成的 tconn、一边每 2 秒发 `list targets`，
  /// 两条命令会争用同一个输出文件，且 tconn 的**返回内容被直接丢弃** ——
  /// 于是失败时完全看不到原因（实测就是这样：等满 60 秒、弹窗不出现、
  /// 日志里也没有任何 tconn 输出）。
  ///
  /// 现在：等 tconn 返回 → 记录其输出 → 以 `list targets` 复核。
  Future<WirelessResult> connectToPort(
    int port, {
    Duration trustWait = const Duration(seconds: 12),
    void Function(String msg)? onWait,
  }) async {
    // 先确认内置 hdc 服务在应答，否则 tconn 会秒失败（弹窗也不会出现）。
    await _ensureServerReady(maxWait: trustWait);

    // 先试 127.0.0.1（本机自连主路径）；仅当它**快速失败**时再试 localhost，
    // 避免在明显连不通时还要等两轮超时。
    for (final host in const ['127.0.0.1', 'localhost']) {
      final url = '$host:$port';

      // 同一主机名最多试两次：首次可能是服务刚起来或瞬时抖动。
      for (var attempt = 1; attempt <= 2; attempt++) {
        // 弹窗需要用户操作，等几秒后给出提示，否则用户以为卡死。
        final hintTimer = Timer(const Duration(seconds: 6), () {
          onWait?.call('若手机弹出「是否信任此设备」，请点「信任」');
        });

        final t0 = DateTime.now();
        String out;
        try {
          out = await runHdc('hdc tconn $url')
              .timeout(trustWait, onTimeout: () => '[Fail]timeout');
        } catch (e) {
          out = '[Fail]error: $e';
        } finally {
          hintTimer.cancel();
        }
        final elapsed = DateTime.now().difference(t0);
        final text = out.trim();
        await _log('tconn $url（第 $attempt 次，${elapsed.inMilliseconds}ms）'
            '→ ${text.isEmpty ? "(无输出)" : text}');

        // 以「目标列表」为准（不同 hdc 版本措辞不一）。
        final targets = await _currentTargets();
        await _log('list targets → ${targets.isEmpty ? "(空)" : targets.join(",")}');
        final tconnFailed = text.contains('[Fail]') ||
            text.toLowerCase().contains('error');
        if (!tconnFailed && targets.isNotEmpty &&
            await hasLiveConnection()) {
          return WirelessResult(ok: true, port: port, target: targets.first);
        }

        // tconn 一直没返回（超过 trustWait）：多半在等信任弹窗，或端口不通。
        // 再试另一个主机名只会让用户多等一轮，直接结束。
        if (text == '[Fail]timeout') {
          await _log('$url 等待超时（$trustWait），停止重试');
          return WirelessResult(
            ok: false,
            port: port,
            message: '等待超时：没有收到设备授权。\n'
                '如果手机上出现过「是否信任此设备」，请重新连接并点「信任」。',
          );
        }

        // 快速失败 → 退避后重试一次（吸收服务刚启动的抖动）。
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }

    return WirelessResult(
      ok: false,
      port: port,
      message: '未能连上该端口。请确认：\n'
          '· 端口号与开发者选项里显示的一致\n'
          '· 弹出「是否信任」时点了「信任」\n'
          '· 无线调试处于开启状态',
    );
  }

  /// 断开某个端口（清理探测残留）。
  Future<void> disconnect(int port) async {
    try {
      await runHdc('hdc tconn 127.0.0.1:$port -remove');
    } catch (_) {
      // 清理失败不影响主流程
    }
  }

  /// Ask the device over the active HDC channel, rather than trusting a
  /// previously entered port or a target left in HDC's target list.
  Future<bool> hasLiveConnection() async {
    try {
      final out = await runHdc('hdc shell bm get --udid')
          .timeout(perPortTimeout, onTimeout: () => '');
      return !out.contains('[Fail]') &&
          RegExp(r'\b[0-9A-Fa-f]{40,}\b').hasMatch(out);
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _currentTargets() async {
    try {
      final out = await runHdc('hdc list targets')
          .timeout(perPortTimeout, onTimeout: () => '');
      return parseTargets(out);
    } catch (_) {
      return const [];
    }
  }

  /// 解析 `hdc list targets` 的输出。
  ///
  /// 空列表时输出是 `[Empty]`，不能当成一个目标。
  static List<String> parseTargets(String raw) {
    return raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) =>
            l.isNotEmpty &&
            !l.startsWith('[Empty]') &&
            !l.startsWith('[') &&
            !l.toLowerCase().contains('fail'))
        .toList();
  }


}
