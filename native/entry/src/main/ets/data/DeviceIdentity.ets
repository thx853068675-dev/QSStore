import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { generateCsr } from 'libhap_core.so';

/**
 * 本机生成 P-256 私钥与 PKCS#10 证书请求（CSR）。
 *
 * 为什么不用 HUKS：AGC 申请调试证书只收 CSR，而 CSR 必须由私钥现场签名。
 * HUKS 里的密钥默认导不出，这里用系统 cryptoFramework 生成可导出的
 * 新生成 P-256 密钥；已有 P-256/P-384 私钥都可补建 CSR。
 * HarmonyOS 6.1 的 cert.generateCsr 对新生成的密钥报错，
 * 所以由现有 Rust 签名模块基于同一把 PKCS#8 私钥构造 PKCS#10 请求。
 *
 * 私钥只在本机内存与本应用沙箱内产生，不上传、不离开设备。
 */
export class DeviceKeyMaterial {
  /** 未加密的 PKCS#8 PEM：`-----BEGIN PRIVATE KEY-----`。 */
  privateKeyPem: string = '';
  /** `-----BEGIN CERTIFICATE REQUEST-----`。 */
  csrPem: string = '';
}

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

function buildCsr(privateKeyPem: string): string {
  const csr = generateCsr(privateKeyPem);
  if (!/^-----BEGIN CERTIFICATE REQUEST-----/.test(csr)) {
    throw new Error('签名模块未返回有效的证书请求');
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

    const material = new DeviceKeyMaterial();
    material.privateKeyPem = privateKeyPem;
    material.csrPem = buildCsr(privateKeyPem);
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
    return buildCsr(privateKeyPem);
  }
}
