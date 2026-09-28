import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/agc/agc_models.dart';
import 'package:hapstore/state/agc/agc_service.dart';
import 'package:hapstore/state/identity_generator.dart';
import 'package:hapstore/state/sign_material_store.dart';
import 'package:pointycastle/asn1.dart';

class _RestoreAgc extends AgcService {
  _RestoreAgc(this.certs, this.bytesByObject) {
    initUserInfo(AuthInfo(accessToken: 'token', userId: 'account'));
  }

  final List<CertInfo> certs;
  final Map<String, List<int>> bytesByObject;
  int createCalls = 0;
  int deleteCalls = 0;

  @override
  Future<List<CertInfo>> getCertList() async => certs;

  @override
  Future<List<UrlInfo>> downloadObj(String objId) async =>
      [UrlInfo(newUrl: 'https://example.invalid/$objId')];

  @override
  Future<bool> downloadFile(String url, String savePath) async {
    await File(savePath).writeAsBytes(
        bytesByObject[Uri.parse(url).pathSegments.last]!, flush: true);
    return true;
  }

  @override
  Future<CertInfo> createCert(String name, int type, String csr) async {
    createCalls++;
    throw StateError('恢复过程不应创建证书');
  }

  @override
  Future<void> deleteCertList(List<String> ids) async {
    deleteCalls++;
    throw StateError('恢复过程不应删除证书');
  }
}

List<int> _certificateFor(String pem) {
  final der = ASN1Sequence(elements: [
    ASN1BitString(stringValues: publicKeyPointOfPrivateKey(pem)),
  ]).encode();
  final encoded = base64.encode(der);
  // 与 AGC 返回的 PEM 证书链一样，长度足以通过材料文件校验。
  return utf8.encode(List.generate(3, (_) =>
      '-----BEGIN CERTIFICATE-----\n$encoded\n-----END CERTIFICATE-----\n').join());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ohos_adapter');
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('starstore-restore-');
    TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'appDir') return dir.path;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  test('满槽位时复用配对证书，保留不配对证书且不申请新证书', () async {
    final store = await SignMaterialStore.load();
    expect(await store.ensureIdentity(), isNull);
    final original = await File(store.config.keystoreFile).readAsString();
    final imported = generateIdentity(subject: 'C=CN,O=Test,CN=existing');
    final unrelated = generateIdentity(subject: 'C=CN,O=Test,CN=other');
    final service = _RestoreAgc([
      CertInfo(id: 'other', certObjectId: 'other', certType: 1),
      CertInfo(id: 'matched', certObjectId: 'matched', certType: 1),
      CertInfo(id: 'third', certObjectId: 'third', certType: 1),
    ], {
      'other': _certificateFor(unrelated.privateKeyPem),
      'matched': _certificateFor(imported.privateKeyPem),
      'third': _certificateFor(unrelated.privateKeyPem),
    });
    store.agc = service;

    expect(await store.restoreExistingIdentity(imported.privateKeyPem), isNull);
    expect(store.certId, 'matched');
    expect(await File(store.config.keystoreFile).readAsString(),
        imported.privateKeyPem);
    expect(isCsrKeyPaired(
        privateKeyPem: imported.privateKeyPem,
        csrPem: await File(store.config.csrPath).readAsString()), isTrue);
    expect(await File('${dir.path}/identity/identity.pem.before-restore')
        .readAsString(), original);
    expect(service.createCalls, 0);
    expect(service.deleteCalls, 0);
  });

  test('不配对时不更改本机私钥和证书 ID', () async {
    final store = await SignMaterialStore.load();
    expect(await store.ensureIdentity(), isNull);
    final original = await File(store.config.keystoreFile).readAsString();
    final imported = generateIdentity(subject: 'C=CN,O=Test,CN=wrong');
    store.agc = _RestoreAgc([
      CertInfo(id: 'unrelated', certObjectId: 'unrelated', certType: 1),
    ], {'unrelated': _certificateFor(original)});

    expect(await store.restoreExistingIdentity(imported.privateKeyPem),
        contains('均不匹配'));
    expect(await File(store.config.keystoreFile).readAsString(), original);
    expect(store.certId, isEmpty);
  });

  test('复用同一私钥时清理重复的明文回退文件', () async {
    final store = await SignMaterialStore.load();
    expect(await store.ensureIdentity(), isNull);
    final original = await File(store.config.keystoreFile).readAsString();
    store.agc = _RestoreAgc([
      CertInfo(id: 'same', certObjectId: 'same', certType: 1),
    ], {'same': _certificateFor(original)});

    expect(await store.restoreExistingIdentity(original), isNull);
    expect(await File('${dir.path}/identity/identity.pem.before-restore').exists(),
        isFalse);
  });
}
