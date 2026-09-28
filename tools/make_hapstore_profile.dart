// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 为 com.tonghongxiang.hapstore 生成**与 key.pem 严格配对**的调试证书与 Profile。
//
// ── 为什么需要这个脚本 ────────────────────────────────────────────────
// 设备侧安装要求「签名私钥 ↔ 证书 ↔ Profile」三者配对。历史问题正是这里断链：
//   · Profile 绑定的证书不是 key.pem 换来的那张
//   · 于是签名「成功」，装到设备却报 9568322 / 签名校验失败
// 本脚本用 **key.pem 对应的 CSR**（xiaobai.csr）去 AGC 换证，再用该证书建
// Profile，最后**本地复验**配对关系，确保交付物可用。
//
// 用法（在 app/ 目录下运行，才能解析 package: 依赖）：
//   cd app
//   dart run ../tools/make_hapstore_profile.dart list                 # 仅列出 AGC 证书
//   dart run ../tools/make_hapstore_profile.dart <UDID> [输出目录]
//
// 可选参数：
//   --csr <path>   证书请求（默认 ~/Documents/hap_installer/store/xiaobai.csr）
//   --key <path>   与该 CSR 配对的私钥（默认 .../key.pem）
//
// 产物（默认写到 ~/Documents/hap_installer/store/）：
//   hapstore-debug.cer                —— 与 key.pem 配对的证书链
//   com_tonghongxiang_hapstore.p7b    —— 绑 hapstore 包名与本机 UDID 的 Profile

import 'dart:convert';
import 'dart:io';

import '../app/lib/state/agc/agc_models.dart';
import '../app/lib/state/agc/agc_service.dart';
import '../app/lib/state/identity_generator.dart';

const String kBundleName = 'com.tonghongxiang.hapstore';
const String kCertName = 'hapstore-desktop-debug';
const String kProfileName = 'hapstore-desktop_com_tonghongxiang_hapstore';

Future<int> _fail(String msg) async {
  stderr.writeln('✗ $msg');
  return 1;
}

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME']!;
  final store = '$home/Documents/hap_installer/store';

  final rest = <String>[];
  var csrPath = '$store/xiaobai.csr';
  var keyPath = '$store/key.pem';
  var outDir = store;
  var allowNewCert = false;
  var bundleName = kBundleName;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--csr' && i + 1 < args.length) {
      csrPath = args[++i];
    } else if (a == '--key' && i + 1 < args.length) {
      keyPath = args[++i];
    } else if (a == '--allow-new-cert') {
      allowNewCert = true;
    } else if (a == '--bundle' && i + 1 < args.length) {
      bundleName = args[++i];
    } else {
      rest.add(a);
    }
  }
  if (rest.isNotEmpty && rest.length >= 2) outDir = rest[1];
  final mode = rest.isNotEmpty ? rest[0] : '';
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
      .hasMatch(bundleName)) {
    exitCode = await _fail('无效的 HAP 包名');
    return;
  }
  final udids = mode == 'list'
      ? <String>[]
      : mode.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  if (!await File(csrPath).exists()) {
    exitCode = await _fail('找不到 CSR：$csrPath');
    return;
  }
  if (!await File(keyPath).exists()) {
    exitCode = await _fail('找不到私钥：$keyPath');
    return;
  }

  // 私钥对应的公钥点（用于后续配对复验）。
  final keyPem = await File(keyPath).readAsString();

  // ── 1. 恢复华为登录态 ────────────────────────────────────────────
  final authFile = File('$home/Documents/hap_installer/userInfo.json');
  if (!await authFile.exists()) {
    exitCode = await _fail('找不到登录态：${authFile.path}\n'
        '  请先用小白/商店 App 登录一次华为账号');
    return;
  }
  final auth = AuthInfo.fromJson(
      jsonDecode(await authFile.readAsString()) as Map<String, dynamic>);
  final agc = AgcService()..initUserInfo(auth);

  if (!await agc.checkSignedIn() || !agc.isSignedIn) {
    exitCode = await _fail('登录态已失效（尝试刷新也失败），请重新登录');
    return;
  }
  stdout.writeln('✓ 登录态有效：${agc.authInfo?.nickName ?? agc.authInfo?.userId}');
  // checkSignedIn 可能已静默刷新 token —— 写回，供后续复用。
  await authFile.writeAsString(jsonEncode(agc.authInfo!.toJson()), flush: true);

  // ── 2. 列出现有调试证书 ──────────────────────────────────────────
  final certs = await agc.getCertList();
  final debugCerts = certs.where((c) => c.isDebug).toList();
  stdout.writeln('· AGC 调试证书 ${debugCerts.length} 张：');
  for (final c in debugCerts) {
    stdout.writeln('    ${c.id}  ${c.certName}  ${c.publicKeySha256}');
  }
  if (mode == 'list') {
    stdout.writeln('（list 模式，未做任何修改）');
    return;
  }

  if (udids.isEmpty || udids.any((id) => id.length < 20)) {
    exitCode = await _fail('缺少有效 UDID\n'
        '  用法：dart run ../tools/make_hapstore_profile.dart <UDID[,UDID...]>');
    return;
  }
  await Directory(outDir).create(recursive: true);

  // ── 3. 找回「与 key.pem 配对」的证书；没有就用 CSR 新建 ───────────
  CertInfo? paired = await _findPairedCert(agc, debugCerts, keyPem, outDir);
  if (paired == null) {
    if (!allowNewCert) {
      exitCode = await _fail('没有与桌面私钥配对的 AGC 证书。为避免占满槽位，'
          '已停止；确认确实要为这把密钥新建证书后，显式传入 --allow-new-cert');
      return;
    }
    stdout.writeln('· 没有与 key.pem 配对的证书 → 用 CSR 新建 $kCertName');
    paired = await _createCert(agc, csrPath, debugCerts);
  }
  stdout.writeln('✓ 使用证书：${paired.certName}（${paired.id}）');

  // 下载该证书链并**复验配对**（这是整条链的关键不变量）。
  final certFile = '${outDir}/hapstore-debug.cer';
  await _downloadCert(agc, paired, certFile);
  final certBytes = await File(certFile).readAsBytes();
  final ok = isKeyCertPaired(privateKeyPem: keyPem, certificate: certBytes);
  if (ok != true) {
    exitCode = await _fail('证书与 key.pem 配对复验失败（结果=$ok）—— 已停止，'
        '以免签出一个装不上的包');
    return;
  }
  stdout.writeln('✓ 证书与 key.pem 配对复验通过：$certFile');

  // ── 4. 确保本机设备已登记 ────────────────────────────────────────
  var devices = await agc.deviceList();
  for (final udid in udids) {
    if (devices.any((d) => d.udid == udid)) continue;
    stdout.writeln('· 登记设备 ${udid.substring(0, 12)}…');
    await agc.createDevice('hapstore-${udid.substring(0, 10)}', udid);
    devices = await agc.deviceList();
  }
  final ids = devices.where((d) => udids.contains(d.udid)).map((d) => d.id).toList();
  if (ids.length < udids.length) {
    exitCode = await _fail('设备登记失败（AGC 未返回全部目标 UDID）');
    return;
  }
  stdout.writeln('✓ 设备已登记：${ids.length} 条记录');

  // ── 5. 优先复用本地授权；缺设备时才向 AGC 申请 ────────────────
  final safeBundle = bundleName.replaceAll('.', '_');
  final profilePath = '$outDir/$safeBundle.p7b';
  if (await File(profilePath).exists()) {
    try {
      await _verifyProfile(profilePath, udids, keyPem, bundleName);
      stdout.writeln('✓ 本地 Profile 已覆盖目标设备，未向 AGC 重复申请');
      return;
    } catch (_) {}
  }

  final profileName = bundleName == kBundleName ? kProfileName :
      'hapstore-desktop_$safeBundle';
  stdout.writeln('· 创建 Profile：$profileName');
  final url = await agc.createProfile(
    name: profileName,
    certId: paired.id,
    deviceIds: ids,
    moduleRequestedPermissions: const [],
    packageName: bundleName,
  );

  // ── 6. 下载并复验 Profile ────────────────────────────────────────
  if (!await agc.downloadFile(url, profilePath)) {
    exitCode = await _fail('Profile 下载失败：$url');
    return;
  }
  await _verifyProfile(profilePath, udids, keyPem, bundleName);

  final size = await File(profilePath).length();
  stdout.writeln('✓ Profile 已保存：$profilePath（$size 字节）');
  stdout.writeln('');
  stdout.writeln('签名时使用：');
  stdout.writeln('  证书    $certFile');
  stdout.writeln('  Profile $profilePath');
  stdout.writeln('  私钥    $keyPath');
}

/// 在已有调试证书里找回与 [keyPem] 配对的那张（逐张下载证书链复验）。
Future<CertInfo?> _findPairedCert(
  AgcService agc,
  List<CertInfo> debugCerts,
  String keyPem,
  String outDir,
) async {
  for (final c in debugCerts) {
    if (c.certObjectId.isEmpty) continue;
    final tmp = '$outDir/.probe-${c.id}.cer';
    try {
      final urls = await agc.downloadObj(c.certObjectId);
      if (urls.isEmpty) continue;
      if (!await agc.downloadFile(urls.first.newUrl, tmp)) continue;
      final paired =
          isKeyCertPaired(privateKeyPem: keyPem, certificate: await File(tmp).readAsBytes());
      if (paired == true) return c;
    } catch (_) {
      // 单张探测失败不影响继续找
    } finally {
      try {
        if (await File(tmp).exists()) await File(tmp).delete();
      } catch (_) {}
    }
  }
  return null;
}

/// 仅在有空位时新建证书；团队证书绝不自动删除。
Future<CertInfo> _createCert(
  AgcService agc,
  String csrPath,
  List<CertInfo> debugCerts,
) async {
  if (debugCerts.length >= 3) {
    throw StateError('3 个调试证书槽位已满，且没有与当前私钥配对的证书。'
        '请先在 AGC 确认哪张已不再使用，手动清理后重试');
  }
  final csr = await File(csrPath).readAsString();
  return agc.createCert(kCertName, 1, csr);
}

Future<void> _downloadCert(AgcService agc, CertInfo cert, String target) async {
  if (cert.certObjectId.isEmpty) {
    throw StateError('证书 ${cert.id} 没有 certObjectId，无法下载');
  }
  final urls = await agc.downloadObj(cert.certObjectId);
  if (urls.isEmpty) throw StateError('证书 ${cert.id} 取下载地址失败');
  if (!await agc.downloadFile(urls.first.newUrl, target)) {
    throw StateError('证书 ${cert.id} 下载失败');
  }
}

/// 复验 Profile：必须含目标包名与本机 UDID。
Future<void> _verifyProfile(String path, List<String> udids, String keyPem,
    String bundleName) async {
  final bytes = await File(path).readAsBytes();
  final payload = _extractJson(bytes);
  if (payload == null) {
    throw StateError('Profile 载荷解析失败（未找到 JSON）');
  }
  final bundle = (payload['bundle-info'] as Map?)?['bundle-name'];
  final embeddedCert = (payload['bundle-info'] as Map?)?['development-certificate'];
  final devIds =
      ((payload['debug-info'] as Map?)?['device-ids'] as List?)?.cast<String>() ??
          const <String>[];
  if (bundle != bundleName) {
    throw StateError('Profile 包名不符：$bundle');
  }
  if (embeddedCert is! String ||
      isKeyCertPaired(privateKeyPem: keyPem,
          certificate: utf8.encode(embeddedCert)) != true) {
    throw StateError('Profile 内证书与当前私钥不配对');
  }
  final expires = (payload['validity'] as Map?)?['not-after'];
  if (expires is num &&
      expires.toInt() <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7 * 86400) {
    throw StateError('Profile 已过期或即将过期');
  }
  if (!udids.every(devIds.contains)) {
    throw StateError('Profile 未包含全部目标 UDID（含 ${devIds.length} 台设备）');
  }
  stdout.writeln('✓ Profile 复验通过：包名 $bundle，含目标设备 ${udids.length} 台');
}

/// 从 CMS 封装里取出 Profile 的 JSON 载荷（逐个 `{` 候选尝试）。
Map<String, dynamic>? _extractJson(List<int> der) {
  for (var open = der.indexOf(0x7b); open >= 0; open = der.indexOf(0x7b, open + 1)) {
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = open; i < der.length; i++) {
      final c = der[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == 0x5c) {
          esc = true;
        } else if (c == 0x22) {
          inStr = false;
        }
        continue;
      }
      if (c == 0x22) {
        inStr = true;
      } else if (c == 0x7b) {
        depth++;
      } else if (c == 0x7d) {
        depth--;
        if (depth == 0) {
          try {
            final parsed = jsonDecode(utf8.decode(der.sublist(open, i + 1)));
            if (parsed is Map<String, dynamic> &&
                parsed.containsKey('bundle-info')) {
              return parsed;
            }
          } catch (_) {}
          break;
        }
      }
    }
  }
  return null;
}
