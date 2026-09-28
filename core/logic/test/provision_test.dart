// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// Profile 自动重建测试 —— 验证「UUID 报错」不再需要用户手动重置证书。
//
// 这组测试直接对着原实现的那个错误判据设计：
//   原：if (!File(profilePath).exists()) → 存在就复用
//   新：「存在」还必须满足 bundle 匹配 + UDID 命中 + 未过期 + ACL 覆盖
//
// 因此关键在于：**文件存在但内容不适用时必须触发重建**。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:signing_core/signing_core.dart';
import 'package:test/test.dart';

Uint8List profileBytes({
  required String bundle,
  required List<String> udids,
  String type = 'debug',
  int? notAfter,
}) {
  final json = jsonEncode({
    'bundle-info': {'bundle-name': bundle},
    'debug-info': {'device-ids': udids, 'device-id-type': 'udid'},
    'type': type,
    'validity': {
      'not-before': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400,
      'not-after': notAfter ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 365,
    },
  });
  return Uint8List.fromList([
    ...List<int>.filled(64, 0x30),
    ...utf8.encode(json),
    ...List<int>.filled(32, 0x00),
  ]);
}

/// 一个可编程的假 provider，记录被调用情况。
class FakeProvider implements ProfileProvider {
  @override
  List<String> get grantableAcls => const [];
  FakeProvider(this.response, {this.forceReason});

  /// 每次 obtainProfile 返回的内容（可依次不同）。
  final List<Uint8List> response;
  final RegenerateReason? forceReason;

  int obtainCalls = 0;
  int decideCalls = 0;

  @override
  Future<RegenerateReason?> shouldRegenerate(ProfileRequest request) async {
    decideCalls++;
    if (forceReason != null) return forceReason;
    return provisioningDecision(
      profileFile: File(request.profilePath),
      targetBundleName: request.packageName,
      deviceUdid: request.deviceUdid,
    );
  }

  @override
  Future<Uint8List> obtainProfile(ProfileRequest request) async {
    final idx = obtainCalls < response.length ? obtainCalls : response.length - 1;
    obtainCalls++;
    final bytes = response[idx];
    // 模拟真实 provider 的副作用：写入目标路径。
    File(request.profilePath).writeAsBytesSync(bytes, flush: true);
    return bytes;
  }
}

void main() {
  late Directory tmp;
  late String profilePath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qs-provision-');
    profilePath = '${tmp.path}/profile.p7b';
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ProfileRequest req({
    String bundle = 'com.tonghongxiang.quietstart',
    String udid = 'DEVICE-A',
    List<String> perms = const [],
    List<String> acls = const [],
  }) =>
      ProfileRequest(
        packageName: bundle,
        deviceUdid: udid,
        profilePath: profilePath,
        requestedPermissions: perms,
        grantableAcls: acls,
      );

  group('重建判据（替换原实现的 if-exists）', () {
    test('文件不存在 → fileMissing', () async {
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.fileMissing);
    });

    test('文件存在但缺本机 UDID → deviceNotAuthorized（这正是 9568423）', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-B', 'DEVICE-C']));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.deviceNotAuthorized);
    });

    test('文件存在但 bundle 不匹配 → bundleMismatch', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'org.ohosdev.anime', udids: ['DEVICE-A']));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.bundleMismatch);
    });

    test('文件存在但已过期 → expired', () async {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400;
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A'], notAfter: past));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.expired);
    });

    test('即将过期 → expiringSoon（提前续期）', () async {
      final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 2;
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A'], notAfter: soon));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.expiringSoon);
    });

    test('非 debug 类型 → notDebug', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A'], type: 'release'));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.notDebug);
    });

    test('无法解析 → unreadable（宁可重建）', () async {
      File(profilePath).writeAsBytesSync(List<int>.filled(100, 0x41));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, RegenerateReason.unreadable);
    });

    test('全部满足 → null（可复用）', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A']));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
      );
      expect(r, isNull);
    });
  });

  group('ACL 处理（对应 9568289）', () {
    test('只提交「包内声明」与「可授权白名单」的交集', () {
      final r = req(
        perms: ['INTERNET', 'KEEP_BACKGROUND_RUNNING', 'NOT_ALLOWED'],
        acls: ['INTERNET', 'KEEP_BACKGROUND_RUNNING'],
      );
      expect(r.effectiveAcls, ['INTERNET', 'KEEP_BACKGROUND_RUNNING']);
    });

    test('交集为空时不报错', () {
      final r = req(perms: ['A'], acls: ['B']);
      expect(r.effectiveAcls, isEmpty);
    });

    test('指纹稳定（顺序无关）', () {
      final a = req(perms: ['X', 'Y'], acls: ['X', 'Y']);
      final b = req(perms: ['Y', 'X'], acls: ['Y', 'X']);
      expect(a.aclFingerprint, b.aclFingerprint);
    });

    test('从 module.json 提取权限声明', () {
      final perms = extractRequestedPermissions({
        'module': {
          'requestPermissions': [
            {'name': 'INTERNET'},
            {'name': 'KEEP_BACKGROUND_RUNNING'},
            {'other': 'ignored'},
          ]
        }
      });
      expect(perms, ['INTERNET', 'KEEP_BACKGROUND_RUNNING']);
    });

    test('ACL 指纹变化触发重建', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A']));
      final r = await provisioningDecision(
        profileFile: File(profilePath),
        targetBundleName: 'com.a',
        deviceUdid: 'DEVICE-A',
        expectedAclFingerprint: 'INTERNET,NEW_PERM',
        actualAclFingerprint: 'INTERNET',
      );
      expect(r, RegenerateReason.aclChanged);
    });
  });

  group('ensureUsableProfile 编排', () {
    test('Profile 已可用时不触发重建', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['DEVICE-A']));
      final p = FakeProvider([]);
      final r = await ensureUsableProfile(request: req(bundle: 'com.a'), provider: p);
      expect(r.ok, isTrue);
      expect(r.didRegenerate, isFalse);
      expect(p.obtainCalls, 0);
    });

    test('★ 文件存在但缺本机 UDID → 自动重建（原实现会在这里失败）', () async {
      // 旧 Profile：属于另一台设备
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.tonghongxiang.quietstart', udids: ['OTHER']));
      // provider 能造出正确的
      final p = FakeProvider([
        profileBytes(bundle: 'com.tonghongxiang.quietstart', udids: ['DEVICE-A']),
      ]);

      final r = await ensureUsableProfile(request: req(), provider: p);

      expect(r.ok, isTrue, reason: '应自动重建出可用的 Profile');
      expect(r.didRegenerate, isTrue);
      expect(p.obtainCalls, 1);
      expect(r.attempts.first.reason, RegenerateReason.deviceNotAuthorized);
      // 复验：重建后的内容确实含本机 UDID
      final summary = await inspectProfile(r.bytes!);
      expect(summary.containsDevice('DEVICE-A'), isTrue);
    });

    test('provider 返回的内容仍不适用 → 重试后放弃', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['OTHER']));
      // 每次都返回同样没用的内容
      final p = FakeProvider([
        profileBytes(bundle: 'com.a', udids: ['OTHER']),
      ]);
      final r = await ensureUsableProfile(
          request: req(bundle: 'com.a'), provider: p, maxAttempts: 3);
      expect(r.ok, isFalse);
      expect(p.obtainCalls, 3, reason: '应重试到上限');
      expect(r.error, contains('重建'));
    });

    test('provider 抛异常 → 标记 providerFailed 且不无限重试', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['OTHER']));
      final p = _ThrowingProvider();
      final r = await ensureUsableProfile(request: req(bundle: 'com.a'), provider: p);
      expect(r.ok, isFalse);
      expect(r.providerFailed, isTrue);
      expect(r.error, contains('登录'));
    });

    test('requireUsableProfile 失败时抛出带说明的异常', () async {
      File(profilePath).writeAsBytesSync(
          profileBytes(bundle: 'com.a', udids: ['OTHER']));
      final p = FakeProvider([profileBytes(bundle: 'com.a', udids: ['OTHER'])]);
      await expectLater(
        requireUsableProfile(request: req(bundle: 'com.a'), provider: p),
        throwsA(isA<ProvisioningException>().having(
          (e) => e.toString(),
          'message',
          contains('不需要用户手动重置证书'),
        )),
      );
    });
  });
}

class _ThrowingProvider implements ProfileProvider {
  @override
  List<String> get grantableAcls => const [];
  @override
  Future<RegenerateReason?> shouldRegenerate(ProfileRequest request) async =>
      RegenerateReason.deviceNotAuthorized;

  @override
  Future<Uint8List> obtainProfile(ProfileRequest request) async {
    throw const FormatException('请登录华为账号');
  }
}
