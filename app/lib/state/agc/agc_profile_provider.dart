// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 把 AGC 云能力接进 signing_core 的「设备授权自动重建」契约。
//
// ── 它解决什么问题 ────────────────────────────────────────────────────
// 调试 Profile 里绑定了设备 UDID 列表。换设备后旧 Profile 不含新设备，
// 设备侧安装时报 9568423。原实现只在「Profile 文件不存在」时才创建 Profile
// （`if (!await File(profilePath).exists())`），导致换设备必然失败，
// 用户只能去「重置证书」删文件。
//
// signing_core 的 provision.dart 已经实现了正确的判据与编排：
//   文件存在 ∧ bundle 匹配 ∧ 本机 UDID 在列 ∧ 未过期 ∧ ACL 覆盖
// 本文件补上「重建」这一动作的实际执行 —— 也就是调 AGC。
//
// ── 关于 CSR 与证书 ───────────────────────────────────────────────────
// 重建 Profile **不需要**新建证书：Profile 绑定的是已有的证书 ID。
// 只有在完全没有调试证书时才需要 CSR 来创建 —— 而 CSR 与私钥是配对的，
// 必须由生成签名材料时一并产出（小白就是这么做的）。
// 因此本 Provider 的处理顺序是：
//   ① 有 certId 且证书仍有效 → 直接用
//   ② 否则找同名的调试证书 → 用它的
//   ③ 都没有 → 才需要用 CSR 新建

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:signing_core/signing_core.dart';

import '../sign_material_store.dart';
import '../identity_generator.dart' show isKeyCertPaired;
import 'agc_models.dart';
import 'agc_service.dart';

class AgcProfileProvider implements AgcProviderContract {
  AgcProfileProvider({
    required this.agc,
    required this.csrPath,
    required this.keyPath,
    required this.certPath,
    required this.profileName,
    this.certId = '',
    this.onProgress,
    this.certName = kDebugCertName,
    this.onCertIdResolved,
  });

  final AgcService agc;

  /// 与私钥配对的 CSR 路径（仅在需要新建证书时使用）。
  final String csrPath;
  final String keyPath;

  /// 证书下载目标路径。
  final String certPath;

  /// Profile 名称。
  final String profileName;

  /// 已知的证书 ID；为空则自动查找/创建。
  String certId;

  final AgcProgress? onProgress;

  /// 调试证书名（与 [SignMaterialStore] 创建证书时用的名字必须一致）。
  final String certName;

  /// 当证书 ID 被解析/新建出来时回调，供上层**落盘**。
  ///
  /// 不落盘的话，进程重启后 Provider 又只能「按名字猜证书」，
  /// 而这个账号上可能有同名但不同私钥的历史证书。
  final void Function(String certId)? onCertIdResolved;

  /// 供 UI 展示的准备情况。
  @override
  String get accountLabel => agc.authInfo?.nickName?.isNotEmpty == true
      ? agc.authInfo!.nickName!
      : (agc.authInfo?.userId ?? '未登录');

  @override
  bool get isSignedIn => agc.isSignedIn;

  @override
  List<String> get grantableAcls => agc.aclList;

  // ────────────────── ProfileProvider 契约 ──────────────────

  @override
  Future<RegenerateReason?> shouldRegenerate(ProfileRequest request) async {
    final current = await provisioningDecision(
      profileFile: File(request.profilePath),
      targetBundleName: request.packageName,
      deviceUdid: request.deviceUdid,
      expectedAclFingerprint: request.aclFingerprint,
    );
    if (current == null) return null;

    // 各应用共用签名入口文件，但每个包的授权要单独缓存。装过 A 再装 B
    // 不应因入口文件被 B 覆盖就重新向 AGC 申请 A 的 Profile。
    final cached = _cachedProfile(request);
    if (await provisioningDecision(
          profileFile: cached,
          targetBundleName: request.packageName,
          deviceUdid: request.deviceUdid,
          expectedAclFingerprint: request.aclFingerprint,
        ) ==
        null) {
      await cached.copy(request.profilePath);
      onProgress?.call('已复用本地设备授权');
      return null;
    }
    return current;
  }

  File _cachedProfile(ProfileRequest request) {
    final team = agc.authInfo?.teamId ?? '';
    final identity = '$team|$certId|${request.packageName}';
    final key = sha256.convert(utf8.encode(identity)).toString().substring(0, 24);
    return File('${request.profilePath}.cache/$key.p7b');
  }

  @override
  Future<Uint8List> obtainProfile(ProfileRequest request) async {
    if (!agc.isSignedIn) {
      throw AgcException('需要先登录华为账号才能更新设备授权');
    }

    // ── ① 确保证书可用 ──────────────────────────────────────────
    final id = await _ensureCertId();
    onProgress?.call('已就绪证书 $id');

    // ── ② 确保设备已注册 ────────────────────────────────────────
    await _ensureDeviceRegistered(request.deviceUdid);

    // ── ③ 取设备 ID ─────────────────────────────────────────────
    final devices = await agc.deviceList();
    final deviceIds = devices
        .where((d) => d.udid == request.deviceUdid)
        .map((d) => d.id)
        .toList();
    if (deviceIds.isEmpty) {
      throw AgcException(
          '设备未注册成功，无法生成仅限本机的 Profile（UDID ${_short(request.deviceUdid)}）');
    }
    onProgress?.call('设备已登记（${deviceIds.length} 条记录）');

    // ── ④ 创建 Profile ──────────────────────────────────────────
    final acls = request.effectiveAcls;
    onProgress?.call(
        '申请 Profile：${request.resolvedProfileName}（ACL ${acls.length} 项）');
    final url = await agc.createProfile(
      name: request.resolvedProfileName,
      certId: id,
      deviceIds: deviceIds,
      moduleRequestedPermissions: request.requestedPermissions,
      packageName: request.packageName,
    );

    // ── ⑤ 下载到目标路径 ────────────────────────────────────────
    final target = request.profilePath;
    final ok = await agc.downloadFile(url, target);
    if (!ok) {
      throw AgcException('Profile 下载失败（$url）');
    }
    onProgress?.call('Profile 已更新');
    final bytes = await File(target).readAsBytes();
    if (await provisioningDecision(
          profileFile: File(target),
          targetBundleName: request.packageName,
          deviceUdid: request.deviceUdid,
          expectedAclFingerprint: request.aclFingerprint,
        ) ==
        null) {
      final cached = _cachedProfile(request);
      await cached.parent.create(recursive: true);
      await cached.writeAsBytes(bytes, flush: true);
    }
    return bytes;
  }

  // ────────────────── 内部步骤 ──────────────────

  /// 确保证书 ID 可用：优先复用已有证书，必要时新建。
  Future<String> _ensureCertId() async {
    final certs = await agc.getCertList();
    final debugCerts = certs.where((c) => c.isDebug).toList();

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final valid = debugCerts.where((c) =>
        c.expireTime == 0 || c.expireEpochSeconds > now);
    final candidates = <CertInfo>[
      ...valid.where((c) => c.id == certId),
      ...valid.where((c) => c.certName == certName && c.id != certId),
      ...valid.where((c) => c.id != certId && c.certName != certName),
    ];
    for (final candidate in candidates) {
      if (candidate.id == certId) {
        try {
          final local = File(certPath);
          if (await local.exists() &&
              isKeyCertPaired(
                    privateKeyPem: await File(keyPath).readAsString(),
                    certificate: await local.readAsBytes(),
                  ) ==
                  true) {
            return certId;
          }
        } catch (_) {}
      }
      try {
        await _downloadCert(candidate);
        certId = candidate.id;
        onCertIdResolved?.call(certId);
        return certId;
      } on AgcException catch (e) {
        if (!e.message.contains('与当前私钥不配对')) rethrow;
      }
    }

    // AGC 证书属于团队资源，不能自动删除一张可能仍被别的应用使用的证书。
    if (debugCerts.length >= 3) {
      throw AgcException('3 个调试证书槽位已满，且都不与本机私钥配对。请在证书管理中核对后删除一张不用的证书，或恢复该证书原私钥');
    }
    if (debugCerts.length == 2) {
      throw AgcException('AGC 仅剩最后一个调试证书槽位，请先在登录准备页确认后申请');
    }

    // 新建必须要有 CSR —— 它与私钥配对，无法凭空生成。
    final csr = await agc.readCsr(csrPath);
    if (csr == null || csr.trim().isEmpty) {
      throw AgcException(
        '需要新建调试证书，但读不到 CSR 文件：$csrPath',
        code: 0,
      );
    }
    if (!csr.contains('CERTIFICATE REQUEST')) {
      throw AgcException('CSR 文件内容不是合法的证书请求：$csrPath');
    }

    onProgress?.call('创建调试证书 $certName');
    final created = await agc.createCert(certName, 1, csr);
    await _downloadCert(created);
    certId = created.id;
    onCertIdResolved?.call(certId);
    return certId;
  }

  /// 把证书下到本地（签名时需要证书链文件）。
  Future<void> _downloadCert(CertInfo info) async {
    if (info.certObjectId.isEmpty) throw AgcException('AGC 证书缺少下载 ID');
    final f = File(certPath);
    final temp = File('$certPath.download');
    try {
      final urls = await agc.downloadObj(info.certObjectId);
      if (urls.isEmpty) throw AgcException('无法获取 AGC 证书下载地址');
      await f.parent.create(recursive: true);
      if (!await agc.downloadFile(urls.first.newUrl, temp.path)) {
        throw AgcException('AGC 证书下载失败');
      }
      final key = await File(keyPath).readAsString();
      final bytes = await temp.readAsBytes();
      if (isKeyCertPaired(privateKeyPem: key, certificate: bytes) != true) {
        throw AgcException('AGC 证书与当前私钥不配对');
      }
      await temp.rename(f.path);
      onProgress?.call('证书已下载到本地');
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// 确保目标设备已在 AGC 登记。
  Future<void> _ensureDeviceRegistered(String udid) async {
    if (udid.isEmpty) {
      throw AgcException('缺少设备 UDID，无法登记设备');
    }
    final devices = await agc.deviceList();
    if (devices.any((d) => d.udid == udid)) return;

    onProgress?.call('登记本机设备');
    final name = 'hapstore-${udid.length >= 10 ? udid.substring(0, 10) : udid}';
    try {
      await agc.createDevice(name, udid);
    } catch (e) {
      throw AgcException('设备登记失败（UDID ${_short(udid)}）：$e');
    }
  }

  static String _short(String s) =>
      s.length <= 12 ? s : '${s.substring(0, 12)}…';
}
