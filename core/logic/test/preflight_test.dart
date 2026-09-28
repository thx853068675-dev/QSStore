// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 预检测试。
//
// 这是本项目最重要的一组测试：它验证「UUID 报错」在签名之前就能被发现。
// 测试会优先使用本机 ~/Documents/hap_installer/store 下的**真实 Profile**
// （那正是踩过坑的那两份），找不到时退化为合成样本。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:signing_core/signing_core.dart';
import 'package:test/test.dart';

/// 本机真实签名材料目录（存在则用于更贴近现实的验证）。
final _storeDir = Directory(
    '${Platform.environment['HOME']}/Documents/hap_installer/store');

File? _realProfile(String name) {
  final f = File('${_storeDir.path}/$name');
  return f.existsSync() ? f : null;
}

/// 合成一份最小可解析的 Profile（结构与华为签发的 CMS 封装一致：
/// DER 里内嵌一段 JSON 明文）。
Uint8List syntheticProfile({
  required String bundle,
  required List<String> udids,
  required String type,
  int? notBefore,
  int? notAfter,
}) {
  final json = jsonEncode({
    'bundle-info': {'bundle-name': bundle},
    'debug-info': {'device-ids': udids, 'device-id-type': 'udid'},
    'type': type,
    'validity': {
      'not-before': notBefore ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400),
      'not-after': notAfter ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 365),
    },
  });
  // 前后各垫一些非 JSON 字节，模拟真实 CMS 结构
  return Uint8List.fromList([
    ...List<int>.filled(64, 0x30),
    ...utf8.encode(json),
    ...List<int>.filled(32, 0x00),
  ]);
}

void main() {
  late Directory tmp;
  late File profileFile;
  late File certFile;
  late File keyFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qs-preflight-');
    profileFile = File('${tmp.path}/profile.p7b');
    certFile = File('${tmp.path}/chain.cer');
    keyFile = File('${tmp.path}/key.pem');

    // 一份看起来像真实产物的证书与未加密私钥
    await certFile.writeAsString('-----BEGIN CERTIFICATE-----\n'
        'MIIB\n-----END CERTIFICATE-----\n');
    await keyFile.writeAsString('-----BEGIN PRIVATE KEY-----\n'
        'MIIB\n-----END PRIVATE KEY-----\n');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  SignConfig configFor({
    String? profile,
    String? cert,
    String? key,
  }) =>
      SignConfig(
        certPath: cert ?? certFile.path,
        profilePath: profile ?? profileFile.path,
        keystoreFile: key ?? keyFile.path,
      );

  group('Profile 解析', () {
    test('能从 CMS 封装中取出 bundle / UDID / 有效期', () async {
      final bytes = syntheticProfile(
        bundle: 'com.example.app',
        udids: ['AAA', 'BBB'],
        type: 'debug',
      );
      final s = await inspectProfile(bytes);
      expect(s.bundleName, 'com.example.app');
      expect(s.deviceIds, ['AAA', 'BBB']);
      expect(s.isDebug, isTrue);
      expect(s.notAfter, isNotNull);
    });

    test('拒绝不含 JSON 载荷的字节', () async {
      expect(
        () => inspectProfile(Uint8List.fromList(List.filled(100, 0x41))),
        throwsA(isA<FormatException>()),
      );
    });

    test('CMS 头部混入 `{`（0x7B）字节仍能定位真实载荷（真机回归）', () async {
      // 复刻真机 AGC Profile 的故障形态：JSON 之前的 ASN.1 头部
      // （长度字节 / OID）里出现 0x7B。旧实现只认首个 `{` 并在解码
      // 失败后直接放弃，导致「材料状态：Profile 解析失败」永远不消。
      final payload = syntheticProfile(
        bundle: 'com.example.app',
        udids: ['AAA'],
        type: 'debug',
      );
      final header = <int>[0x30, 0x82, 0x07, 0x7b, 0x06, 0x09, 0x2a, 0x86, 0x48];
      final bytes = Uint8List.fromList([...header, ...payload]);
      final s = await inspectProfile(bytes);
      expect(s.bundleName, 'com.example.app');
      expect(s.deviceIds, ['AAA']);
    });
  });

  group('预检：设备 UDID 授权（9568423 的根因）', () {
    test('UDID 不在授权列表时给出 error，并指明这是 9568423 的原因', () async {
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['OTHER-DEVICE-1', 'OTHER-DEVICE-2'],
        type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );

      expect(r.canProceed, isFalse);
      final issue =
          r.errors.firstWhere((i) => i.code == 'DEVICE_UDID_NOT_AUTHORIZED');
      expect(issue.message, contains('不在 Profile 授权列表内'));
      expect(issue.message, contains('列表含 2 台设备'));
      expect(issue.hint, contains('9568423'));
    });

    test('UDID 在授权列表时放行', () async {
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['MY-DEVICE-UDID'],
        type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );

      expect(r.canProceed, isTrue);
      expect(r.hasError, isFalse);
    });

    test('未提供 UDID 时降级为 warning，不阻断', () async {
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['X'],
        type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
      );

      expect(r.canProceed, isTrue);
      expect(r.issues.any((i) => i.code == 'UDID_UNKNOWN'), isTrue);
    });
  });

  group('预检：bundle 匹配（静默签错包的根因）', () {
    test('Profile 的 bundle 与待签包不一致时拦截', () async {
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'org.ohosdev.anime',
        udids: ['MY-DEVICE-UDID'],
        type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );

      expect(r.canProceed, isFalse);
      final issue =
          r.errors.firstWhere((i) => i.code == 'PROFILE_BUNDLE_MISMATCH');
      expect(issue.message, contains('org.ohosdev.anime'));
      expect(issue.message, contains('com.tonghongxiang.quietstart'));
    });
  });

  group('预检：有效期与类型', () {
    test('过期的 Profile 被拦截', () async {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400 * 10;
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['MY-DEVICE-UDID'],
        type: 'debug',
        notAfter: past,
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );
      expect(r.errors.any((i) => i.code == 'PROFILE_EXPIRED'), isTrue);
    });

    test('即将过期的 Profile 给出 warning 但不阻断', () async {
      final soon = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 2;
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['MY-DEVICE-UDID'],
        type: 'debug',
        notAfter: soon,
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );
      expect(r.canProceed, isTrue);
      expect(r.issues.any((i) => i.code == 'PROFILE_EXPIRING'), isTrue);
    });

    test('非 debug 类型的 Profile 被拦截（发布证书装不上设备）', () async {
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'com.tonghongxiang.quietstart',
        udids: ['MY-DEVICE-UDID'],
        type: 'release',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
        deviceUdid: 'MY-DEVICE-UDID',
      );
      expect(r.errors.any((i) => i.code == 'PROFILE_NOT_DEBUG'), isTrue);
    });
  });

  group('预检：材料与私钥', () {
    test('材料缺失被拦截', () async {
      final r = await preflightSigningMaterial(
        config: const SignConfig(
          certPath: '/nonexistent/chain.cer',
          profilePath: '/nonexistent/profile.p7b',
          keystoreFile: '/nonexistent/key.pem',
        ),
        targetBundleName: 'x',
      );
      expect(r.canProceed, isFalse);
      expect(r.errors.where((i) => i.code == 'MATERIAL_MISSING').length, 3);
    });

    test('加密私钥被拒绝（不允许口令上命令行）', () async {
      await keyFile.writeAsString('-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIB\n');
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'x', udids: ['u'], type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'x',
        deviceUdid: 'u',
      );
      expect(r.errors.any((i) => i.code == 'KEY_ENCRYPTED'), isTrue);
    });

    test('非 PEM 私钥（如 PKCS#12）被拒绝', () async {
      await keyFile.writeAsBytes(List<int>.filled(64, 0x30));
      await profileFile.writeAsBytes(syntheticProfile(
        bundle: 'x', udids: ['u'], type: 'debug',
      ));

      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'x',
        deviceUdid: 'u',
      );
      expect(r.errors.any((i) => i.code == 'KEY_NOT_PEM'), isTrue);
    });
  });

  group('真实材料回归（存在才跑）', () {
    test('本机真实 Profile 可被解析出关键字段', () async {
      final p = _realProfile('com_tonghongxiang_quietstart.p7b');
      if (p == null) {
        markTestSkipped('本机没有真实 Profile，跳过');
        return;
      }
      final s = await inspectProfile(await p.readAsBytes());
      expect(s.bundleName, isNotEmpty);
      expect(s.deviceIds, isNotEmpty);
      print('  真实 Profile: bundle=${s.bundleName} '
          '设备数=${s.deviceIds.length} 类型=${s.type} 到期=${s.notAfter}');
    });

    test('本机那份错误 Profile 会被 bundle 校验拦下（真实踩坑样本）', () async {
      final wrong = _realProfile('xiaobai-debug.p7b');
      if (wrong == null) {
        markTestSkipped('本机没有该样本，跳过');
        return;
      }
      final s = await inspectProfile(await wrong.readAsBytes());
      // 这份 Profile 绑的是另一个 bundle，正是「签名成功但装不上」的元凶
      print('  xiaobai-debug.p7b 实际 bundle = ${s.bundleName}');
      expect(s.bundleName, isNot('com.tonghongxiang.quietstart'),
          reason: '如果这份 Profile 恰好是轻启的，说明样本已更换');

      await profileFile.writeAsBytes(await wrong.readAsBytes());
      final r = await preflightSigningMaterial(
        config: configFor(),
        targetBundleName: 'com.tonghongxiang.quietstart',
      );
      expect(
        r.errors.any((i) => i.code == 'PROFILE_BUNDLE_MISMATCH'),
        isTrue,
        reason: '预检必须拦下这份 bundle 不匹配的 Profile',
      );
    });
  });
}
