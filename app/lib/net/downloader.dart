// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 多镜像竞速下载器。
//
// ── 为什么要竞速 ──────────────────────────────────────────────────────
// GitHub 直链在国内常常极慢甚至不可达，而各个加速镜像的可用性又随时间
// 变化（实测 gh-proxy 可用、ghfast/ghproxy 时好时坏）。因此服务端为每个
// 附件返回 4 个候选地址，客户端**并行探测首字节**，取最快者下载。
//
// ── 安全约束 ─────────────────────────────────────────────────────────
// 下载完成后必须校验 SHA-256（服务端在采集时算好）。校验不通过一律丢弃，
// 绝不把未校验的包交给签名流程 —— 否则镜像被投毒就会直接装进设备。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../model/store_models.dart';

/// 下载阶段。
enum DownloadStage { probing, downloading, verifying, done, failed }

class DownloadProgress {
  DownloadProgress({
    required this.stage,
    this.received = 0,
    this.total = 0,
    this.mirror = '',
    this.message = '',
  });

  final DownloadStage stage;
  final int received;
  final int total;

  /// 当前使用的镜像地址
  final String mirror;
  final String message;

  double get ratio => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  String get receivedText {
    if (total <= 0) return _mb(received);
    return '${_mb(received)} / ${_mb(total)}';
  }

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

class DownloadResult {
  DownloadResult({required this.file, required this.sha256, required this.mirror});

  final File file;
  final String sha256;

  /// 实际使用的镜像（便于诊断）
  final String mirror;
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => 'DownloadException: $message';
}

class MirrorDownloader {
  MirrorDownloader({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// 探测超时：首字节迟迟不来就换下一个候选
  static const Duration _probeTimeout = Duration(seconds: 8);

  /// 整体下载超时（大包需要更久）
  static const Duration _downloadTimeout = Duration(minutes: 20);

  /// 并行探测各镜像，返回第一个成功响应首字节的地址。
  ///
  /// 返回 (地址, 响应) —— 响应已开始流式读取，交由调用方消费。
  Future<String> pickFastest(List<String> candidates,
      {void Function(String msg)? onLog}) async {
    if (candidates.isEmpty) {
      throw DownloadException('没有可用的下载地址');
    }
    if (candidates.length == 1) return candidates.first;

    final completer = Completer<String>();
    var pending = candidates.length;

    for (final url in candidates) {
      () async {
        try {
          final req = http.Request('GET', Uri.parse(url));
          req.headers['Range'] = 'bytes=0-0'; // 只取 1 字节，最快拿到首字节
          final resp = await _http.send(req).timeout(_probeTimeout);
          if (resp.statusCode == 200 || resp.statusCode == 206) {
            if (!completer.isCompleted) {
              onLog?.call('选用镜像：${_short(url)}');
              completer.complete(url);
            }
          }
          // 主动排空/关闭，避免连接泄漏
          await resp.stream.drain<void>().catchError((_) {});
        } catch (_) {
          // 该镜像不可用，静默跳过
        } finally {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.completeError(
                DownloadException('全部 ${candidates.length} 个镜像均不可用'));
          }
        }
      }();
    }
    return completer.future;
  }

  /// 下载到 [destDir]，带进度回调与 SHA-256 校验。
  Future<DownloadResult> download({
    required HapAsset asset,
    required Directory destDir,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final candidates = asset.mirrorUrls.isNotEmpty
        ? asset.mirrorUrls
        : (asset.url.isNotEmpty ? [asset.url] : <String>[]);
    if (candidates.isEmpty) {
      throw DownloadException('该附件没有下载地址');
    }

    onProgress?.call(DownloadProgress(stage: DownloadStage.probing));

    final dest = File('${destDir.path}/${_safeName(asset.name)}');
    if (await dest.exists()) await dest.delete();
    await destDir.create(recursive: true);

    // 逐个尝试：先用竞速挑出最快的，失败再按顺序兜底。
    Object? lastError;
    final ordered = <String>[];
    try {
      ordered.add(await pickFastest(candidates));
    } catch (e) {
      lastError = e;
    }
    for (final c in candidates) {
      if (!ordered.contains(c)) ordered.add(c);
    }

    for (final url in ordered) {
      try {
        await _downloadOne(url, dest, asset.size, onProgress);
        onProgress?.call(DownloadProgress(
            stage: DownloadStage.verifying, mirror: url, total: asset.size));

        final actual = await _sha256OfFile(dest);
        // 可信哈希是**安装的必备条件**：拿不到哈希就不装。
        // 早先「哈希为空则跳过校验」等于给镜像投毒留了后门 —— 一个能篡改
        // 元数据的中间人只要清空 sha256 字段，未校验的包就会被签名安装。
        if (asset.sha256.isEmpty) {
          await dest.delete();
          throw DownloadException(
              '该附件缺少可信 SHA-256，已拒绝安装（无法确认镜像内容与 GitHub 原件一致）');
        }
        if (actual != asset.sha256.toLowerCase()) {
          await dest.delete();
          throw DownloadException(
              'SHA-256 校验失败（期望 ${asset.sha256.substring(0, 12)}…，'
              '实际 ${actual.substring(0, 12)}…）—— 已丢弃该文件');
        }

        onProgress?.call(DownloadProgress(
            stage: DownloadStage.done,
            received: asset.size,
            total: asset.size,
            mirror: url));
        return DownloadResult(file: dest, sha256: actual, mirror: url);
      } catch (e) {
        lastError = e;
        if (await dest.exists()) await dest.delete();
      }
    }

    onProgress?.call(DownloadProgress(
        stage: DownloadStage.failed, message: '$lastError'));
    throw DownloadException('下载失败：$lastError');
  }

  Future<void> _downloadOne(
    String url,
    File dest,
    int expectedSize,
    void Function(DownloadProgress)? onProgress,
  ) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await _http.send(req).timeout(_probeTimeout);
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw DownloadException('镜像返回 HTTP ${resp.statusCode}');
    }
    final total = int.tryParse(resp.headers['content-length'] ?? '') ??
        (expectedSize > 0 ? expectedSize : 0);

    final sink = dest.openWrite();
    var received = 0;
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;

    sub = resp.stream.listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(
          stage: DownloadStage.downloading,
          received: received,
          total: total,
          mirror: url,
        ));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future.timeout(_downloadTimeout);
    } finally {
      await sub.cancel();
      await sink.flush();
      await sink.close();
    }

    if (received == 0) {
      throw DownloadException('镜像未返回任何数据');
    }
    if (expectedSize > 0 && received != expectedSize) {
      throw DownloadException('大小不符（期望 $expectedSize，实际 $received）');
    }
  }

  static Future<String> _sha256OfFile(File f) async {
    final sink = AccumulatorSink<Digest>();
    final conv = sha256.startChunkedConversion(sink);
    await for (final chunk in f.openRead()) {
      conv.add(chunk);
    }
    conv.close();
    return sink.events.single.toString();
  }

  static String _safeName(String name) {
    // 只取 basename，避免路径穿越
    final base = name.split('/').last.split('\\').last;
    return base.isEmpty ? 'download.hap' : base;
  }

  static String _short(String url) {
    if (url.length <= 56) return url;
    return '${url.substring(0, 28)}…${url.substring(url.length - 24)}';
  }

  void dispose() => _http.close();
}

/// 与 `package:convert` 的 AccumulatorSink 等价的最小实现，
/// 避免为一个类引入额外依赖。
class AccumulatorSink<T> implements Sink<T> {
  final _events = <T>[];

  List<T> get events => _events;

  T get single => _events.single;

  @override
  void add(T data) => _events.add(data);

  @override
  void close() {}
}

/// 便于测试：把 utf8 文本转字节
List<int> utf8Bytes(String s) => utf8.encode(s);
