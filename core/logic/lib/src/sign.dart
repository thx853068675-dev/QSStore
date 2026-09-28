// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 签名端到端主入口。
//
// ── 与原 quietstart_signing.dart 的关系 ─────────────────────────────────
// 保留的三条不变量（这些是原实现真正有价值的部分）：
//   1) 内外模块分层重签：工作模块先签，再把它的新摘要回填进主包清单
//   2) 「载荷未变」校验：签名器若改动了程序内容立即中止
//   3) Profile 三元一致：主包与工作模块必须使用同一次设备授权
//
// 去掉的东西：
//   · 整包入内存（改为文件到文件 + 流式重打包）
//   · 64 MB 大小上限（9 处检查随之取消）
//   · zipView() 的中央目录重建绕行（自研随机访问解析后不再需要）
//
// ── 顺带修掉的一个真实缺陷 ─────────────────────────────────────────────
// 原实现的输出文件有两个写入点：`resignQuietStart` 内部先写一次，
// `QuietStartAdapter` 在调用前又删一次。若照搬这个调用次序，本实现里
// 「输出已存在」的守卫会被触发，导致签名失败。这里统一为：由本函数
// **独占**负责输出的创建与原子落盘，调用方不再预处理输出文件。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'hap_zip.dart';
import 'manifest.dart';
import 'package.dart';
import 'native_lib_pad.dart';
import 'provision.dart';
import 'verify.dart';
import 'zip_stream.dart';

/// 签名器调用契约：把 [input] 签成 [target]，最低 API 版本为 [minimumApi]。
///
/// 平台差异全部收敛到这个回调里：
///   · HarmonyOS 走 ohos_adapter 的 signCmd（NAPI → 原生 Go signer）
///   · 桌面走内置 signer 可执行文件
typedef SignerRunner = Future<void> Function(
  File input,
  File target,
  int minimumApi,
);

typedef SignProgress = void Function(String message);

/// 签名结果。
class SignResult {
  const SignResult({
    required this.handled,
    this.isQuietStartPackage = false,
    this.message,
    this.outputPath,
    this.provisioningAttempts = const [],
  });

  /// 是否已由本核心处理完成。
  ///
  /// 为 false 表示「不是轻启包」，调用方应回退到普通单包签名流程。
  final bool handled;

  /// 是否走了「轻启整包分层重签」路径。
  final bool isQuietStartPackage;

  /// 失败原因（handled 为 true 时为 null）。
  final String? message;

  /// 成功时的产物路径。
  final String? outputPath;

  /// 设备授权（Profile）的处理记录。
  ///
  /// 非空表示本次走过了「判定 → 可能重建 → 复验」流程，
  /// 可用于向用户说明「已自动更新设备授权」，而不是让他去重置证书。
  final List<EnsureProfileAttempt> provisioningAttempts;

  /// 本次是否自动重建过设备授权。
  bool get didRegenerate => provisioningAttempts.any((a) => a.regenerated);

  bool get succeeded => handled && message == null;

  @override
  String toString() => 'SignResult(handled=$handled, ok=$succeeded, '
      'message=$message, output=$outputPath)';
}

/// 对一个 HAP 执行签名。
///
/// [input] 待签文件（不会被修改）
/// [output] 产物路径（由本函数独占管理）
/// [profileBytes] 设备授权 Profile 的字节内容
/// [sign] 平台签名器回调
/// [profileRequest] + [profileProvider] 若同时提供，则在 Profile 不适用于
///   当前设备时**自动重建**（见 provision.dart）。此时 [profileBytes] 可传
///   空数组，实际使用的 Profile 以 provider 返回的为准。
///
/// 若 [input] 不是轻启包，返回 `handled: false`，调用方应改用普通签名流程。
Future<SignResult> signHap({
  required File input,
  required File output,
  required Uint8List profileBytes,
  required SignerRunner sign,
  required SignProgress progress,
  ProfileRequest? profileRequest,
  ProfileProvider? profileProvider,
}) async {
  if (!await input.exists()) {
    return SignResult(handled: true, message: '文件不存在：${input.path}');
  }
  if (p.equals(p.absolute(input.path), p.absolute(output.path))) {
    return const SignResult(handled: true, message: '不能覆盖原包');
  }

  // ── 阶段 0：确保 Profile 适用于当前设备（自动重建）────────────────
  // 这一步替换了原实现「文件存在就复用」的错误判据，是消灭 9568423 的关键。
  Uint8List effectiveProfile = profileBytes;
  List<EnsureProfileAttempt> provisioningAttempts = const [];
  if (profileRequest != null && profileProvider != null) {
    final ensured = await ensureUsableProfile(
      request: profileRequest,
      provider: profileProvider,
    );
    provisioningAttempts = ensured.attempts;
    if (!ensured.ok) {
      return SignResult(
        handled: true,
        message: '设备授权获取失败：${ensured.error ?? "未知原因"}',
        provisioningAttempts: provisioningAttempts,
      );
    }
    effectiveProfile = ensured.bytes!;
    if (ensured.didRegenerate) {
      progress('已自动更新设备授权 Profile');
    }
  }

  // 输出由本函数独占管理：清理残留后原子落盘。
  if (await output.exists()) {
    await output.delete();
  }
  await output.parent.create(recursive: true);

  PackageInfo? info;
  try {
    info = await PackageInfo.inspect(input);
  } on HapFormatException catch (e) {
    return SignResult(handled: true, message: '轻启整包签名失败：${e.message}');
  }

  if (info == null) {
    // 不是轻启包 —— 交给调用方的普通签名流程。
    return const SignResult(handled: false);
  }

  try {
    return await _resign(
      info: info,
      output: output,
      profileBytes: effectiveProfile,
      sign: sign,
      progress: progress,
      provisioningAttempts: provisioningAttempts,
    );
  } on HapFormatException catch (e) {
    return SignResult(
      handled: true,
      isQuietStartPackage: true,
      message: '轻启整包签名失败：${e.message}',
    );
  } catch (e) {
    return SignResult(
      handled: true,
      isQuietStartPackage: true,
      message: '轻启整包签名失败：$e',
    );
  } finally {
    await info.close();
  }
}

Future<SignResult> _resign({
  required PackageInfo info,
  required File output,
  required Uint8List profileBytes,
  required SignerRunner sign,
  required SignProgress progress,
  List<EnsureProfileAttempt> provisioningAttempts = const [],
}) async {
  // 临时目录与输出同目录：手机沙箱里跨分区 rename 可能失败。
  final temporary = await Directory(
    p.join(output.parent.path,
        'quietstart-resign-${DateTime.now().microsecondsSinceEpoch}'),
  ).create(recursive: true);

  var succeeded = false;
  try {
    // ── 1/3 重签工作模块 ──────────────────────────────────────────────
    // 工作模块受 workerPayloadLimit 约束，可以安全地在内存中处理。
    final wi = File(p.join(temporary.path, 'worker-unsigned.hap'));
    final wo = File(p.join(temporary.path, 'worker-signed.hap'));
    await wi.writeAsBytes(info.workerPayload, flush: true);

    progress('1/3 重签工作模块');
    await sign(wi, wo, info.workerMinApi);
    if (!await wo.exists()) {
      throw const HapFormatException('签名器未生成工作模块');
    }

    // 不变量 1：工作模块载荷未变。
    final signedWorker = await wo.readAsBytes();
    await _checkWorkerPayload(info.workerPayload, wo);

    // 不变量 2：工作模块使用本次的设备授权 Profile。
    if (!bytesEqual(await signedProfileOf(wo), profileBytes)) {
      throw const HapFormatException('工作模块未使用本次的设备授权 Profile');
    }

    // ── 2/3 重签主包 ────────────────────────────────────────────────
    final replacements = <String, Uint8List>{
      workerPath: signedWorker,
      manifestPath: buildWorkerManifestBytes(
        base: info.manifest,
        workerSize: signedWorker.length,
        workerSha256: sha256Hex(signedWorker),
      ),
    };
    // 顺带修补尺寸过小的原生库，否则手机侧签名器会崩溃
    // （根因与实测边界见 native_lib_pad.dart）
    await _collectNativeLibPadding(info, replacements);

    final mi = File(p.join(temporary.path, 'main-unsigned.hap'));
    await streamRepack(source: info.reader, target: mi, replacements: replacements);

    progress('2/3 重签轻启主包');
    final mo = File(p.join(temporary.path, 'main-signed.hap'));
    await sign(mi, mo, info.mainMinApi);
    if (!await mo.exists()) {
      throw const HapFormatException('签名器未生成主包');
    }

    // ── 3/3 校验内外模块与安装内容 ──────────────────────────────────
    progress('3/3 检查内外模块与安装内容');
    await checkPayloadUnchanged(
      original: info.reader,
      result: mo,
      replacements: replacements,
    );
    if (!bytesEqual(await signedProfileOf(mo), profileBytes)) {
      throw const HapFormatException('主包与工作模块的设备授权不一致');
    }

    // 结构自检：产物必须仍是合法轻启包。
    final signedInfo = await PackageInfo.inspect(mo);
    if (signedInfo == null) {
      throw const HapFormatException('重签后的包 bundle 标识不符');
    }
    await signedInfo.close();

    // ── 交付 ────────────────────────────────────────────────────────
    // rename 在同一文件系统内是原子操作，安装流程不会看到半成品。
    await mo.rename(output.path);
    succeeded = true;
    return SignResult(
      handled: true,
      isQuietStartPackage: true,
      outputPath: output.path,
      provisioningAttempts: provisioningAttempts,
    );
  } finally {
    if (succeeded) {
      try {
        await temporary.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结果。
      }
    }
    // 失败时保留临时目录，便于排查；由系统清理策略回收。
  }
}

/// 普通 HAP 单包签名（非轻启整包场景）。
///
/// 这是 `signHap` 返回 `handled: false` 时的回退路径：包内没有内嵌工作模块，
/// 直接交给签名器即可。
///
/// 与轻启整包路径共用同一套输出管理约定（本函数独占输出、原子落盘）。
Future<SignResult> signPlain({
  required File input,
  required File output,
  required int minimumApi,
  required SignerRunner sign,
  bool verifyPayload = true,
}) async {
  if (!await input.exists()) {
    return SignResult(handled: true, message: '文件不存在：${input.path}');
  }
  if (p.equals(p.absolute(input.path), p.absolute(output.path))) {
    return const SignResult(handled: true, message: '不能覆盖原包');
  }
  if (await output.exists()) await output.delete();
  await output.parent.create(recursive: true);

  final staging = File('${output.path}.signing');
  if (await staging.exists()) await staging.delete();

  final temporary = await Directory.systemTemp.createTemp('hapstore-plain-');
  try {
    // ── 0/2 修补过小的原生库 ──────────────────────────────────────
    // 普通包也要做：手机侧签名器遇到 <169KB 的原生库会崩溃。
    // 不需要修补时直接签原包，避免无谓的重打包。
    File toSign = input;
    final replacements = <String, Uint8List>{};
    {
      final reader = await HapReader.open(input);
      try {
        for (final entry in reader.entries) {
          if (!isNativeLibEntry(entry.name)) continue;
          if (paddingFor(entry.name, entry.uncompressedSize) == 0) continue;
          final bytes = await reader.readDecoded(entry);
          final padded = padIfNeeded(entry.name, bytes);
          if (padded.length != bytes.length) {
            replacements[entry.name] = padded;
          }
        }
      } finally {
        await reader.close();
      }

      if (replacements.isNotEmpty) {
        final repacked = File(p.join(temporary.path, 'padded.hap'));
        final src = await HapReader.open(input);
        try {
          await streamRepack(
              source: src, target: repacked, replacements: replacements);
        } finally {
          await src.close();
        }
        toSign = repacked;
      }
    }

    await sign(toSign, staging, minimumApi);
    if (!await staging.exists() || await staging.length() < 1024) {
      return const SignResult(
          handled: true, message: '签名器未生成有效产物');
    }

    // 产物必须是可解析的 ZIP，否则说明签名器写坏了。
    final signed = await HapReader.open(staging);
    try {
      if (signed.entries.isEmpty) {
        return const SignResult(handled: true, message: '签名产物为空包');
      }
    } finally {
      await signed.close();
    }

    // 载荷未变校验：普通包同样不能容忍程序内容被改动。
    if (verifyPayload) {
      final original = await HapReader.open(input);
      try {
        await checkPayloadUnchanged(
          original: original,
          result: staging,
          // 原生库填充是我们有意做的改动，必须如实告知校验器，
          // 否则会被「内容被改动」拦下（这层防护本身是对的）。
          replacements: replacements,
          // 普通 HAP 可能很大，深度比对只覆盖小条目；
          // 大条目由「尺寸一致」把守。
          deepCheckLimit: 4 * 1024 * 1024,
        );
      } finally {
        await original.close();
      }
    }

    await staging.rename(output.path);
    return SignResult(
      handled: true,
      isQuietStartPackage: false,
      outputPath: output.path,
    );
  } on HapFormatException catch (e) {
    return SignResult(handled: true, message: '签名失败：${e.message}');
  } catch (e) {
    return SignResult(handled: true, message: '签名失败：$e');
  } finally {
    if (await staging.exists()) {
      try {
        await staging.delete();
      } catch (_) {}
    }
    // 清理为「修补原生库」而建的临时目录
    try {
      await temporary.delete(recursive: true);
    } catch (_) {}
  }
}

/// 校验签名器没有改变工作模块的程序内容。
///
/// 工作模块很小（≤ workerPayloadLimit），因此把深度比对阈值拉满，
/// 让**每个条目都做完整内容比对**，不依赖 CRC 之类的廉价判据。
Future<void> _checkWorkerPayload(
    Uint8List original, File resultFile) async {
  final before = await openMemoryHap(original);
  try {
    await checkPayloadUnchanged(
      original: before,
      result: resultFile,
      deepCheckLimit: workerPayloadLimit * 2,
    );
  } finally {
    await before.close();
  }
}

/// 收集需要修补的原生库，把补齐后的字节放进 [replacements]。
///
/// 手机侧签名器（Go 版 hapsigner）对 <169KB 的原生库会崩溃，
/// 详见 `native_lib_pad.dart`。这里在重打包阶段顺手补齐，
/// 使下游签名器不再遇到触发条件。
///
/// 读取失败不应阻断签名流程 —— 补不上只是让签名器可能崩，
/// 而在这里抛异常会让**所有**安装都失败。
Future<void> _collectNativeLibPadding(
  PackageInfo info,
  Map<String, Uint8List> replacements,
) async {
  try {
    for (final entry in info.reader.entries) {
      if (!isNativeLibEntry(entry.name)) continue;
      if (paddingFor(entry.name, entry.uncompressedSize) == 0) continue;
      final bytes = await info.reader.readDecoded(entry);
      final padded = padIfNeeded(entry.name, bytes);
      if (padded.length != bytes.length) {
        replacements[entry.name] = padded;
      }
    }
  } catch (_) {
    // 保持签名流程可继续
  }
}
