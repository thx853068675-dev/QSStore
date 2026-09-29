import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { util } from '@kit.ArkTS';

/**
 * 本机生成 P-256 私钥与 PKCS#10 证书请求（CSR）。
 *
 * 为什么不用 HUKS：AGC 申请调试证书只收 CSR，而 CSR 必须由私钥现场签名。
 * HUKS 里的密钥默认导不出，`cert.generateCsr` 又只接受密钥数据本身，所以
 * 走 HUKS 就得把签名核心改成接受密钥句柄。这里改用系统 cryptoFramework
 * 生成可导出的 P-256 密钥，再用 `cert.generateCsr` 构造 CSR —— 两者都在
 * API 12 / 18 就有，实机（API 24）可用。
 *
 * 私钥只在本机内存与本应用沙箱内产生，不上传、不离开设备。
 */
export class DeviceKeyMaterial {
  /** 未加密的 PKCS#8 PEM：`-----BEGIN PRIVATE KEY-----`。 */
  privateKeyPem: string = '';
  /** `-----BEGIN CERTIFICATE REQUEST-----`。 */
  csrPem: string = '';
  /** 公钥 DER 的 SHA-256（十六进制），用来给同一把密钥起稳定的证书名。 */
  keyFingerprint: string = '';
}

/// CSR 主体。AGC 不校验这里的内容，保持与云端签名身份格式一致即可。
const CSR_SUBJECT = '/C=CN/O=Qingqi/OU=Device/CN=qingqi-installer';
const CERT_NAME_PREFIX = 'qingqi-debug';

function derToPem(label: string, der: Uint8Array): string {
  const base64 = new util.Base64Helper().encodeToStringSync(der);
  let body = '';
  for (let i = 0; i < base64.length; i += 64) {
    body += base64.substring(i, i + 64) + '\n';
  }
  return '-----BEGIN ' + label + '-----\n' + body + '-----END ' + label + '-----\n';
}

function hex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

function asPemText(csr: string | Uint8Array): string {
  return typeof csr === 'string' ? csr :
    util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(csr);
}

/**
 * 用私钥数据构造 CSR。
 *
 * `PrivateKeyInfo.key` 同时收 PEM 字符串与 DER 字节，但不同版本对「哪种」的
 * 容忍度不一致。先按 PEM 试，抛错再退回 PKCS#8 DER 字节 —— 两条路产生的是
 * 同一个请求，谁先成功就用谁。
 */
async function buildCsr(privateKeyPem: string, privateKeyDer: Uint8Array): Promise<string> {
  const subject = await cert.createX500DistinguishedName(CSR_SUBJECT);
  const config: cert.CsrGenerationConfig = {
    subject: subject,
    mdName: 'SHA256',
    outFormat: cert.EncodingBaseFormat.PEM
  };
  let csr = '';
  try {
    csr = asPemText(cert.generateCsr({ key: privateKeyPem }, config));
  } catch (_) {
    csr = asPemText(cert.generateCsr({ key: privateKeyDer }, config));
  }
  if (!/^-----BEGIN CERTIFICATE REQUEST-----/.test(csr)) {
    throw new Error('系统未返回有效的证书请求');
  }
  return csr;
}

export class DeviceIdentity {
  /// 生成一对新的 P-256 密钥并构造对应 CSR。调用方负责落盘与配对校验。
  static async generate(): Promise<DeviceKeyMaterial> {
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    const pair = await generator.generateKeyPair();
    const privateKeyDer = pair.priKey.getEncodedDer('PKCS8').data;
    const privateKeyPem = derToPem('PRIVATE KEY', privateKeyDer);
    // 公钥用 SPKI DER：AGC 与 keyMatchesCertificate 都按标准 X.509 解析。
    const publicKeyDer = pair.pubKey.getEncodedDer('X509').data;
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: publicKeyDer });
    const fingerprint = hex((await md.digest()).data);

    const material = new DeviceKeyMaterial();
    material.privateKeyPem = privateKeyPem;
    material.csrPem = await buildCsr(privateKeyPem, privateKeyDer);
    material.keyFingerprint = fingerprint;
    if (!/^-----BEGIN PRIVATE KEY-----/.test(material.privateKeyPem) ||
      material.privateKeyPem.length > 4096) {
      throw new Error('本机生成的私钥格式无效');
    }
    if (material.csrPem.length > 8192) {
      throw new Error('本机生成的证书请求过长');
    }
    return material;
  }

  /**
   * 证书名带私钥指纹：同一把密钥永远得到同一个名字，便于在 AGC 控制台辨认，
   * 也让人工清理时知道哪张证书属于这台设备。
   */
  static async certNameFor(privateKeyPem: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(privateKeyPem) });
    const suffix = hex((await md.digest()).data).substring(0, 10);
    return suffix.length === 10 ? CERT_NAME_PREFIX + '-' + suffix : CERT_NAME_PREFIX;
  }

  /// 已有私钥补建 CSR。入参是未加密的 PKCS#8 PEM。
  static async csrFor(privateKeyPem: string): Promise<string> {
    if (!/^-----BEGIN PRIVATE KEY-----/.test(privateKeyPem)) {
      throw new Error('本机私钥格式不是未加密的 PKCS#8，无法补建证书请求');
    }
    return buildCsr(privateKeyPem, pemBodyToDer(privateKeyPem));
  }
}

/// 取出 PEM 正文的 DER 字节，供只接受字节的接口使用。
function pemBodyToDer(pem: string): Uint8Array {
  const match = /-----BEGIN [A-Z0-9 ]+-----([\s\S]*?)-----END [A-Z0-9 ]+-----/.exec(pem);
  const body = (match ? match[1] : pem).replace(/\s/g, '');
  return new util.Base64Helper().decodeSync(body);
}
