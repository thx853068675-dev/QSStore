// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 签名前预检 —— 本项目最重要的一块。
//
// ── 为什么需要它 ────────────────────────────────────────────────────────
// 旧实现全流程**没有任何 UDID 预检**：唯一的 Profile 解析器只看 bundle-name
// 和 ACL，完全跳过 device-ids。于是会发生这种事：
//
//   签名材料目录里同时躺着两份 Profile
//     · com_tonghongxiang_quietstart.p7b   ← 正确（含本机 UDID）
//     · xiaobai-debug.p7b                  ← bundle 是 org.ohosdev.anime
//   而配置指向了错的那份
//
// 结果是：包签好了、推到设备了，才弹
//   code:9568423 the device is unauthorized, make sure the UDID of your
//   device is configured in the signing profile
// 用户看不懂，只能去「重置证书」——这正是「UUID 报错」的完整成因。
//
// 这里把这件事提前到签名之前，并且给出机器可读的结论。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'package.dart';

enum Severity { info, warning, error }

class PreflightIssue {
  const PreflightIssue(this.severity, this.code, this.message, {this.hint});

  final Severity severity;

  /// 机器可读的问题码，便于上层做自愈动作编排。
  final String code;
  final String message;
  final String? hint;

  @override
  String toString() => '[${severity.name.toUpperCase()}] $code: $message'
      '${hint != null ? ' ($hint)' : ''}';
}

/// Profile（.p7b）的关键字段摘要。
class ProfileSummary {
  const ProfileSummary({
    required this.bundleName,
    required this.type,
    required this.deviceIds,
    this.allowedAcls = const [],
    required this.notBefore,
    required this.notAfter,
  });

  final String bundleName;
  final String type;
  final List<String> deviceIds;
  final List<String> allowedAcls;
  final DateTime? notBefore;
  final DateTime? notAfter;

  bool containsDevice(String udid) => deviceIds.contains(udid);

  bool get isDebug => type.toLowerCase() == 'debug';
}

class PreflightReport {
  PreflightReport(this.issues, {this.profile});

  final List<PreflightIssue> issues;
  final ProfileSummary? profile;

  bool get hasError => issues.any((i) => i.severity == Severity.error);
  bool get hasWarning => issues.any((i) => i.severity == Severity.warning);

  /// 是否可以安全进入签名流程。
  bool get canProceed => !hasError;

  List<PreflightIssue> get errors =>
      issues.where((i) => i.severity == Severity.error).toList();

  @override
  String toString() =>
      'PreflightReport(errors=${errors.length}, issues=${issues.length})';
}

/// 解析 Profile（PKCS#7 / CMS 封装，内含 JSON 载荷）。
///
/// 这里**不做密码学验签**：Profile 的签名由设备与系统校验，本函数只提取
/// 用于预检的元数据。这不是安全边界，因此不引入 OpenSSL 依赖。
Future<ProfileSummary> inspectProfile(Uint8List der) async {
  final json = _extractProfilePayload(der);
  if (json == null) {
    throw const FormatException('无法解析 Profile：未找到 JSON 载荷');
  }
  final map = jsonDecode(json);
  if (map is! Map<String, dynamic>) {
    throw const FormatException('无法解析 Profile：载荷不是 JSON 对象');
  }

  final bundleInfo = map['bundle-info'];
  final debugInfo = map['debug-info'];
  final validity = map['validity'];
  final acls = map['acls'];
  final allowedAcls = acls is Map ? acls['allowed-acls'] : null;

  return ProfileSummary(
    bundleName:
        (bundleInfo is Map ? bundleInfo['bundle-name'] : null) as String? ?? '',
    type: map['type'] as String? ?? '',
    deviceIds: (debugInfo is Map ? (debugInfo['device-ids'] as List?) : null)
            ?.cast<String>() ??
        const [],
    allowedAcls: allowedAcls is List
        ? allowedAcls.whereType<String>().toList()
        : const [],
    notBefore: _epochToDate(validity is Map ? validity['not-before'] : null),
    notAfter: _epochToDate(validity is Map ? validity['not-after'] : null),
  );
}

DateTime? _epochToDate(dynamic v) {
  final n = v is int ? v : (v is String ? int.tryParse(v) : null);
  if (n == null || n <= 0) return null;
  // Profile 里的时间戳是秒级。
  return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
}

/// 从 DER 字节中定位 Profile 的 JSON 载荷。
///
/// 不能用「首个 `{` 到最后一个 `}`」的宽松策略：真实 Profile 的 CMS 结构里
/// JSON 之后还跟着 ASN.1 数据（可能包含 `}` 字节），会截取出非法 JSON。
/// 这里改为**括号配对扫描**，并正确处理字符串与转义。
///
/// 另外不能只看**首个** `{`：CMS 头部（版本号 / OID / 长度字节）在 JSON
/// 之前，其中完全可能混进一个 0x7B 字节。实测真机下载的 AGC Profile
/// 就因此永远解析失败（表现为「材料状态：Profile 解析失败」）。
/// 因此这里把**每一个** `{` 都作为候选起点逐一尝试：某个候选点解码不出
/// 合法 JSON 就继续找下一个，直到找到包含 Profile 关键字段的那个。
String? _extractProfilePayload(Uint8List der) {
  for (var open = der.indexOf(0x7b);
      open >= 0;
      open = der.indexOf(0x7b, open + 1)) {
    final json = _tryPayloadAt(der, open);
    if (json != null) return json;
  }
  return null;
}

/// 从指定起点做括号配对，提取候选 JSON 并验证其为 Profile 载荷。
///
/// 返回 null 表示该候选不成立（交给调用方尝试下一个起点）。
String? _tryPayloadAt(Uint8List der, int open) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = open; i < der.length; i++) {
    final c = der[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5c) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7b) {
      depth++;
    } else if (c == 0x7d) {
      depth--;
      if (depth == 0) {
        try {
          final text = utf8.decode(der.sublist(open, i + 1));
          final parsed = jsonDecode(text);
          // 必须是含 Profile 关键字段的对象，避免把二进制里碰巧
          // 可解码的片段当成载荷。
          if (parsed is Map<String, dynamic> &&
              parsed.containsKey('bundle-info')) {
            return text;
          }
          return null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}

/// 对签名材料做签名前预检。
///
/// [config] 材料配置
/// [targetBundleName] 待签包的 bundleName（用于校验 Profile 是否匹配）
/// [deviceUdid] 当前设备 UDID；为 null 时跳过 UDID 命中检查（仅给警告）
Future<PreflightReport> preflightSigningMaterial({
  required SignConfig config,
  required String targetBundleName,
  String? deviceUdid,
  Duration expiryLead = const Duration(days: 7),
}) async {
  final issues = <PreflightIssue>[];
  ProfileSummary? profile;

  // ── 材料存在性 ────────────────────────────────────────────────────
  for (final entry in {
    '证书': config.certPath,
    'Profile': config.profilePath,
    '私钥': config.keystoreFile,
  }.entries) {
    if (entry.value.isEmpty) {
      issues.add(PreflightIssue(
          Severity.error, 'MATERIAL_MISSING', '${entry.key}路径未配置'));
    } else if (!await File(entry.value).exists()) {
      issues.add(PreflightIssue(Severity.error, 'MATERIAL_MISSING',
          '${entry.key}文件不存在：${entry.value}'));
    }
  }
  if (issues.any((i) => i.severity == Severity.error)) {
    return PreflightReport(issues);
  }

  // ── 私钥类型：必须是未加密 PEM ────────────────────────────────────
  // 这是硬约束：本项目不允许把口令放到进程命令行上。
  try {
    final pem = await File(config.keystoreFile).readAsString();
    // 先判加密：`BEGIN ENCRYPTED PRIVATE KEY` 也是合法 PEM，
    // 若先判「是否 PEM」会给出错误的问题码。
    if (pem.contains('ENCRYPTED')) {
      issues.add(const PreflightIssue(
          Severity.error, 'KEY_ENCRYPTED', '私钥已加密，签名器不接受',
          hint: '请导出未加密的 PEM；口令不应出现在命令行'));
    } else if (!pem.contains('-----BEGIN PRIVATE KEY-----') &&
        !pem.contains('-----BEGIN EC PRIVATE KEY-----') &&
        !pem.contains('-----BEGIN RSA PRIVATE KEY-----')) {
      issues.add(const PreflightIssue(
          Severity.error, 'KEY_NOT_PEM', '私钥不是 PEM 格式（可能是 PKCS#12/JKS）',
          hint: '请使用小白生成的 PEM 私钥'));
    }
  } catch (e) {
    issues.add(PreflightIssue(Severity.error, 'KEY_UNREADABLE', '私钥读取失败：$e'));
  }

  // ── Profile 解析与关键校验 ────────────────────────────────────────
  try {
    final der = await File(config.profilePath).readAsBytes();
    profile = await inspectProfile(der);

    // ① 类型必须是 debug：发布证书签出的包在设备上装不上（9568322）。
    if (!profile.isDebug) {
      issues.add(PreflightIssue(Severity.error, 'PROFILE_NOT_DEBUG',
          'Profile 类型是 ${profile.type}，不是 debug',
          hint: '设备侧载必须使用调试 Profile'));
    }

    // ② bundle 必须匹配：这是最容易被忽略、后果最严重的一项。
    //    材料目录里混放多份 Profile 时尤其危险。
    if (profile.bundleName != targetBundleName) {
      issues.add(PreflightIssue(
          Severity.error,
          'PROFILE_BUNDLE_MISMATCH',
          'Profile 绑定的 bundle 是「${profile.bundleName}」，'
              '与待签包「$targetBundleName」不一致',
          hint: '签名会成功但设备拒绝安装（9568423/9568322）；请选择正确的 Profile'));
    }

    // ③ 有效期。
    final now = DateTime.now().toUtc();
    if (profile.notAfter != null && profile.notAfter!.isBefore(now)) {
      issues.add(PreflightIssue(Severity.error, 'PROFILE_EXPIRED',
          'Profile 已于 ${profile.notAfter!.toLocal()} 过期'));
    } else if (profile.notAfter != null &&
        profile.notAfter!.isBefore(now.add(expiryLead))) {
      issues.add(PreflightIssue(
          Severity.warning,
          'PROFILE_EXPIRING',
          'Profile 将于 ${profile.notAfter!.toLocal()} 过期（不足 '
              '${expiryLead.inDays} 天）',
          hint: '建议提前重新申请'));
    }

    // ④ UDID 命中 —— 这就是 9568423 的根因。
    if (deviceUdid != null && deviceUdid.isNotEmpty) {
      if (!profile.containsDevice(deviceUdid)) {
        issues.add(PreflightIssue(
            Severity.error,
            'DEVICE_UDID_NOT_AUTHORIZED',
            '本机 UDID（${_short(deviceUdid)}）不在 Profile 授权列表内'
                '（列表含 ${profile.deviceIds.length} 台设备）',
            hint: '这是设备报 9568423 的直接原因：'
                '需为该设备重新申请 Profile，而不是重置证书'));
      }
    } else {
      issues.add(const PreflightIssue(
          Severity.warning, 'UDID_UNKNOWN', '未提供设备 UDID，跳过授权校验',
          hint: '连接设备后传入 UDID 可获得完整预检'));
    }
  } catch (e) {
    issues.add(PreflightIssue(
        Severity.error, 'PROFILE_UNREADABLE', 'Profile 解析失败：$e'));
  }

  // ── 证书有效期 ──────────────────────────────────────────────────
  try {
    final pem = await File(config.certPath).readAsString();
    final notAfter = _certNotAfter(pem);
    if (notAfter != null) {
      final now = DateTime.now().toUtc();
      if (notAfter.isBefore(now)) {
        issues.add(PreflightIssue(
            Severity.error, 'CERT_EXPIRED', '证书已于 ${notAfter.toLocal()} 过期'));
      } else if (notAfter.isBefore(now.add(expiryLead))) {
        issues.add(PreflightIssue(Severity.warning, 'CERT_EXPIRING',
            '证书将于 ${notAfter.toLocal()} 过期'));
      }
    }
  } catch (_) {
    // 证书解析失败不阻断：原生签名器会给出更准确的结论。
    issues.add(const PreflightIssue(
        Severity.info, 'CERT_UNPARSED', '证书有效期未能解析（不影响签名）'));
  }

  return PreflightReport(issues, profile: profile);
}

String _short(String s) => s.length <= 12 ? s : '${s.substring(0, 12)}…';

/// 从 PEM 文本中粗略提取证书的 notAfter。
///
/// 只做「是否有明显过期」的判断，不做完整 X.509 解析 —— 精确校验交给原生签名器。
DateTime? _certNotAfter(String pem) {
  // 采用 openssl 文本输出的常见形式不便直接解析，这里改用 ASN.1 UTCTime
  // 的固定形态做宽松匹配；匹配不到就返回 null（上层降级为 info）。
  final match = RegExp(r'(\d{12})Z').firstMatch(pem);
  if (match == null) return null;
  final s = match.group(1)!;
  try {
    return DateTime.utc(
      2000 + int.parse(s.substring(0, 2)),
      int.parse(s.substring(2, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
      int.parse(s.substring(8, 10)),
      int.parse(s.substring(10, 12)),
    );
  } catch (_) {
    return null;
  }
}

/// 便捷方法：从包里读 bundleName 后做预检。
Future<PreflightReport> preflightForPackage({
  required SignConfig config,
  required String targetBundleName,
  String? deviceUdid,
}) =>
    preflightSigningMaterial(
      config: config,
      targetBundleName: targetBundleName,
      deviceUdid: deviceUdid,
    );

/// 轻启包的 bundleName 常量再导出，便于调用方拼装预检参数。
const quietStartBundleName = bundleName;
