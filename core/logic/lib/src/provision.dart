// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// Profile 自动重建 —— 消灭「UUID 报错只能重置证书」的根因。
//
// ── 原实现的问题（一句话）────────────────────────────────────────────
// `EcoServices.autoCreateProfile` 第 355 行的判据是：
//
//     if (!await File(config.profilePath).exists()) { ...创建... }
//     else { print('profile 存在'); }          // ← 存在就直接复用
//
// 它只看「文件在不在」，不看「这份 Profile 是否适用于**当前这台设备**」。
// 于是必然出现：
//
//   · 首次在某台设备上登录使用 → 自动创建，含该机 UDID → 一切正常
//   · 换一台设备               → 文件已存在 → 复用旧 Profile
//                             → 里面没有新设备 UDID → 设备报 9568423
//   · 用户只能「重置证书」（删文件），让那个 if 重新成立
//
// 讽刺之处在于：AGC 侧的「注册设备 + 创建设备授权 Profile」能力本来就是
// 全自动的（`/device/add` + `/provision/add`，凭 DevEco 登录态调用，**不需要
// 任何 client_id/secret**）。缺的只是**正确的重建判据**。
//
// ── 本模块做什么 ─────────────────────────────────────────────────────
// 把判据补成：
//
//   文件存在 ∧ bundle 匹配 ∧ 本机 UDID 在列 ∧ 未过期 ∧ ACL 覆盖
//
// 任一不成立就触发重建。重建由 App 层通过 [ProfileProvider] 注入（因为调
// AGC 需要登录态与网络，属于平台能力），本模块负责**判定 + 编排 + 复验**。

import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'preflight.dart';

/// AGC 创建设备授权 Profile 所需的全部输入。
///
/// 字段与华为 `harmony-cert-manage` / `device-manage` / `provision-manage`
/// 三组接口的参数一一对应。
class ProfileRequest {
  const ProfileRequest({
    required this.packageName,
    required this.deviceUdid,
    required this.profilePath,
    this.certId = '',
    this.requestedPermissions = const [],
    this.grantableAcls = const [],
    this.profileName,
  });

  /// 待授权应用的 bundleName。
  final String packageName;

  /// 目标设备 UDID。AGC 会据此注册设备并把它写入 Profile。
  final String deviceUdid;

  /// 生成后写入的本地路径。
  final String profilePath;

  /// 已存在的证书 ID；为空表示需要先创建证书。
  final String certId;

  /// 包内 `module.json` 声明的权限列表。
  final List<String> requestedPermissions;

  /// 该项目在 AGC 侧**可被授权**的 ACL 白名单。
  ///
  /// 两者取交集后作为 `aclPermissionList` 提交。这一点很关键：
  /// 若 Profile 未声明某个高级权限（如 KEEP_BACKGROUND_RUNNING），
  /// 安装时即便加 `-g` 也会报 9568289。
  final List<String> grantableAcls;

  /// Profile 名称；省略时按 `xiaobai-debug_<包名下划线化>` 生成。
  final String? profileName;

  /// 实际会提交给 AGC 的 ACL 列表（权限 ∩ 白名单）。
  List<String> get effectiveAcls {
    final allowed = grantableAcls.toSet();
    final out = <String>{};
    for (final p in requestedPermissions) {
      if (allowed.contains(p)) out.add(p);
    }
    final sorted = out.toList()..sort();
    return sorted;
  }

  /// ACL 集合的指纹，用于判断「权限声明变了，需要重建 Profile」。
  String get aclFingerprint => effectiveAcls.join(',');

  String get resolvedProfileName =>
      profileName ?? 'xiaobai-debug_${packageName.replaceAll('.', '_')}';
}

/// 由 App 层实现的 Profile 获取能力。
///
/// 典型实现直接复用现有 `EcoService`：
///   deviceList() → 必要时 createDevice() → createProfile() → downloadFile()
abstract class ProfileProvider {
  /// AGC 账号可申请的 ACL；用于计算现有 Profile 是否覆盖本次安装。
  List<String> get grantableAcls => const [];

  /// 判定是否需要重建。返回 null 表示现有材料可用。
  ///
  /// 实现可以直接委托给 `provisioningDecision()`，也可以加入自己的判据
  /// （例如「证书也不存在」）。
  Future<RegenerateReason?> shouldRegenerate(ProfileRequest request);

  /// 执行重建，返回新 Profile 的字节内容。
  ///
  /// 实现应当同时把文件写到 [ProfileRequest.profilePath]，但本模块只依赖
  /// 返回的字节，不依赖副作用。
  Future<Uint8List> obtainProfile(ProfileRequest request);
}

/// 需要重建 Profile 的原因（机器可读，便于上层做提示与埋点）。
enum RegenerateReason {
  /// 本地文件不存在。
  fileMissing,

  /// Profile 绑定的 bundle 与目标应用不一致。
  bundleMismatch,

  /// 本机 UDID 不在授权列表内 —— **9568423 的直接原因**。
  deviceNotAuthorized,

  /// Profile 已过期。
  expired,

  /// 即将过期（提前续期，避免用户在使用中途失效）。
  expiringSoon,

  /// 包声明的权限变了，Profile 的 ACL 覆盖可能与需求不符。
  aclChanged,

  /// Profile 类型不是 debug。
  notDebug,

  /// 文件无法解析。
  unreadable,
}

extension RegenerateReasonText on RegenerateReason {
  /// 注意：这里刻意使用传统 switch 而非 Dart 3 的 switch 表达式，
  /// 以便与鸿蒙 Flutter 工具链（3.7.12-ohos / Dart 2.19.6）兼容。
  String get describe {
    switch (this) {
      case RegenerateReason.fileMissing:
        return '本地没有 Profile';
      case RegenerateReason.bundleMismatch:
        return 'Profile 绑定的包名不匹配';
      case RegenerateReason.deviceNotAuthorized:
        return '本机 UDID 不在 Profile 授权列表内';
      case RegenerateReason.expired:
        return 'Profile 已过期';
      case RegenerateReason.expiringSoon:
        return 'Profile 即将过期';
      case RegenerateReason.aclChanged:
        return '应用权限声明已变化（需要刷新 ACL）';
      case RegenerateReason.notDebug:
        return 'Profile 不是调试类型';
      case RegenerateReason.unreadable:
        return 'Profile 无法解析';
    }
    // 下面这行在覆盖全部枚举值后实际不可达，但保留以便未来新增原因时
    // 编译器能给出「缺少分支」提示。
    // ignore: dead_code
    return '未知原因';
  }
}

/// 判定现有 Profile 是否可用。
///
/// 这是对原实现 `if (!File.exists)` 的替换。返回 null 表示可以复用；
/// 否则返回需要重建的原因。
///
/// [expectedAclFingerprint] 若提供，会与 Profile 的 allowed-acls 比对；
/// [actualAclFingerprint] 仅供已提取 ACL 的调用方覆盖，未提供时直接解析 Profile。
Future<RegenerateReason?> provisioningDecision({
  required File profileFile,
  required String targetBundleName,
  required String deviceUdid,
  String? expectedAclFingerprint,
  String? actualAclFingerprint,
  Duration expiryLead = const Duration(days: 7),
}) async {
  if (!await profileFile.exists()) {
    return RegenerateReason.fileMissing;
  }

  ProfileSummary summary;
  try {
    summary = await inspectProfile(await profileFile.readAsBytes());
  } catch (_) {
    // 解析不了就当不可用 —— 重建比让用户对着 9568423 发懵强。
    return RegenerateReason.unreadable;
  }

  if (!summary.isDebug) return RegenerateReason.notDebug;
  if (summary.bundleName != targetBundleName) {
    return RegenerateReason.bundleMismatch;
  }
  if (deviceUdid.isNotEmpty && !summary.containsDevice(deviceUdid)) {
    return RegenerateReason.deviceNotAuthorized;
  }

  final now = DateTime.now().toUtc();
  if (summary.notAfter != null) {
    if (summary.notAfter!.isBefore(now)) return RegenerateReason.expired;
    if (summary.notAfter!.isBefore(now.add(expiryLead))) {
      return RegenerateReason.expiringSoon;
    }
  }

  final profileAclFingerprint =
      (summary.allowedAcls.toList()..sort()).join(',');
  if (expectedAclFingerprint != null &&
      expectedAclFingerprint !=
          (actualAclFingerprint ?? profileAclFingerprint)) {
    return RegenerateReason.aclChanged;
  }

  return null;
}

/// 确保拿到一份**可用于当前设备**的 Profile。
///
/// 流程：判定 → 必要时重建 → 复验 →（仍不通过则最多重试 [maxAttempts] 次）。
///
/// 返回结果里带有最终 Profile 字节与所做决策，便于上层展示与埋点。
Future<EnsureProfileResult> ensureUsableProfile({
  required ProfileRequest request,
  required ProfileProvider provider,
  int maxAttempts = 3,
  Duration expiryLead = const Duration(days: 7),
}) async {
  final attempts = <EnsureProfileAttempt>[];
  var lastReason = await provider.shouldRegenerate(request);

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (lastReason == null) {
      // 无需重建，直接读取现有材料并做一次独立复验。
      final file = File(request.profilePath);
      if (!await file.exists()) {
        lastReason = RegenerateReason.fileMissing;
        continue;
      }
      final bytes = await file.readAsBytes();
      final check = await provisioningDecision(
        profileFile: file,
        targetBundleName: request.packageName,
        deviceUdid: request.deviceUdid,
        expectedAclFingerprint: request.aclFingerprint,
        expiryLead: expiryLead,
      );
      attempts.add(EnsureProfileAttempt(
        attempt: attempt,
        reason: null,
        regenerated: false,
      ));
      if (check == null) {
        return EnsureProfileResult(
          bytes: bytes,
          attempts: attempts,
          providerFailed: false,
        );
      }
      // 复验不通过：把原因带进下一轮重建。
      lastReason = check;
    }

    attempts.add(EnsureProfileAttempt(
      attempt: attempt,
      reason: lastReason,
      regenerated: true,
    ));

    try {
      final bytes = await provider.obtainProfile(request);
      // 复验：AGC 返回的内容必须真的适用于本设备。
      // 这一步能挡住「调用成功但结果仍是旧 Profile」这类静默失败。
      final check = await provisioningDecision(
        profileFile: _materialize(bytes, request.profilePath),
        targetBundleName: request.packageName,
        deviceUdid: request.deviceUdid,
        expectedAclFingerprint: request.aclFingerprint,
        expiryLead: expiryLead,
      );
      if (check == null) {
        return EnsureProfileResult(
          bytes: bytes,
          attempts: attempts,
          providerFailed: false,
        );
      }
      lastReason = check;
    } catch (e) {
      attempts.add(EnsureProfileAttempt(
        attempt: attempt,
        reason: lastReason,
        regenerated: false,
        error: '$e',
      ));
      return EnsureProfileResult(
        bytes: null,
        attempts: attempts,
        providerFailed: true,
        error: '$e',
      );
    }
  }

  return EnsureProfileResult(
    bytes: null,
    attempts: attempts,
    providerFailed: false,
    error: '重建 ${attempts.length} 次后仍不可用'
        '（最后原因：${lastReason?.describe ?? "未知"}）',
  );
}

/// 把字节落到磁盘以便复用同一套文件校验路径。
///
/// 传入 [path] 时写文件；否则写临时文件。返回该文件。
File _materialize(Uint8List bytes, String path) {
  final f = File(path);
  f.writeAsBytesSync(bytes, flush: true);
  return f;
}

class EnsureProfileAttempt {
  const EnsureProfileAttempt({
    required this.attempt,
    required this.reason,
    required this.regenerated,
    this.error,
  });

  final int attempt;

  /// 本轮触发的重建原因；null 表示本轮是「直接复用」。
  final RegenerateReason? reason;
  final bool regenerated;
  final String? error;

  @override
  String toString() => 'attempt#$attempt '
      '${regenerated ? "重建" : "复用"}'
      '${reason != null ? " (${reason!.describe})" : ""}'
      '${error != null ? " 错误=$error" : ""}';
}

class EnsureProfileResult {
  const EnsureProfileResult({
    required this.bytes,
    required this.attempts,
    required this.providerFailed,
    this.error,
  });

  /// 最终可用的 Profile 字节；失败时为 null。
  final Uint8List? bytes;
  final List<EnsureProfileAttempt> attempts;

  /// 是否因 provider 抛异常而失败（区别于「重建了但仍不可用」）。
  final bool providerFailed;
  final String? error;

  bool get ok => bytes != null;

  /// 是否发生过重建（用于提示「已自动为你更新设备授权」）。
  bool get didRegenerate => attempts.any((a) => a.regenerated);

  @override
  String toString() => ok
      ? 'EnsureProfileResult(ok, 重建=${didRegenerate}, 轮次=${attempts.length})'
      : 'EnsureProfileResult(失败: $error)';
}

/// 便捷封装：把「确保 Profile + 预检」合成一步，供签名主流程调用。
///
/// 返回最终可用的 Profile 字节，或抛出 [ProvisioningException]。
Future<Uint8List> requireUsableProfile({
  required ProfileRequest request,
  required ProfileProvider provider,
  int maxAttempts = 3,
}) async {
  final result = await ensureUsableProfile(
    request: request,
    provider: provider,
    maxAttempts: maxAttempts,
  );
  if (!result.ok) {
    throw ProvisioningException(
      result.error ?? '无法获取可用的设备授权 Profile',
      attempts: result.attempts,
    );
  }
  return result.bytes!;
}

class ProvisioningException implements Exception {
  ProvisioningException(this.message, {this.attempts = const []});

  final String message;
  final List<EnsureProfileAttempt> attempts;

  @override
  String toString() {
    final detail = attempts.isEmpty
        ? ''
        : '\n  尝试记录：\n${attempts.map((a) => '    - $a').join('\n')}';
    // 明确指出这不是「需要用户去重置证书」的场景。
    return 'ProvisioningException: $message$detail\n'
        '  （这属于可自动恢复的授权问题，不需要用户手动重置证书）';
  }
}

/// 从包的 `module.json` 中提取声明的权限名，供 [ProfileRequest] 使用。
List<String> extractRequestedPermissions(Map<String, dynamic> moduleJson) {
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

/// 生成 [SignConfig] 之外的便利：从材料路径构造 request。
ProfileRequest buildProfileRequest({
  required String packageName,
  required String deviceUdid,
  required String profilePath,
  String certId = '',
  List<String> requestedPermissions = const [],
  List<String> grantableAcls = const [],
}) =>
    ProfileRequest(
      packageName: packageName,
      deviceUdid: deviceUdid,
      profilePath: profilePath,
      certId: certId,
      requestedPermissions: requestedPermissions,
      grantableAcls: grantableAcls,
    );
