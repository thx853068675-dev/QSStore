// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// AGC 设备授权自动重建测试。
//
// ── 为什么这组测试重要 ────────────────────────────────────────────────
// 「换设备后自动重建 Profile」是消灭 9568423 的最后一环。真机验证需要
// 华为账号登录，无法自动化；因此这里用一个**假的 AgcService** 把整条
// 重建链路跑通，验证：
//   · 判据正确（缺本机 UDID / bundle 不匹配 / 过期 → 触发重建）
//   · 重建动作正确（登记设备 → 复用证书 → 创建 Profile → 下载）
//   · 结果可复验（重建后的 Profile 真的含本机 UDID）
//
// ── 模拟的边界 ────────────────────────────────────────────────────────
// 这里不 mock HTTP，而是覆写 AgcService 的方法。这样测的是
// **AgcProfileProvider 的编排逻辑**，而不是网络层 —— 后者契约固定，
// 且原实现已在生产中使用。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/agc/agc_models.dart';
import 'package:hapstore/state/agc/agc_profile_provider.dart';
import 'package:hapstore/state/agc/agc_service.dart';
import 'package:hapstore/state/identity_generator.dart';
import 'package:pointycastle/asn1.dart';
import 'package:signing_core/signing_core.dart';

/// 造一份可解析的 Profile 字节（结构与华为签发的 CMS 封装一致：
/// DER 中内嵌一段 JSON 明文）。
Uint8List makeProfile({
  required String bundle,
  required List<String> udids,
  String type = 'debug',
  int? notAfter,
  List<String> acls = const [],
}) {
  final json = jsonEncode({
    'bundle-info': {'bundle-name': bundle},
    'debug-info': {'device-ids': udids, 'device-id-type': 'udid'},
    'type': type,
    'acls': {'allowed-acls': acls},
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

/// 可控的假 AGC 服务，记录所有被调用的动作。
class FakeAgc extends AgcService {
  FakeAgc({
    this.certs = const [],
    this.devices = const [],
    this.udidToRegisterAs,
  }) {
    // 让 isSignedIn 为真
    initUserInfo(AuthInfo(accessToken: 't', userId: 'u', nickName: '测试账号'));
  }

  List<CertInfo> certs;
  Uint8List certBytes = Uint8List(0);
  Map<String, Uint8List> certBytesByObject = {};
  List<DeviceInfo> devices;

  /// 非 null 时表示「本机还未登记」，createDevice 会把它加进 devices
  final String? udidToRegisterAs;

  /// 生成 Profile 时使用的设备 ID 列表
  List<String> lastDeviceIds = const [];
  List<String> lastAcls = const [];
  String lastPackageName = '';
  String lastProfileName = '';

  int createDeviceCalls = 0;
  int createCertCalls = 0;
  int createProfileCalls = 0;
  int downloadCalls = 0;
  int deleteCertCalls = 0;

  /// 由测试决定「新 Profile 该含哪些 UDID」
  List<String> profileUdids = const [];

  @override
  Future<List<CertInfo>> getCertList() async => certs;

  @override
  Future<List<DeviceInfo>> deviceList() async => devices;

  @override
  Future<void> createDevice(String deviceName, String uuid) async {
    createDeviceCalls++;
    devices = [
      ...devices,
      DeviceInfo(
          id: 'dev-${devices.length + 1}', deviceName: deviceName, udid: uuid),
    ];
  }

  @override
  Future<CertInfo> createCert(String name, int type, String csr) async {
    createCertCalls++;
    final c = CertInfo(
      id: 'cert-new',
      certName: name,
      certObjectId: 'obj-new',
      certType: type,
      expireTime: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 365,
    );
    certs = [...certs, c];
    return c;
  }

  @override
  Future<void> deleteCertList(List<String> certIds) async {
    deleteCertCalls++;
    certs = certs.where((c) => !certIds.contains(c.id)).toList();
  }

  @override
  Future<List<UrlInfo>> downloadObj(String objId) async =>
      [UrlInfo(newUrl: 'https://example.invalid/$objId')];

  @override
  Future<String> createProfile({
    required String name,
    required String certId,
    required List<String> deviceIds,
    required List<String> moduleRequestedPermissions,
    required String packageName,
  }) async {
    createProfileCalls++;
    lastDeviceIds = deviceIds;
    lastAcls = effectiveAcls(moduleRequestedPermissions);
    lastPackageName = packageName;
    lastProfileName = name;
    return 'https://example.invalid/profile.p7b';
  }

  @override
  Future<bool> downloadFile(String url, String savePath) async {
    downloadCalls++;
    if (!url.endsWith('profile.p7b')) {
      final objectId = Uri.parse(url).pathSegments.last;
      await File(savePath).writeAsBytes(
          certBytesByObject[objectId] ?? certBytes, flush: true);
      return true;
    }
    // 写出「AGC 刚生成的」那份 Profile
    final bytes = makeProfile(
      bundle: lastPackageName,
      udids: profileUdids.isNotEmpty ? profileUdids : const [],
      acls: lastAcls,
    );
    final f = File(savePath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return true;
  }
}

void main() {
  late Directory tmp;
  late String profilePath;
  late String certPath;
  late String csrPath;
  late String keyPath;
  late Uint8List certBytes;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qs-agc-');
    profilePath = '${tmp.path}/profile.p7b';
    certPath = '${tmp.path}/chain.cer';
    csrPath = '${tmp.path}/key.csr';
    keyPath = '${tmp.path}/key.pem';
    final identity = generateIdentity(subject: 'C=CN,O=HapStore,CN=test');
    await File(keyPath).writeAsString(identity.privateKeyPem);
    certBytes = ASN1Sequence(elements: [
      ASN1BitString(
          stringValues: publicKeyPointOfPrivateKey(identity.privateKeyPem))
    ]).encode();
    // 一份合法的 CSR 文本（内容不参与校验，只检查标记）
    await File(csrPath).writeAsString(
        '-----BEGIN CERTIFICATE REQUEST-----\nMIIB\n-----END CERTIFICATE REQUEST-----\n');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ProfileRequest req({
    String bundle = 'com.tonghongxiang.hapstore',
    String udid = 'DEVICE-NEW',
    List<String> perms = const ['ohos.permission.INTERNET'],
  }) =>
      ProfileRequest(
        packageName: bundle,
        deviceUdid: udid,
        profilePath: profilePath,
        requestedPermissions: perms,
        grantableAcls: defaultAcl,
      );

  AgcProfileProvider providerFor(FakeAgc agc, {String certId = ''}) {
    agc.certBytes = certBytes;
    return AgcProfileProvider(
      agc: agc,
      csrPath: csrPath,
      keyPath: keyPath,
      certPath: certPath,
      profileName: 'hapstore-debug',
      certId: certId,
    );
  }

  group('判据：何时需要重建', () {
    test('AGC 证书到期时间同时兼容秒与毫秒', () {
      expect(CertInfo(expireTime: 1821979547).expireEpochSeconds, 1821979547);
      expect(CertInfo(expireTime: 1821979547000).expireEpochSeconds, 1821979547);
    });
    test('普通后台权限不进入 AGC ACL 列表', () {
      final service = AgcService();
      expect(
        service.effectiveAcls([
          'ohos.permission.INTERNET',
          'ohos.permission.KEEP_BACKGROUND_RUNNING',
          'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM',
        ]),
        ['ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM'],
      );
    });
    test('同一包新增可授权权限时重建 Profile', () async {
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'com.tonghongxiang.hapstore',
        udids: ['DEVICE-NEW'],
      ));
      final result = await providerFor(FakeAgc()).shouldRegenerate(req(
        perms: ['ohos.permission.READ_PASTEBOARD'],
      ));
      expect(result, RegenerateReason.aclChanged);
    });
    test('文件不存在 → 触发重建', () async {
      final agc = FakeAgc();
      final r = await providerFor(agc).shouldRegenerate(req());
      expect(r, RegenerateReason.fileMissing);
    });

    test('文件存在但缺本机 UDID → 触发重建（9568423 的根因）', () async {
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'com.tonghongxiang.hapstore',
        udids: ['OTHER-DEVICE'],
      ));
      final agc = FakeAgc();
      final r = await providerFor(agc).shouldRegenerate(req());
      expect(r, RegenerateReason.deviceNotAuthorized);
    });

    test('bundle 不匹配 → 触发重建', () async {
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'org.ohosdev.anime',
        udids: ['DEVICE-NEW'],
      ));
      final r = await providerFor(FakeAgc()).shouldRegenerate(req());
      expect(r, RegenerateReason.bundleMismatch);
    });

    test('已过期 → 触发重建', () async {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400;
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'com.tonghongxiang.hapstore',
        udids: ['DEVICE-NEW'],
        notAfter: past,
      ));
      final r = await providerFor(FakeAgc()).shouldRegenerate(req());
      expect(r, RegenerateReason.expired);
    });

    test('完全可用 → 不重建', () async {
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'com.tonghongxiang.hapstore',
        udids: ['DEVICE-NEW'],
      ));
      final r = await providerFor(FakeAgc()).shouldRegenerate(req());
      expect(r, isNull);
    });
  });

  group('重建动作：完整链路', () {
    test('★ 缺本机 UDID → 登记设备 → 建 Profile → 下载 → 结果含本机 UDID', () async {
      // 起点：旧 Profile 属于别的设备
      await File(profilePath).writeAsBytes(makeProfile(
        bundle: 'com.tonghongxiang.hapstore',
        udids: ['OLD-DEVICE'],
      ));

      final agc = FakeAgc(
        certs: [
          CertInfo(
            id: 'cert-1',
            certName: kDebugCertName,
            certObjectId: 'obj-1',
            certType: 1,
            expireTime:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 300,
          ),
        ],
      )..profileUdids = ['DEVICE-NEW'];

      final provider = providerFor(agc);
      final result =
          await ensureUsableProfile(request: req(), provider: provider);

      expect(result.ok, isTrue, reason: '应重建出可用的 Profile');
      expect(result.didRegenerate, isTrue);
      expect(
          result.attempts.first.reason, RegenerateReason.deviceNotAuthorized);

      // 动作序列正确
      expect(agc.createDeviceCalls, 1, reason: '应登记本机设备');
      expect(agc.createProfileCalls, 1, reason: '应创建一次 Profile');
      // 下载两次：一次证书（本地缺失时补下载）、一次 Profile
      expect(agc.downloadCalls, 2, reason: '应下载证书与 Profile 各一次');
      expect(agc.createCertCalls, 0, reason: '已有证书，不应重复创建');

      // 复验：新 Profile 确实含本机 UDID
      final summary = await inspectProfile(result.bytes!);
      expect(summary.containsDevice('DEVICE-NEW'), isTrue);
      expect(summary.bundleName, 'com.tonghongxiang.hapstore');

      // 提交给 AGC 的设备 ID 来自登记结果
      expect(agc.lastDeviceIds, isNotEmpty);
      expect(agc.lastPackageName, 'com.tonghongxiang.hapstore');
    });

    test('设备已登记时不再重复登记', () async {
      final agc = FakeAgc(
        certs: [
          CertInfo(
              id: 'c1',
              certName: kDebugCertName,
              certObjectId: 'obj-c1',
              certType: 1)
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];

      await ensureUsableProfile(request: req(), provider: providerFor(agc));

      expect(agc.createDeviceCalls, 0, reason: '设备已在列，不应重复登记');
      expect(agc.createProfileCalls, 1);
    });

    test('A → B → A 时复用本地授权，不再为 A 申请', () async {
      final agc = FakeAgc(
        certs: [CertInfo(
          id: 'shared-cert', certName: kDebugCertName,
          certObjectId: 'shared-object', certType: 1,
        )],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];
      final provider = providerFor(agc);

      expect((await ensureUsableProfile(request: req(bundle: 'example.a'),
          provider: provider)).ok, isTrue);
      expect((await ensureUsableProfile(request: req(bundle: 'example.b'),
          provider: provider)).ok, isTrue);
      final third = await ensureUsableProfile(request: req(bundle: 'example.a'),
          provider: provider);
      expect(third.ok, isTrue);
      expect(third.didRegenerate, isFalse);
      expect(agc.createProfileCalls, 2);
    });

    test('ACL 取「包内声明 ∩ 白名单」的交集', () async {
      final agc = FakeAgc(
        certs: [
          CertInfo(
              id: 'c1',
              certName: kDebugCertName,
              certObjectId: 'obj-c1',
              certType: 1)
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];

      await ensureUsableProfile(
        request: req(perms: [
          // 在白名单里 → 应被提交
          'ohos.permission.READ_CONTACTS',
          'ohos.permission.READ_PASTEBOARD',
          // 不在白名单里 → 应被过滤掉
          'ohos.permission.KEEP_BACKGROUND_RUNNING',
          'ohos.permission.NOT_IN_WHITELIST',
        ]),
        provider: providerFor(agc),
      );

      expect(
        agc.lastAcls,
        containsAll([
          'ohos.permission.READ_CONTACTS',
          'ohos.permission.READ_PASTEBOARD',
        ]),
      );
      expect(agc.lastAcls, isNot(contains('ohos.permission.NOT_IN_WHITELIST')));
      expect(agc.lastAcls,
          isNot(contains('ohos.permission.KEEP_BACKGROUND_RUNNING')));
      // 记录一个实测事实：普通权限（如 INTERNET）不在该白名单内 ——
      // 这是照搬原实现的白名单，不是我们能决定的
      expect(defaultAcl, isNot(contains('ohos.permission.INTERNET')));
    });
  });

  group('证书处理', () {
    test('有同名调试证书时直接复用', () async {
      final agc = FakeAgc(
        certs: [
          CertInfo(
              id: 'reuse-me',
              certName: kDebugCertName,
              certObjectId: 'o',
              certType: 1),
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];

      await ensureUsableProfile(request: req(), provider: providerFor(agc));
      expect(agc.createCertCalls, 0);
      expect(agc.deleteCertCalls, 0);
    });

    test('完全没有证书时用 CSR 新建', () async {
      final agc = FakeAgc(
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];

      await ensureUsableProfile(request: req(), provider: providerFor(agc));
      expect(agc.createCertCalls, 1, reason: '无证书时应新建');
    });

    test('三槽已满但旧命名证书与私钥配对时直接复用', () async {
      final agc = FakeAgc(
        certs: [
          CertInfo(id: 'other-1', certName: 'DevEco', certObjectId: 'wrong-1', certType: 1),
          CertInfo(id: 'other-2', certName: 'Other', certObjectId: 'wrong-2', certType: 1),
          CertInfo(id: 'mine', certName: '旧版星仓', certObjectId: 'match', certType: 1),
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];
      final wrong = generateIdentity(subject: 'CN=other');
      agc.certBytesByObject = {
        for (final id in ['wrong-1', 'wrong-2'])
          id: ASN1Sequence(elements: [ASN1BitString(
              stringValues: publicKeyPointOfPrivateKey(wrong.privateKeyPem))]).encode(),
        'match': certBytes,
      };

      final provider = providerFor(agc);
      final result = await ensureUsableProfile(request: req(), provider: provider);
      expect(result.ok, isTrue);
      expect(provider.certId, 'mine');
      expect(agc.createCertCalls, 0);
      expect(agc.deleteCertCalls, 0);
    });

    test('仅剩一个槽位时安装流程不会静默新建证书', () async {
      final wrong = generateIdentity(subject: 'CN=other');
      final wrongCert = ASN1Sequence(elements: [ASN1BitString(
          stringValues: publicKeyPointOfPrivateKey(wrong.privateKeyPem))]).encode();
      final agc = FakeAgc(
        certs: [
          CertInfo(id: 'one', certName: 'one', certObjectId: 'one', certType: 1),
          CertInfo(id: 'two', certName: 'two', certObjectId: 'two', certType: 1),
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..certBytesByObject = {'one': wrongCert, 'two': wrongCert};

      final result = await ensureUsableProfile(request: req(),
          provider: providerFor(agc));
      expect(result.ok, isFalse);
      expect(result.error, contains('最后一个'));
      expect(agc.createCertCalls, 0);
    });

    test('CSR 读不到时给出可读错误（而不是静默失败）', () async {
      final agc = FakeAgc(
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];

      final provider = AgcProfileProvider(
        agc: agc,
        csrPath: '${tmp.path}/missing.csr',
        keyPath: keyPath,
        certPath: certPath,
        profileName: 'p',
      );

      final result =
          await ensureUsableProfile(request: req(), provider: provider);
      expect(result.ok, isFalse);
      expect(result.providerFailed, isTrue);
      expect(result.error, contains('CSR'));
    });

    test('证书数量达上限时不删除团队证书', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final agc = FakeAgc(
        certs: [
          CertInfo(
              id: 'old', certName: 'a', certObjectId: 'old', certType: 1, expireTime: now + 100),
          CertInfo(
              id: 'mid', certName: 'b', certObjectId: 'mid', certType: 1, expireTime: now + 200),
          CertInfo(
              id: 'new', certName: 'c', certObjectId: 'new', certType: 1, expireTime: now + 300),
        ],
        devices: [DeviceInfo(id: 'd1', udid: 'DEVICE-NEW')],
      )..profileUdids = ['DEVICE-NEW'];
      agc.certBytesByObject = {
        for (final id in ['old', 'mid', 'new'])
          id: ASN1Sequence(elements: [ASN1BitString(
            stringValues: publicKeyPointOfPrivateKey(
              generateIdentity(subject: 'CN=$id').privateKeyPem,
            ),
          )]).encode(),
      };

      final result =
          await ensureUsableProfile(request: req(), provider: providerFor(agc));

      expect(result.ok, isFalse);
      expect(result.error, contains('槽位已满'));
      expect(agc.deleteCertCalls, 0);
      expect(agc.createCertCalls, 0);
      expect(agc.certs.any((c) => c.id == 'old'), isTrue);
    });
  });

  group('未登录时的行为', () {
    test('未登录 → 明确报错，且不尝试任何 AGC 调用', () async {
      final agc = FakeAgc();
      agc.initUserInfo(null); // 模拟未登录

      final result = await ensureUsableProfile(
        request: req(),
        provider: providerFor(agc),
      );

      expect(result.ok, isFalse);
      expect(result.providerFailed, isTrue);
      expect(result.error, contains('登录'));
      expect(agc.createProfileCalls, 0, reason: '未登录不应发起 AGC 调用');
    });
  });
}
