// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 纯 Dart 签名身份生成的测试。
//
// 这组测试保护的是一个**替代方案**：设备内签名器的 `generate-keypair`
// 与 `generate-csr` 报告成功却不产出文件（桌面与手机同源、同样如此），
// 因此改为纯 Dart 生成密钥与 CSR（见 identity_generator.dart）。
//
// 关键验证点：
//   · 结构正确：PEM 头尾齐全、可被解析
//   · **密码学正确**：CSR 的自签名必须能被对应公钥验证通过
//   · **唯一性**：每次生成都不同 —— 这正是修掉「所有用户共用一把私钥」的关键

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/state/identity_generator.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// PEM → DER
Uint8List derOf(String pem) {
  final body = pem
      .split('\n')
      .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
      .join();
  return base64.decode(body);
}

/// 从 PKCS#8 PEM 还原私钥标量。
///
/// 不走 `ASN1PrivateKeyInfo.fromEccPem`：它在解析**带公钥的** SEC1 结构时
/// 会把 `[1]` 标签强转成 OctetString 而抛错（pointycastle 3.7.3 的缺陷）。
BigInt privateScalarOf(String pem) {
  final top = ASN1Parser(derOf(pem)).nextObject() as ASN1Sequence;
  final innerOctets = (top.elements![2] as ASN1OctetString).octets!;
  final inner = ASN1Parser(innerOctets).nextObject() as ASN1Sequence;
  final keyBytes = inner.elements![1] as ASN1OctetString;

  return BigInt.parse(
    keyBytes.octets!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
    radix: 16,
  );
}

ASN1Sequence csrSeqOf(String pem) =>
    ASN1Parser(derOf(pem)).nextObject() as ASN1Sequence;

/// CertificationRequestInfo（4 个元素：version/subject/pkInfo/[0]）
ASN1Sequence csrInfoOf(ASN1Sequence csr) =>
    ASN1Parser((csr.elements![0] as ASN1Sequence).encode()).nextObject()
        as ASN1Sequence;

String csrSubjectValues(ASN1Sequence csr) {
  final subject = ASN1Parser(csrInfoOf(csr).elements![1].encode()).nextObject()
      as ASN1Sequence;
  final out = <String>[];
  for (final rdnRaw in subject.elements!) {
    final set = ASN1Parser(rdnRaw.encode()).nextObject() as ASN1Set;
    for (final atvRaw in set.elements!) {
      final atv = ASN1Parser(atvRaw.encode()).nextObject() as ASN1Sequence;
      final v = atv.elements![1];
      if (v is ASN1UTF8String) out.add(v.utf8StringValue ?? '');
      if (v is ASN1PrintableString) out.add(v.stringValue ?? '');
    }
  }
  return out.join('|');
}

Uint8List csrPubKey(ASN1Sequence csr) {
  final spki = ASN1Parser(csrInfoOf(csr).elements![2].encode()).nextObject()
      as ASN1Sequence;
  return Uint8List.fromList(
      (spki.elements![1] as ASN1BitString).stringValues!);
}

ECSignature csrSignature(ASN1Sequence csr) {
  final bs = csr.elements![2] as ASN1BitString;
  final sig = ASN1Parser(Uint8List.fromList(bs.stringValues!)).nextObject()
      as ASN1Sequence;
  return ECSignature(
    (sig.elements![0] as ASN1Integer).integer!,
    (sig.elements![1] as ASN1Integer).integer!,
  );
}

void main() {
  final curve = ECCurve_secp256r1();

  group('生成的产物结构', () {
    test('PEM 头尾齐全', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,OU=Device,CN=t');

      expect(id.privateKeyPem, startsWith('-----BEGIN PRIVATE KEY-----'));
      expect(id.privateKeyPem, contains('-----END PRIVATE KEY-----'));
      expect(id.csrPem, startsWith('-----BEGIN CERTIFICATE REQUEST-----'));
      expect(id.csrPem, contains('-----END CERTIFICATE REQUEST-----'));
      expect(id.subject, 'C=CN,O=HapStore,OU=Device,CN=t');
    });

    test('短于 256 字符的合法 P-256 私钥仍可复用', () {
      final id = generateIdentity(subject: 'CN=identity-reuse');
      expect(id.privateKeyPem.length, lessThan(256));
      expect(isUsableIdentityKey(id.privateKeyPem), isTrue);
      expect(isUsableIdentityKey('not a private key'), isFalse);
    });

    test('CSR 丢失后用原私钥补建，不产生新的证书身份', () {
      final identity = generateIdentity(subject: 'CN=keep-key');
      final recovered = generateCsrForPrivateKey(identity.privateKeyPem,
          subject: 'CN=keep-key');
      expect(isCsrKeyPaired(
          privateKeyPem: identity.privateKeyPem, csrPem: recovered), isTrue);
      expect(csrPubKey(csrSeqOf(recovered)),
          publicKeyPointOfPrivateKey(identity.privateKeyPem));
    });

    test('私钥是合法的 P-256 标量', () {
      final id = generateIdentity(subject: 'C=CN,O=X,CN=parse');
      final d = privateScalarOf(id.privateKeyPem);

      expect(d > BigInt.zero, isTrue);
      expect(d < curve.n, isTrue, reason: '私钥必须落在 [1, n) 内');
    });

    test('主题缺项时不崩', () {
      final id = generateIdentity(subject: 'CN=only-cn');
      expect(id.csrPem, contains('CERTIFICATE REQUEST'));
      expect(csrSubjectValues(csrSeqOf(id.csrPem)), contains('only-cn'));
    });
  });

  group('CSR 内容正确', () {
    test('主题包含传入的各项', () {
      final id = generateIdentity(
          subject: 'C=CN,O=HapStore,OU=Device,CN=starhub-test');
      final values = csrSubjectValues(csrSeqOf(id.csrPem));

      expect(values, contains('starhub-test'));
      expect(values, contains('HapStore'));
      expect(values, contains('Device'));
    });

    test('★ CSR 里的公钥与私钥一致', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=match');
      final d = privateScalarOf(id.privateKeyPem);
      final expected = Uint8List.fromList((curve.G * d)!.getEncoded(false));

      expect(csrPubKey(csrSeqOf(id.csrPem)), equals(expected));
    });

    test('★ CSR 的自签名可被对应公钥验证通过（密码学正确性）', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=verify');
      final csr = csrSeqOf(id.csrPem);

      final d = privateScalarOf(id.privateKeyPem);
      final pub = ECPublicKey(curve.G * d, curve);

      final signed = csrInfoOf(csr).encode();

      // 验证器必须与签名器用同一种摘要形式：生成侧用
      // `ECDSASigner(SHA256Digest(), ...)`（内部对消息做 SHA-256），
      // 所以这里也要给 digest，否则是对原始字节做验证，必然失败。
      final verifier = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64));
      verifier.init(false, PublicKeyParameter<ECPublicKey>(pub));

      // ECDSA 的 (r, s) 与 (r, n-s) 数学上等价，验证器需接受两种形式。
      // 实现侧已归一化到 low-s（OpenSSL 只接受 low-s）。
      var sig = csrSignature(csr);
      var ok = verifier.verifySignature(Uint8List.fromList(signed), sig);
      if (!ok) {
        sig = ECSignature(sig.r, curve.n - sig.s);
        ok = verifier.verifySignature(Uint8List.fromList(signed), sig);
      }

      expect(ok, isTrue,
          reason: 'CSR 自签名必须验证通过，否则 AGC 会拒绝该证书请求');
    });

    test('签名算法标识是 ecdsa-with-SHA256', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=alg');
      final csr = csrSeqOf(id.csrPem);
      final alg = ASN1Parser((csr.elements![1] as ASN1Sequence).encode())
          .nextObject() as ASN1Sequence;
      final oid = alg.elements![0] as ASN1ObjectIdentifier;

      expect(oid.objectIdentifierAsString, '1.2.840.10045.4.3.2');
    });
  });

  group('唯一性', () {
    test('★ 每次生成的私钥都不同', () {
      final a = generateIdentity(subject: 'C=CN,O=HapStore,CN=uniq');
      final b = generateIdentity(subject: 'C=CN,O=HapStore,CN=uniq');

      expect(a.privateKeyPem, isNot(equals(b.privateKeyPem)),
          reason: '私钥必须每次唯一 —— 这正是修掉「所有用户共用一把私钥」的关键');
      expect(a.csrPem, isNot(equals(b.csrPem)));
    });

    test('批量生成无重复', () {
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=batch');
        expect(seen.add(id.privateKeyPem), isTrue, reason: '出现重复私钥');
      }
    });
  });

  group('私钥 ↔ 证书 配对校验', () {
    // 造一份「证书」字节：只要首字节是 SEQUENCE、且内部含公钥点即可 ——
    // 配对判断是在证书字节里子串查找私钥对应的公钥点，不解析 X.509 结构。
    Uint8List certWithPoint(Uint8List point) =>
        ASN1Sequence(elements: [ASN1BitString(stringValues: point)]).encode();

    // 把多份 DER 拼成 PEM 证书链（root 在前，模拟 AGC 的下发顺序）。
    Uint8List pemChain(List<Uint8List> ders) {
      final sb = StringBuffer();
      for (final d in ders) {
        final b64 = base64.encode(d);
        sb.write('-----BEGIN CERTIFICATE-----\n');
        for (var i = 0; i < b64.length; i += 64) {
          final end = (i + 64 < b64.length) ? i + 64 : b64.length;
          sb.writeln(b64.substring(i, end));
        }
        sb.write('-----END CERTIFICATE-----\n');
      }
      return Uint8List.fromList(utf8.encode(sb.toString()));
    }

    Uint8List pointOf(int fill) =>
        Uint8List.fromList([4, ...List.filled(64, fill)]);

    test('从私钥推导的公钥点与 CSR 内公钥一致', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=pair');
      expect(publicKeyPointOfPrivateKey(id.privateKeyPem),
          equals(csrPubKey(csrSeqOf(id.csrPem))));
    });

    test('★ 配对时返回 true、不配对时返回 false', () {
      final a = generateIdentity(subject: 'C=CN,O=HapStore,CN=a');
      final b = generateIdentity(subject: 'C=CN,O=HapStore,CN=b');
      final certA = certWithPoint(publicKeyPointOfPrivateKey(a.privateKeyPem));

      expect(isKeyCertPaired(privateKeyPem: a.privateKeyPem, certificate: certA),
          isTrue);
      expect(isKeyCertPaired(privateKeyPem: b.privateKeyPem, certificate: certA),
          isFalse);
    });

    test('★ 证书链 root 在前、且叶子不是第一张时，仍能判定配对', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=leaf');
      final leafPoint = publicKeyPointOfPrivateKey(id.privateKeyPem);

      // AGC 下发的是 root → intermediate → leaf（叶子在最后）。
      final chain = pemChain([
        certWithPoint(pointOf(1)),
        certWithPoint(pointOf(2)),
        certWithPoint(leafPoint),
      ]);

      expect(
          isKeyCertPaired(privateKeyPem: id.privateKeyPem, certificate: chain),
          isTrue);
    });

    test('裸 DER（非 PEM）也能判定', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=dER');
      final der = certWithPoint(publicKeyPointOfPrivateKey(id.privateKeyPem));
      expect(isKeyCertPaired(privateKeyPem: id.privateKeyPem, certificate: der),
          isTrue);
    });

    test('证书无法识别时返回 null（不误判为不配对）', () {
      final id = generateIdentity(subject: 'C=CN,O=HapStore,CN=nil');
      expect(
          isKeyCertPaired(
              privateKeyPem: id.privateKeyPem,
              certificate: utf8.encode('not a certificate')),
          isNull);
    });

    // 真实材料回归：本机 key.pem 与 xiaobai-debug.cer 必须是配对的
    //（这正是「签名成功却装不上」的根因所在）。文件不存在时跳过。
    test('真实 key.pem 与 xiaobai-debug.cer 判定为配对', () {
      final home = Platform.environment['HOME'] ?? '';
      final store = '$home/Documents/hap_installer/store';
      final key = File('$store/key.pem');
      final cert = File('$store/xiaobai-debug.cer');
      if (!key.existsSync() || !cert.existsSync()) return;

      final paired = isKeyCertPaired(
        privateKeyPem: key.readAsStringSync(),
        certificate: cert.readAsBytesSync(),
      );
      expect(paired, isTrue, reason: 'key.pem 必须与 xiaobai-debug.cer 配对');
    });
  });
}
