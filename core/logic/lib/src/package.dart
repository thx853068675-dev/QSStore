// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 轻启安装包结构检查。
//
// 与旧实现 QuietStartPackage 的差异：旧版需要「整个包的字节」作为输入，因此
// 调用方必须先 readAsBytes()。这里入参是文件，检查所需的数据只有三类：
//   · module.json          —— 小
//   · 工作模块清单 json     —— 小
//   · 工作模块 HAP 本身     —— 受 workerPayloadLimit（16 MB）约束
// 主包体（可能几百 MB）自始至终不进入内存。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'hap_zip.dart';

const workerPath = 'resources/rawfile/quietstart-worker.hap';
const manifestPath = 'resources/rawfile/quietstart-worker.json';
const bundleName = 'com.tonghongxiang.quietstart';

/// 主模块名与工作模块名，用于校验内外一致。
const mainModuleName = 'entry';
const workerModuleName = 'entry_test';

/// 包结构信息。只持有小数据，不持有主包体。
class PackageInfo {
  PackageInfo._({
    required this.reader,
    required this.main,
    required this.worker,
    required this.manifest,
    required this.workerPayload,
  });

  final HapReader reader;
  final Map<String, dynamic> main;
  final Map<String, dynamic> worker;
  final Map<String, dynamic> manifest;

  /// 工作模块的**未压缩**内容（≤ workerPayloadLimit）。
  final Uint8List workerPayload;

  String get workerBundleName => (worker['app'] as Map)['bundleName'] as String;

  int get workerMinApi => (worker['app'] as Map)['minAPIVersion'] as int;

  int get mainMinApi => (main['app'] as Map)['minAPIVersion'] as int;

  Future<void> close() => reader.close();

  /// 检查文件是否轻启安装包。
  ///
  /// 返回 null 表示「不是轻启包」（bundleName 不匹配）——这是正常结果，
  /// 调用方应回退到普通签名流程。结构损坏则抛 [HapFormatException]。
  ///
  /// 注意：无论成功、返回 null 还是抛异常，HapReader 都已正确释放；
  /// 成功时由调用方通过 [close] 释放。
  static Future<PackageInfo?> inspect(File file) async {
    final reader = await HapReader.open(file);
    var keepOpen = false;
    try {
      final mainEntry = reader.find('module.json');
      final manifestEntry = reader.find(manifestPath);
      final payloadEntry = reader.find(workerPath);
      if (mainEntry == null || manifestEntry == null || payloadEntry == null) {
        return null;
      }
      if (payloadEntry.uncompressedSize > workerPayloadLimit) {
        throw const HapFormatException('轻启工作模块超出内置上限，请重新下载完整安装包');
      }

      final mainRaw = jsonDecode(utf8.decode(await reader.readDecoded(mainEntry)));
      if (mainRaw is! Map<String, dynamic>) {
        throw const HapFormatException('安装包 module.json 结构无效');
      }
      if ((mainRaw['app'] as Map?)?['bundleName'] != bundleName) return null;

      final manifestRaw =
          jsonDecode(utf8.decode(await reader.readDecoded(manifestEntry)));
      if (manifestRaw is! Map<String, dynamic>) {
        throw const HapFormatException('安装包清单结构无效');
      }
      final payload = await reader.readDecoded(payloadEntry);

      if (payload.length < 1024 ||
          payload.length > workerPayloadLimit ||
          manifestRaw['size'] != payload.length ||
          manifestRaw['sha256'] != sha256.convert(payload).toString()) {
        throw const HapFormatException('轻启工作模块缺失或摘要不符，请重新下载完整安装包');
      }

      // 工作模块本身是一个小 HAP，可以安全地整块解析。
      // 先在内存中校验其结构，再决定是否落临时文件。
      final worker =
          await _decodeInnerMain(payload, manifestRaw, mainRaw);

      final result = PackageInfo._(
        reader: reader,
        main: mainRaw,
        worker: worker,
        manifest: manifestRaw,
        workerPayload: payload,
      );
      keepOpen = true;
      return result;
    } finally {
      if (!keepOpen) await reader.close();
    }
  }

  /// 解析工作模块（内嵌 HAP）并校验内外一致性。
  static Future<Map<String, dynamic>> _decodeInnerMain(
    Uint8List payload,
    Map<String, dynamic> manifest,
    Map<String, dynamic> main,
  ) async {
    // 内嵌 HAP 很小，落到临时文件后复用同一套随机访问解析器，
    // 避免为「读内存中的 ZIP」再写一份解析实现。
    final dir = await Directory.systemTemp.createTemp('qs-inner-');
    try {
      final f = File(p.join(dir.path, 'worker.hap'));
      await f.writeAsBytes(payload, flush: true);
      final inner = await HapReader.open(f);
      try {
        final innerMain = inner.find('module.json');
        if (innerMain == null) {
          throw const HapFormatException('工作模块缺少 module.json');
        }
        final workerRaw =
            jsonDecode(utf8.decode(await inner.readDecoded(innerMain)));
        if (workerRaw is! Map<String, dynamic>) {
          throw const HapFormatException('工作模块结构无效');
        }

        // 工作模块内不得再嵌套一份工作模块（防递归嵌入）。
        for (final e in inner.entries) {
          if (e.name.endsWith('quietstart-worker.hap') ||
              e.name.endsWith('quietstart-worker.json')) {
            throw const HapFormatException('工作模块内不得再嵌套工作模块');
          }
        }

        // 内外一致性：名称、bundle、版本号必须完全对齐。
        if ((main['module'] as Map?)?['name'] != mainModuleName ||
            (workerRaw['module'] as Map?)?['name'] != workerModuleName ||
            manifest['moduleName'] != workerModuleName ||
            (workerRaw['app'] as Map?)?['bundleName'] != bundleName ||
            manifest['bundleName'] != bundleName ||
            (main['app'] as Map?)?['versionCode'] !=
                (workerRaw['app'] as Map?)?['versionCode'] ||
            (main['app'] as Map?)?['versionCode'] != manifest['versionCode']) {
          throw const HapFormatException('轻启主包、工作模块的名称或版本不一致');
        }

        for (final module in [main, workerRaw]) {
          final minApi = (module['app'] as Map?)?['minAPIVersion'];
          if (minApi is! int || minApi <= 0) {
            throw const HapFormatException('安装包 API 版本无效');
          }
        }
        return workerRaw;
      } finally {
        await inner.close();
      }
    } finally {
      // 临时目录用完即删；失败时也删，避免沙箱内堆积。
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不应覆盖真正的错误。
      }
    }
  }
}

/// 从 HAP 文件中提取 `module.json` 声明的权限名。
///
/// 用途：创建调试 Profile 时，AGC 需要知道包声明了哪些权限，
/// 才能把「包内声明 ∩ 可授权白名单」作为 aclPermissionList 提交。
/// 这必须在**签名之前**做 —— Profile 是签名的输入之一。
///
/// 不是轻启包、或文件损坏时返回空列表（不抛异常）：
/// 权限信息缺失只会影响 ACL 授权范围，不应阻断安装流程。
Future<List<String>> readDeclaredPermissions(File hap) async {
  HapReader? reader;
  try {
    reader = await HapReader.open(hap);
    final entry = reader.find('module.json');
    if (entry == null) return const [];
    final json = jsonDecode(utf8.decode(await reader.readDecoded(entry)));
    if (json is! Map<String, dynamic>) return const [];
    return extractRequestedPermissionsFrom(json);
  } catch (_) {
    return const [];
  } finally {
    await reader?.close();
  }
}

/// 从已解析的 `module.json` 结构中取出权限名列表。
List<String> extractRequestedPermissionsFrom(Map<String, dynamic> moduleJson) {
  final module = moduleJson['module'];
  if (module is! Map) return const [];
  final perms = module['requestPermissions'];
  if (perms is! List) return const [];
  final out = <String>[];
  for (final p in perms) {
    if (p is Map && p['name'] is String) out.add(p['name'] as String);
  }
  return out;
}

/// 把内存中的 HAP 字节写到临时文件后解析（供测试与小数据场景使用）。
Future<HapReader> openMemoryHap(Uint8List bytes, {Directory? into}) async {
  final dir = into ?? await Directory.systemTemp.createTemp('qs-mem-');
  final f = File(p.join(dir.path, 'mem-${DateTime.now().microsecondsSinceEpoch}.hap'));
  await f.writeAsBytes(bytes, flush: true);
  return HapReader.open(f);
}
