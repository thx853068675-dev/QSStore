// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 平台能力实现 —— 把签名核心的抽象契约接到鸿蒙原生能力上。
//
// 三个接点：
//   1) sign      → ohosAdapter.signCmd('signtool sign-app ...')
//                  原生 libsigner.so（Go 编译）在设备内执行签名
//   2) install   → ohosAdapter.hdcCmd('hdc install ...')
//                  原生 libhdc_z.so 负责设备通道
//   3) workDir   → ohosAdapter.tempDir()
//
// 之所以全部走 ohos_adapter 的方法通道而不是直接在 Dart 里做：
// 签名与 HDC 都是原生实现，且 hdc 需要常驻服务（startServer）。

import 'dart:io';

import 'package:ohos_adapter/ohos_adapter.dart';
import 'package:path/path.dart' as p;
import 'package:signing_core/signing_core.dart';

import 'install_coordinator.dart';
import 'sign_material_store.dart';
import 'wireless_debug.dart';

/// 准备流程需要的平台能力（抽象出来便于测试注入替身）。
abstract class SetupPlatform {
  /// 启动内置 HDC 服务
  Future<void> startHdcServer();

  /// 无线调试连接器
  WirelessDebugger wireless({void Function(String msg)? onProgress});

  /// 跳转系统设置页（developer / wireless / app）
  Future<bool> openSystemSettings(String page);

  /// 读取本机 UDID
  Future<String?> deviceUdid();

  /// 生成唯一密钥对
  Future<bool> generateKeyPair({
    required String keystorePath,
    required String keyAlias,
    required String password,
  });

  /// 生成 CSR
  Future<String?> generateCsr({
    required String keystorePath,
    required String outPath,
    required String keyAlias,
    required String password,
    required String subject,
  });
}

class OhosInstallPlatform extends InstallPlatform implements SetupPlatform {
  OhosInstallPlatform({required this.materials, this.requestReconnect});

  final SignMaterialStore materials;
  final Future<bool> Function()? requestReconnect;

  @override
  Future<bool> ensureInstallConnection() async {
    await startHdcServer();
    if (await wireless().hasLiveConnection()) return true;
    return await requestReconnect?.call() ?? false;
  }

  /// 原生签名器路径（设备内）
  static const _signerCmd = 'signtool';

  @override
  Future<Directory> workDir() async {
    final base = await ohosAdapter.tempDir() ?? Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'hapstore'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<void> sign(File input, File target, int minimumApi) async {
    final cfg = materials.config;
    if (await target.exists()) await target.delete();

    // 密钥库口令：
    //   · 商店自动生成的密钥对是 PKCS12，用真实口令
    //   · 用户从外部导入的可能是未加密 PEM，签名器约定传占位口令
    final pwd = cfg.keystorePwd.isNotEmpty
        ? cfg.keystorePwd
        : 'unused-for-unencrypted-pem';

    // 参数与现有小白一致：libsigner.so 的 CLI 契约
    final cmd = '$_signerCmd sign-app -mode localSign '
        '-keyAlias ${cfg.keyAlias} '
        '-appCertFile ${cfg.certPath} '
        '-profileFile ${cfg.profilePath} '
        '-keystoreFile ${cfg.keystoreFile} '
        '-keystorePwd $pwd '
        '-keyPwd $pwd '
        '-signAlg SHA256withECDSA '
        '-compatibleVersion $minimumApi '
        '-signCode 1 '
        '-inFile ${input.path} -outFile ${target.path}';

    final result = await ohosAdapter.signCmd(cmd) ?? '';
    // 原生签名器存在「失败也返回 0」的情况，因此同时检查产物。
    final claimedOk =
        result.contains('success') || result.contains('签名成功');
    if (!claimedOk || !await target.exists() || await target.length() < 1024) {
      throw StateError('签名失败：${result.trim().isEmpty ? "签名器无输出" : result.trim()}');
    }
  }

  @override
  Future<String?> install(String hapPath) async {
    if (!await File(hapPath).exists()) return '文件不存在：$hapPath';

    // The debugging service can restart while a large HAP is signing. Keep
    // the signed file and resume this exact installation after reconnection.
    if (!await ensureInstallConnection()) return '未连接无线调试，安装已取消';

    final result = await ohosAdapter.hdcCmd('hdc install "$hapPath"') ?? '';
    if (result.contains('install bundle successfully') &&
        !result.contains('[Fail]')) {
      return null;
    }
    // 复用核心的结构化错误码归类
    final failure = classifyInstallError(result);
    return failure.toString();
  }

  @override
  Future<String?> deviceUdid() async {
    try {
      // bm get --udid 输出形如 "udid of current device is :\n<64位hex>"
      final out = await ohosAdapter.hdcCmd('hdc shell bm get --udid') ?? '';
      final m = RegExp(r'\b([0-9A-Fa-f]{40,})\b').firstMatch(out);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  @override
  ProfileProvider? profileProvider() => materials.provider;

  // ────────────── 设备通道 ──────────────

  /// 启动内置 HDC 服务（连接设备前后台通道）。
  Future<void> startHdcServer() async {
    try {
      await ohosAdapter.startServer();
    } catch (_) {
      // 已启动时会抛错，忽略
    }
  }

  /// 执行 hdc 命令。
  Future<String> runHdc(String cmd) async => await ohosAdapter.hdcCmd(cmd) ?? '';

  /// 跳转系统设置页。
  ///
  /// 实现照搬轻启 0.9.51（`entry/src/main/ets/pages/Index.ets` 的
  /// `openSystemSettings` / `openDeveloperSetup`）。要点：
  ///
  ///   bundleName  = com.huawei.hmos.settings
  ///   abilityName = com.huawei.hmos.settings.MainAbility
  ///   uri         = system_wireless_commissioning   → 无线调试
  ///                 about_device                     → 关于本机
  ///   action      = ohos.want.action.viewData
  ///
  /// **四个都要给。** 只给 uri/action 时系统会回 "start ability successfully"
  /// 但实际不打开任何页面（我踩过这个坑）；只给 bundle+ability 也不行。
  ///
  /// 已在设备上验证：调用后前台变为
  /// `com.huawei.hmos.settings:phone_settings:...MainAbility`。
  Future<bool> openSystemSettings(String page) async {
    const bundle = 'com.huawei.hmos.settings';
    const ability = 'com.huawei.hmos.settings.MainAbility';

    final uri = page == 'developer' ? 'about_device' : 'system_wireless_commissioning';

    try {
      final ok = await ohosAdapter.startWant(bundle, ability, uri);
      await ohosAdapter.log('[settings] startWant uri=$uri → $ok');
      if (ok) return true;
    } catch (e) {
      try {
        await ohosAdapter.log('[settings] startWant uri=$uri 异常：$e');
      } catch (_) {}
    }

    // 退一步：只给 bundle + ability（打开设置首页，由用户自己找）
    try {
      final ok = await ohosAdapter.startWant(bundle, ability, '');
      await ohosAdapter.log('[settings] 退到设置首页 → $ok');
      if (ok) return true;
    } catch (_) {}

    return false;
  }

  /// 无线调试连接器。
  ///
  /// 排除本应用自己的服务端口（避免把商店的端口误判成调试端口），
  /// 并把探测过程写进 hilog —— 真机上这是唯一可用的排查手段。
  WirelessDebugger wireless({
    void Function(String msg)? onProgress,
  }) =>
      WirelessDebugger(
        runHdc: runHdc,
        onProgress: onProgress,
        log: (m) async {
          try {
            await ohosAdapter.log('[wireless] $m');
          } catch (_) {}
        },
      );

  // ────────────── 密钥对与 CSR 的本地生成 ──────────────
  //
  // 这是「一键登录、无需手动导入」的关键一环。
  //
  // 原「小白」把 key.pem 与 xiaobai.csr 作为**随包资源**分发，所有用户
  // 共用同一把私钥 —— 那是一个严重的安全问题（见 docs/SIGNING-CORE.md）。
  // 正确做法是每台设备生成**唯一**密钥对，这里用内置的原生签名器完成，
  // 不依赖 OpenSSL（手机上没有）。

  /// 生成唯一密钥对（PKCS12 格式），返回是否成功。
  ///
  /// 参数取自签名器的 CLI 契约，算法与 AGC 要求一致（ECC NIST-P-256）。
  Future<bool> generateKeyPair({
    required String keystorePath,
    required String keyAlias,
    required String password,
  }) async {
    final f = File(keystorePath);
    if (await f.exists()) await f.delete();
    await f.parent.create(recursive: true);

    final cmd = '$_signerCmd generate-keypair '
        '-keyAlias $keyAlias '
        '-keyAlg ECC -keySize NIST-P-256 '
        '-keystoreFile $keystorePath '
        '-keystorePwd $password '
        '-keyPwd $password';

    // 原生签名器存在「失败也返回 0」的情况，因此以产物为准。
    // 但原始返回是排查的唯一线索，必须记下来。
    final raw = await ohosAdapter.signCmd(cmd) ?? '';
    var ok = await f.exists() && await f.length() > 256;

    // 签名器是独立进程、可能写到了自己的当前目录。若目标路径没有，
    // 就在可能的位置里找一找 —— 找到就认账，避免把成功当失败。
    String found = '';
    if (!ok) {
      for (final cand in _keypairCandidates(keystorePath, keyAlias)) {
        final g = File(cand);
        try {
          if (await g.exists() && await g.length() > 256) {
            found = cand;
            ok = true;
            // 移到期望位置，后续流程按约定路径使用
            try {
              await g.copy(keystorePath);
            } catch (_) {}
            break;
          }
        } catch (_) {}
      }
    }

    try {
      final dir = Directory(p.dirname(keystorePath));
      List<String> listing;
      try {
        final all = await dir.list().toList();
        final parts = <String>[];
        for (final e in all) {
          if (e is File) {
            var n = 0;
            try {
              n = await e.length();
            } catch (_) {}
            parts.add('${p.basename(e.path)}(${n}B)');
          } else {
            parts.add('${p.basename(e.path)}/');
          }
        }
        listing = parts;
      } catch (e) {
        listing = ['<无法列出: $e>'];
      }
      // 也看系统临时目录 —— 签名器可能写在自己进程的 cwd
      String tmpListing;
      try {
        final t = await Directory.systemTemp.list().take(20).toList();
        tmpListing = t.map((e) => p.basename(e.path)).toList().toString();
      } catch (e) {
        tmpListing = '<无法列出: $e>';
      }
      await ohosAdapter.log('[signer] keypair ok=$ok found="$found"');
      await ohosAdapter.log('[signer]   dir=${dir.path} 内容=$listing');
      await ohosAdapter.log('[signer]   systemTemp=${Directory.systemTemp.path} 内容=$tmpListing');
      await ohosAdapter.log('[signer]   rawOut="${raw.replaceAll("\n", " ")}"');
    } catch (_) {}
    return ok;
  }

  /// 用已有密钥对生成 CSR（提交给 AGC 换证书）。
  Future<String?> generateCsr({
    required String keystorePath,
    required String outPath,
    required String keyAlias,
    required String password,
    required String subject,
  }) async {
    final out = File(outPath);
    if (await out.exists()) await out.delete();

    final cmd = '$_signerCmd generate-csr '
        '-keyAlias $keyAlias '
        '-subject "$subject" '
        '-signAlg SHA256withECDSA '
        '-keystoreFile $keystorePath '
        '-keystorePwd $password '
        '-keyPwd $password '
        '-outFile $outPath';

    final rawCsr = await ohosAdapter.signCmd(cmd) ?? '';
    final okCsr = await out.exists() && await out.length() >= 64;
    try {
      await ohosAdapter.log('[signer] generate-csr ok=$okCsr '
          'out=${rawCsr.length > 300 ? rawCsr.substring(0, 300) : rawCsr}');
    } catch (_) {}
    if (!okCsr) return null;
    return out.readAsString();
  }

  /// 密钥库可能的落点。
  ///
  /// 签名器是独立进程，可能相对自己的当前目录写文件，而不是我们给的
  /// 绝对路径（其实测返回「签名成功」但目标路径没有文件）。
  /// 找到就认账并搬回约定位置，避免把成功误判为失败。
  List<String> _keypairCandidates(String expected, String alias) {
    final names = <String>[
      p.basename(expected),
      '$alias.jks',
      '$alias.p12',
      '$alias.keystore',
    ];
    final dirs = <String>[
      p.dirname(expected),
      Directory.systemTemp.path,
      '${Directory.systemTemp.path}/hapstore',
      '.',
    ];
    final out = <String>[];
    for (final d in dirs) {
      for (final n in names) {
        out.add(p.join(d, n));
      }
    }
    return out;
  }
}
