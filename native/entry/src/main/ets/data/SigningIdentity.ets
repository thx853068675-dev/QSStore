import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { keyMatchesCertificate } from 'libhap_core.so';
import { DeveloperAccount } from './DeveloperAccount';
import { StoreClient } from './StoreClient';
import { AgcClient } from './AgcClient';

const INDEX_NAME = 'signing-identity';

export class LocalSigningIdentity {
  accountId: string = '';
  certId: string = '';
  privateKeyPath: string = '';
  certificatePath: string = '';
}

// Restores only a certificate already issued to this account. This code has
// deliberately no cert/add or cert/delete request: login cannot use a slot.
export class SigningIdentityRecovery {
  private static materialDir(context: common.UIAbilityContext): string {
    const dir = context.filesDir + '/signing-identity';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    return dir;
  }

  static writeFile(path: string, bytes: ArrayBuffer | string): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  static async load(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<LocalSigningIdentity | undefined> {
    const store = await preferences.getPreferences(context, INDEX_NAME);
    const raw = await store.get('identity', '') as string;
    if (raw.length === 0) return undefined;
    try {
      const row = JSON.parse(raw) as Record<string, Object>;
      const identity = new LocalSigningIdentity();
      identity.accountId = String(row['accountId'] ?? '');
      identity.certId = String(row['certId'] ?? '');
      identity.privateKeyPath = String(row['privateKeyPath'] ?? '');
      identity.certificatePath = String(row['certificatePath'] ?? '');
      const dir = SigningIdentityRecovery.materialDir(context) + '/';
      if (identity.accountId !== account.userId || !/^\d{1,64}$/.test(identity.certId) ||
        !identity.privateKeyPath.startsWith(dir) || !identity.certificatePath.startsWith(dir) ||
        !fileIo.accessSync(identity.privateKeyPath) ||
        !fileIo.accessSync(identity.certificatePath)) return undefined;
      return keyMatchesCertificate(identity.privateKeyPath, identity.certificatePath) ?
        identity : undefined;
    } catch (_) {
      return undefined;
    }
  }

  /**
   * 把当前身份切换到账号下的另一张调试证书。
   *
   * 本机的私钥只有一把，所以能不能用取决于「这张证书是否与本机私钥配对」：
   * 配对成功就把证书换掉并落盘；不配对直接报错，不会静默改坏身份。
   */
  static async activate(context: common.UIAbilityContext, account: DeveloperAccount,
    certId: string): Promise<LocalSigningIdentity> {
    const current = await SigningIdentityRecovery.load(context, account);
    if (current === undefined) {
      throw new Error('本机还没有可用的私钥，请先完成一次签名身份核对');
    }
    const agc = new AgcClient(account);
    const cert = (await agc.certificates()).find((item: Record<string, Object>) =>
      String(item['id'] ?? '') === certId && Number(item['certType'] ?? 0) === 1);
    if (cert === undefined) throw new Error('该证书不在当前账号下，或不是调试证书');
    const objectId = String(cert['certObjectId'] ?? '');
    if (objectId.length === 0) throw new Error('AGC 未提供该证书的下载位置');
    const bytes = await agc.download(await agc.certificateUrl(objectId));
    const dir = SigningIdentityRecovery.materialDir(context);
    const certTmp = dir + '/identity.cer.switch';
    try {
      SigningIdentityRecovery.writeFile(certTmp, bytes);
      if (!keyMatchesCertificate(current.privateKeyPath, certTmp)) {
        throw new Error('该证书与本机私钥不配对，无法使用');
      }
      const identity = new LocalSigningIdentity();
      identity.accountId = account.userId;
      identity.certId = certId;
      identity.privateKeyPath = current.privateKeyPath;
      identity.certificatePath = current.certificatePath;
      fileIo.renameSync(certTmp, identity.certificatePath);
      const store = await preferences.getPreferences(context, INDEX_NAME);
      await store.put('identity', JSON.stringify(identity));
      await store.flush();
      return identity;
    } finally {
      try {
        if (fileIo.accessSync(certTmp)) fileIo.unlinkSync(certTmp);
      } catch (_) {
        // 临时文件清理失败不影响主流程
      }
    }
  }

  /** 清掉本机保存的签名身份，下次核对时会重新从账号取回。 */
  static async reset(context: common.UIAbilityContext): Promise<void> {
    const dir = SigningIdentityRecovery.materialDir(context);
    for (const name of ['/identity.pem', '/identity.cer', '/switch.cer']) {
      const path = dir + name;
      try {
        if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      } catch (_) {
        // 单个文件删不掉不阻断重置
      }
    }
    const store = await preferences.getPreferences(context, INDEX_NAME);
    await store.clear();
    await store.flush();
  }

  static async restore(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<LocalSigningIdentity | undefined> {
    const current = await SigningIdentityRecovery.load(context, account);
    if (current) return current;
    const legacy = await SigningIdentityRecovery.migrateLegacy(context, account);
    if (legacy) return legacy;
    const backup = await new StoreClient(context).signingIdentity(account);
    if (!backup) return undefined;
    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const cert = rows.find((row: Record<string, Object>) =>
      String(row['id'] ?? '') === backup.certId && Number(row['certType'] ?? 0) === 1);
    if (!cert) throw new Error('已备份的调试证书不在当前 AGC 账号中；不会申请新证书');
    const expire = Number(cert['expireTime'] ?? 0);
    const expirySeconds = expire > 100000000000 ? Math.floor(expire / 1000) : expire;
    if (expirySeconds > 0 && expirySeconds <= Date.now() / 1000) {
      throw new Error('已备份的调试证书已过期；不会自动占用新槽位');
    }
    const objectId = String(cert['certObjectId'] ?? '');
    if (objectId.length === 0) throw new Error('AGC 未提供已有证书的下载位置');
    const url = await agc.certificateUrl(objectId);
    const bytes = await agc.download(url);
    const dir = SigningIdentityRecovery.materialDir(context);
    const keyTmp = dir + '/identity.pem.restore';
    const certTmp = dir + '/identity.cer.restore';
    const identity = new LocalSigningIdentity();
    identity.accountId = account.userId;
    identity.certId = backup.certId;
    identity.privateKeyPath = dir + '/identity.pem';
    identity.certificatePath = dir + '/identity.cer';
    try {
      SigningIdentityRecovery.writeFile(keyTmp, backup.privateKeyPem);
      SigningIdentityRecovery.writeFile(certTmp, bytes);
      if (!keyMatchesCertificate(keyTmp, certTmp)) {
        throw new Error('备份私钥与 AGC 证书不匹配；本机身份未改动');
      }
      fileIo.renameSync(keyTmp, identity.privateKeyPath);
      fileIo.renameSync(certTmp, identity.certificatePath);
      const store = await preferences.getPreferences(context, INDEX_NAME);
      await store.put('identity', JSON.stringify(identity));
      await store.flush();
      return identity;
    } finally {
      if (fileIo.accessSync(keyTmp)) fileIo.unlinkSync(keyTmp);
      if (fileIo.accessSync(certTmp)) fileIo.unlinkSync(certTmp);
    }
  }

  // A same-bundle ArkTS update retains the Flutter filesDir. Keep its source
  // files untouched and accept the key only after AGC confirms the recorded
  // certificate belongs to the currently signed-in account.
  private static async migrateLegacy(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<LocalSigningIdentity | undefined> {
    const configPath = context.filesDir + '/sign_material.json';
    if (!fileIo.accessSync(configPath)) return undefined;
    try {
      const row = JSON.parse(fileIo.readTextSync(configPath)) as Record<string, Object>;
      const certId = String(row['certId'] ?? '');
      const oldKey = String(row['keystoreFile'] ?? '');
      const oldCert = String(row['certPath'] ?? '');
      const base = context.filesDir + '/';
      if (!/^\d{1,64}$/.test(certId) || !oldKey.startsWith(base) ||
        !oldCert.startsWith(base) || !fileIo.accessSync(oldKey) ||
        !fileIo.accessSync(oldCert) || !keyMatchesCertificate(oldKey, oldCert)) {
        return undefined;
      }
      const agc = new AgcClient(account);
      const cert = (await agc.certificates()).find((item: Record<string, Object>) =>
        String(item['id'] ?? '') === certId && Number(item['certType'] ?? 0) === 1);
      if (!cert) return undefined;
      const expire = Number(cert['expireTime'] ?? 0);
      const expirySeconds = expire > 100000000000 ? Math.floor(expire / 1000) : expire;
      if (expirySeconds > 0 && expirySeconds <= Date.now() / 1000) return undefined;
      const objectId = String(cert['certObjectId'] ?? '');
      if (objectId.length === 0) return undefined;
      const bytes = await agc.download(await agc.certificateUrl(objectId));
      const dir = SigningIdentityRecovery.materialDir(context);
      const keyTmp = dir + '/identity.pem.legacy';
      const certTmp = dir + '/identity.cer.legacy';
      try {
        SigningIdentityRecovery.writeFile(keyTmp, fileIo.readTextSync(oldKey));
        SigningIdentityRecovery.writeFile(certTmp, bytes);
        if (!keyMatchesCertificate(keyTmp, certTmp)) return undefined;
        const identity = new LocalSigningIdentity();
        identity.accountId = account.userId;
        identity.certId = certId;
        identity.privateKeyPath = dir + '/identity.pem';
        identity.certificatePath = dir + '/identity.cer';
        fileIo.renameSync(keyTmp, identity.privateKeyPath);
        fileIo.renameSync(certTmp, identity.certificatePath);
        const store = await preferences.getPreferences(context, INDEX_NAME);
        await store.put('identity', JSON.stringify(identity));
        await store.flush();
        return identity;
      } finally {
        if (fileIo.accessSync(keyTmp)) fileIo.unlinkSync(keyTmp);
        if (fileIo.accessSync(certTmp)) fileIo.unlinkSync(certTmp);
      }
    } catch (_) {
      return undefined;
    }
  }
}
