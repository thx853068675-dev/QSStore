// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 纯 Dart 生成签名身份：ECDSA P-256 密钥对 + PKCS#10 证书请求（CSR）。
//
// ── 为什么不用设备上的原生签名器 ──────────────────────────────────────
// 设备内的签名器（`libsigner.so` / `libgo_signer.so`）**带**这两个子命令，
// 但实测它们**报告成功却不产出任何文件**：
//
//     $ signer generate-keypair -keyAlias t1 -keyAlg ECC -keySize NIST-P-256 \
//         -keystoreFile a.jks -keystorePwd pw
//     stderr: Start generate-keypair
//     stderr: generate-keypair success        ← 报告成功
//     $ ls a.jks
//     ls: a.jks: No such file or directory    ← 但文件不存在
//
// `generate-csr` 同样如此。**桌面版与手机版是同一份代码、行为一致**，
// 所以这不是打包或路径问题，而是该第三方签名器的缺陷。
//
// 对照：官方 `hap-sign-tool.jar` 的同一命令工作正常，但手机上跑 Java 需要
// JVM（`libjavacmd.so`），而该库在原工程里从未被提供（只有头文件）。
//
// ── 于是改为纯 Dart ───────────────────────────────────────────────────
// `pointycastle` 是纯 Dart 实现，自带 ASN.1 / PKCS#10 / X.501 / ECC /
// ECDSA / SecureRandom，不依赖任何原生库。好处：
//   · **每台设备唯一**（原「小白」把私钥随包分发，所有用户共用一把）
//   · 私钥只在本机内存与沙箱内产生，从不出设备
//   · 既不依赖签名器的缺陷命令，也不依赖 OpenSSL
//
// ── 输出格式 ──────────────────────────────────────────────────────────
// 私钥写成**未加密的 PKCS#8 PEM**（`-----BEGIN PRIVATE KEY-----`），
// 与原「小白」随包分发的 `key.pem` 同格式 —— 签名器按 PEM 解析，
// `-keystorePwd` 传占位值即可。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// 生成结果。
class GeneratedIdentity {
  GeneratedIdentity({
    required this.privateKeyPem,
    required this.csrPem,
    required this.subject,
  });

  /// 未加密 PKCS#8 PEM 私钥。
  final String privateKeyPem;

  /// PKCS#10 PEM 证书请求。
  final String csrPem;

  final String subject;
}

/// OID 常量（避免依赖 OID 数据库里的名称拼写）。
const String _oidEcPublicKey = '1.2.840.10045.2.1';
const String _oidPrime256v1 = '1.2.840.10045.3.1.7';
const String _oidEcdsaWithSha256 = '1.2.840.10045.4.3.2';

/// X.500 属性的 OID。
const Map<String, String> _x500Oids = {
  'C': '2.5.4.6',
  'ST': '2.5.4.8',
  'L': '2.5.4.7',
  'O': '2.5.4.10',
  'OU': '2.5.4.11',
  'CN': '2.5.4.3',
};

/// 生成一对 ECDSA P-256 密钥与对应的 CSR。
///
/// [subject] 用 OpenSSL 风格：`C=CN,O=HapStore,OU=Device,CN=xxx`。
GeneratedIdentity generateIdentity({required String subject}) {
  // ── 1. 密钥对（P-256，与 AGC 要求一致）─────────────────────────
  final random = _secureRandom();
  final keyGen = ECKeyGenerator()
    ..init(ParametersWithRandom(
      ECKeyGeneratorParameters(ECCurve_secp256r1()),
      random,
    ));
  final pair = keyGen.generateKeyPair();
  final priv = pair.privateKey as ECPrivateKey;
  final pub = pair.publicKey as ECPublicKey;

  final algoId = _algorithmIdentifier();

  // ── 2. 私钥 → PKCS#8 PEM ───────────────────────────────────────
  // PKCS#8 的 privateKey 字段是 OCTET STRING，内部装 SEC1 的 ECPrivateKey
  final ecPrivateKey = _ecPrivateKeySeq(priv, pub);
  final pkcs8 = ASN1PrivateKeyInfo(
    ASN1Integer(BigInt.zero),
    algoId,
    ASN1OctetString(octets: ecPrivateKey.encode()),
  );
  final privPem = _pem('PRIVATE KEY', pkcs8.encode());

  return GeneratedIdentity(
    privateKeyPem: privPem,
    csrPem: _csrForKey(priv, pub, subject, random),
    subject: subject,
  );
}

/// 从现有私钥补建 CSR。丢失 CSR 时必须保留私钥，否则会占用新的 AGC 证书槽位。
String generateCsrForPrivateKey(String privateKeyPem, {required String subject}) {
  final top = _seq(_derFromPem(privateKeyPem));
  final inner = _seq((top.elements![2] as ASN1OctetString).octets!);
  final raw = (inner.elements![1] as ASN1OctetString).octets!;
  final d = BigInt.parse(
    raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
  final curve = ECCurve_secp256r1();
  if (d <= BigInt.zero || d >= curve.n) {
    throw const FormatException('无效的 P-256 私钥');
  }
  final priv = ECPrivateKey(d, curve);
  final pub = ECPublicKey(curve.G * d, curve);
  return _csrForKey(priv, pub, subject, _secureRandom());
}

String _csrForKey(
    ECPrivateKey priv, ECPublicKey pub, String subject, SecureRandom random) {
  // ── CSR（PKCS#10）──────────────────────────────────────────
  final pubPoint = Uint8List.fromList(pub.Q!.getEncoded(false));
  final spki = ASN1SubjectPublicKeyInfo(
    _algorithmIdentifier(),
    ASN1BitString(stringValues: pubPoint),
  );

  final info = ASN1CertificationRequestInfo(
    ASN1Integer(BigInt.zero),
    _x500Name(subject),
    spki,
    // attributes 传 null → 编码为空的 [0] 包装，符合 PKCS#10
  );
  final infoDer = info.encode();

  final sig = _sign(infoDer, priv, random);
  final csr = ASN1CertificationRequest(
    ASN1Object.fromBytes(infoDer),
    ASN1AlgorithmIdentifier(
      ASN1ObjectIdentifier(_oid(_oidEcdsaWithSha256)),
    ),
    ASN1BitString(stringValues: sig),
  );

  return _pem('CERTIFICATE REQUEST', csr.encode());
}

/// `"1.2.840.10045.2.1"` → `[1, 2, 840, 10045, 2, 1]`
List<int> _oid(String dotted) =>
    dotted.split('.').map(int.parse).toList(growable: false);

/// 密码学安全的随机源（种子取自 `Random.secure()`）。
SecureRandom _secureRandom() {
  final seed = Uint8List(32);
  final rnd = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = rnd.nextInt(256);
  }
  return FortunaRandom()..seed(KeyParameter(seed));
}

/// `SEQUENCE { OID id-ecPublicKey, OID prime256v1 }`
ASN1AlgorithmIdentifier _algorithmIdentifier() => ASN1AlgorithmIdentifier(
      ASN1ObjectIdentifier(_oid(_oidEcPublicKey)),
      parameters: ASN1ObjectIdentifier(_oid(_oidPrime256v1)),
    );

/// SEC1 ECPrivateKey：
/// `SEQUENCE { INTEGER 1, OCTET STRING key, [1] BIT STRING publicKey }`
ASN1Sequence _ecPrivateKeySeq(ECPrivateKey priv, ECPublicKey pub) {
  final point = Uint8List.fromList(pub.Q!.getEncoded(false));

  // [1] 是**显式**标签：内容是一整个 BIT STRING 的编码。
  // 对照 OpenSSL 生成的 SEC1：
  //   38:d=1  cons: cont [ 1 ]
  //   52:d=2  prim: BIT STRING
  final bitString = ASN1BitString(stringValues: point);
  final bsBytes = bitString.encode();
  final wrapper = ASN1Object(tag: 0xA1)
    ..valueBytes = bsBytes
    ..valueByteLength = bsBytes.length;

  return ASN1Sequence(elements: [
    ASN1Integer(BigInt.one),
    ASN1OctetString(octets: _fixedLength(priv.d!, 32)),
    wrapper,
  ]);
}

/// ECDSA 签名，输出 DER 的 `SEQUENCE { r, s }`。
Uint8List _sign(Uint8List data, ECPrivateKey priv, SecureRandom random) {
  // 用 ECDSASigner 的 (digest, kMac) 形式：ECDSASigner 内部会用 digest
  // 计算消息哈希后签名。这也让它能自行推导哈希长度。
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, ParametersWithRandom(
      PrivateKeyParameter<ECPrivateKey>(priv),
      random,
    ));

  final sig = signer.generateSignature(data) as ECSignature;

  // 归一化到 low-s：ECDSA 的 (r, s) 与 (r, n-s) 都数学有效，
  // 但 OpenSSL 等验证方可能只接受 low-s。
  final normalized = sig.normalize(priv.parameters!);

  return ASN1Sequence(elements: [
    ASN1Integer(normalized.r),
    ASN1Integer(normalized.s),
  ]).encode();
}

/// X.500 Name：`C=CN,O=Org,OU=Unit,CN=Name`
ASN1Name _x500Name(String subject) {
  final rdns = <ASN1RDN>[];
  for (final part in subject.split(',')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final key = part.substring(0, idx).trim();
    final value = part.substring(idx + 1).trim();
    final oid = _x500Oids[key];
    if (oid == null || value.isEmpty) continue;

    rdns.add(ASN1RDN(ASN1Set(elements: [
      ASN1AttributeTypeAndValue(
        ASN1ObjectIdentifier(_oid(oid)),
        ASN1UTF8String(utf8StringValue: value),
      )
    ])));
  }
  return ASN1Name(rdns);
}

/// 把大端整数补成固定长度（ECDSA 私钥必须定长）。
Uint8List _fixedLength(BigInt v, int len) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  var bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  if (bytes.length > len) {
    bytes = bytes.sublist(bytes.length - len);
  } else if (bytes.length < len) {
    bytes = List<int>.filled(len - bytes.length, 0) + bytes;
  }
  return Uint8List.fromList(bytes);
}

/// 转成 PEM。
String _pem(String label, Uint8List der) {
  final b64 = base64.encode(der);
  final buf = StringBuffer('-----BEGIN $label-----\n');
  for (var i = 0; i < b64.length; i += 64) {
    final end = (i + 64 < b64.length) ? i + 64 : b64.length;
    buf.writeln(b64.substring(i, end));
  }
  buf.write('-----END $label-----\n');
  return buf.toString();
}

// ──────────────────────────────────────────────────────────────────────
// 配对校验：私钥 ↔ 证书
//
// 复用已有证书前必须先确认它确实由当前私钥签发 —— 否则签名会「成功」，
// 但产物在设备侧因证书与密钥不匹配而装不上（9568322 一类）。
// 这里只做**公钥比对**：从私钥推导公钥点，从证书取出 SubjectPublicKeyInfo
// 的公钥点，两者必须逐字节相同。
// ──────────────────────────────────────────────────────────────────────

/// 从**未加密的 PKCS#8 PEM** 私钥推导对应的 P-256 公钥点（未压缩，65 字节）。
///
/// 不走 `ASN1PrivateKeyInfo.fromEccPem` —— 它在解析带公钥的 SEC1 结构时
/// 会把 `[1]` 标签强转成 OctetString 而抛错（pointycastle 3.7.3 的缺陷）。
Uint8List publicKeyPointOfPrivateKey(String pem) {
  final top = _seq(_derFromPem(pem));
  final inner = _seq((top.elements![2] as ASN1OctetString).octets!);
  final raw = (inner.elements![1] as ASN1OctetString).octets!;
  final d = BigInt.parse(
    raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
  final curve = ECCurve_secp256r1();
  return Uint8List.fromList((curve.G * d)!.getEncoded(false));
}

/// 复用本机身份时按密钥内容校验，不按 PEM 字符长度判断。
/// P-256 私钥通常只有约 241 字符，长度阈值会误删有效身份。
bool isUsableIdentityKey(String pem) {
  try {
    return publicKeyPointOfPrivateKey(pem).length == 65;
  } catch (_) {
    return false;
  }
}

/// CSR 内的公钥必须与本机私钥对应；旧 CSR 损坏时只补建 CSR。
bool isCsrKeyPaired({required String privateKeyPem, required String csrPem}) {
  try {
    final point = publicKeyPointOfPrivateKey(privateKeyPem);
    return csrPem.contains('-----BEGIN CERTIFICATE REQUEST-----') &&
        _indexOfBytes(_derFromPem(csrPem), point) >= 0;
  } catch (_) {
    return false;
  }
}

/// 判定私钥与证书是否配对。
///
/// ── 为什么用「字节子串」而不是解析 X.509 ────────────────────────────────
/// 需要判断的其实只有一件事：证书里承载的公钥是否等于私钥对应的公钥。
/// 而私钥能直接推出**未压缩公钥点**（65 字节，`0x04‖X‖Y`），这个字节串在
/// 配对证书的 SubjectPublicKeyInfo 里必然原样出现。
///
/// 直接在整个证书字节里查找它，比逐步解析 ASN.1 更稳：
///   · 不依赖证书链的顺序（AGC 下发的是 root→intermediate→leaf，根在前）
///   · 不依赖 pointycastle 对「含 SET 的 SEQUENCE」重新编码 —— 实测它会把
///     subject/issuer 与相邻元素错误合并，导致取错元素
///   · PEM / 裸 DER / 多张链都一视同仁
///
/// 返回 true/false 表示已判定；**null 表示无法判定**（拿不到私钥，或证书
/// 字节里连一张可识别的证书都没有），调用方此时不应作废材料。
bool? isKeyCertPaired({
  required String privateKeyPem,
  required List<int> certificate,
}) {
  final Uint8List keyPoint;
  try {
    keyPoint = publicKeyPointOfPrivateKey(privateKeyPem);
  } catch (_) {
    return null;
  }
  if (keyPoint.isEmpty) return null;

  // 可识别的证书内容：PEM 里的每张证书，或一份裸 DER。
  final blobs = _certificateDers(certificate);
  if (blobs.isEmpty) {
    if (certificate.isNotEmpty && certificate[0] == 0x30) {
      blobs.add(Uint8List.fromList(certificate));
    } else {
      return null; // 无法识别，交给调用方按「可通过」处理
    }
  }

  for (final b in blobs) {
    if (_indexOfBytes(b, keyPoint) >= 0) return true;
  }
  return false;
}

/// 在 [hay] 中查找 [needle] 首次出现的位置；未找到返回 -1。
int _indexOfBytes(List<int> hay, List<int> needle) {
  if (needle.isEmpty || needle.length > hay.length) return -1;
  final first = needle[0];
  for (var i = 0; i + needle.length <= hay.length; i++) {
    if (hay[i] != first) continue;
    var ok = true;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// PEM → DER。
///
/// 只取 `-----BEGIN ...-----` 与 `-----END ...-----` 之间的 base64。
/// 不能简单地「丢掉带 ----- 的行」—— 真实私钥文件常带 OpenSSL 的
/// `Bag Attributes` / `friendlyName:` 等文本头（key.pem 就是这种），
/// 那些行不是 base64，会让解码失败。
Uint8List _derFromPem(String pem) {
  final m = RegExp(r'-----BEGIN [A-Z0-9 ]+-----([\s\S]*?)-----END [A-Z0-9 ]+-----')
      .firstMatch(pem);
  final body = m != null ? m.group(1)! : pem;
  return base64.decode(body.replaceAll(RegExp(r'\s'), ''));
}

ASN1Sequence _seq(List<int> der) =>
    ASN1Parser(Uint8List.fromList(der)).nextObject() as ASN1Sequence;

/// 把「PEM 证书链 / 裸 DER」统一成一份或多份证书 DER。
List<Uint8List> _certificateDers(List<int> bytes) {
  if (bytes.isNotEmpty && bytes[0] == 0x30) {
    return [Uint8List.fromList(bytes)]; // 裸 DER：首字节即 SEQUENCE 标签
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    return const [];
  }
  final out = <Uint8List>[];
  final re = RegExp(
      r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----');
  for (final m in re.allMatches(text)) {
    try {
      out.add(base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), '')));
    } catch (_) {
      // 跳过解析失败的段落
    }
  }
  return out;
}
