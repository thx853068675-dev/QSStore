// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 工作模块清单的构建与摘要工具。
//
// 原实现把这段逻辑内联在主流程里，且格式细节（两空格缩进、结尾换行）与
// 构建期生成的清单必须完全一致，否则「载荷未变」校验会在下一轮失败。
// 单独成文件便于测试锁定这个格式契约。

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 计算字节内容的 SHA-256 十六进制字符串。
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 生成工作模块清单的 JSON 文本。
///
/// 保持与原实现完全一致的序列化格式：`JsonEncoder.withIndent('  ')` + 末尾换行。
/// 这不是随意选择 —— 构建期脚本用同样的格式生成原始清单，格式不一致会导致
/// 每轮重签都把清单标记为「已改变」。
String buildWorkerManifest({
  required Map<String, dynamic> base,
  required int workerSize,
  required String workerSha256,
}) {
  final manifest = Map<String, dynamic>.from(base)
    ..['size'] = workerSize
    ..['sha256'] = workerSha256;
  return '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
}

/// 生成清单的 UTF-8 字节。
Uint8List buildWorkerManifestBytes({
  required Map<String, dynamic> base,
  required int workerSize,
  required String workerSha256,
}) =>
    Uint8List.fromList(utf8.encode(buildWorkerManifest(
      base: base,
      workerSize: workerSize,
      workerSha256: workerSha256,
    )));
