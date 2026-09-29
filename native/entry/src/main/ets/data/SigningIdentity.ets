import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { keyMatchesCertificate } from 'libhap_core.so';
import { DeveloperAccount } from './DeveloperAccount';
import { StoreClient } from './StoreClient';
import { AgcClient } from './AgcClient';
import { DeviceIdentity, DeviceKeyMaterial } from './DeviceIdentity';

const INDEX_NAME = 'signing-identity';

export class LocalSigningIdentity {
  accountId: string = '';
  certId: string = '';
  privateKeyPath: string = '';
  certificatePath: string = '';
  /** AGC 侧证书名；仅用于人工核对，删除/复用一律以密钥配对为准。 */
  certName: string = '';
  /** 证书到期时间（epoch 秒）；0 表示 AGC 未给出。 */
  certExpiry: number = 0;
}

export enum EnrollmentOutcome {
  RESTORED = 'restored',
  CREATED = 'created'
}

export class EnrollmentResult {
  outcome: EnrollmentOutcome = EnrollmentOutcome.RESTORED;
  identity: LocalSigningIdentity = new LocalSigningIdentity();
  /** 账号下还剩几张可用的调试证书槽位。 */
  freeSlots: number = 0;
}

export class EnrollmentOptions {
  /**
   * 账号只剩最后一个调试证书槽位时是否仍要新建。
   * 默认 false：先让用户确认，避免一次误点占掉团队最后一个槽位。
   */
  allowLastSlot: boolean = false;
}

// Restores only a certificate already issued to this account. This code has
// deliberately no cert/add or cert/delete request: login cannot use a slot.
export class SigningIdentityRecovery {
  private static materialDir(context: common.UIAbilityContext): string {
    const dir = context.filesDir + '/signing-identity';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    return dir;
  }

  /// `mode` 默认仅属主可读写（0o600）：私钥与证书都属于敏感材料。
  static writeFile(path: string, bytes: ArrayBuffer | string, mode: number = 0o600): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
      fileIo.OpenMode.TRUNC | mode);
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
      const name = String(row['certName'] ?? '');
      identity.certName = /^[A-Za-z0-9._-]{1,64}$/.test(name) ? name : '';
      const expiry = Number(row['certExpiry'] ?? 0);
      identity.certExpiry = Number.isFinite(expiry) && expiry > 0 ? Math.floor(expiry) : 0;
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
    return SigningIdentityRecovery.switchTo(context, account, current, certId, bytes,
      String(cert['certName'] ?? ''), SigningIdentityRecovery.expirySeconds(cert['expireTime']));
  }

  /**
   * 把本机在用的证书原子地换成 `candidate`。
   *
   * 先落到临时文件并确认与私钥配对，通过后才改名覆盖正式证书 —— 中途任何
   * 失败都不会让本机留下一个「证书与私钥不配对」的坏身份。
   */
  private static async switchTo(context: common.UIAbilityContext, account: DeveloperAccount,
    current: LocalSigningIdentity, certId: string, certificate: ArrayBuffer,
    certName: string, certExpiry: number): Promise<LocalSigningIdentity> {
    const dir = SigningIdentityRecovery.materialDir(context);
    const certTmp = dir + '/identity.cer.switch';
    try {
      SigningIdentityRecovery.writeFile(certTmp, certificate);
      if (!keyMatchesCertificate(current.privateKeyPath, certTmp)) {
        throw new Error('该证书与本机私钥不配对，无法使用');
      }
      const identity = new LocalSigningIdentity();
      identity.accountId = account.userId;
      identity.certId = certId;
      identity.privateKeyPath = current.privateKeyPath;
      identity.certificatePath = current.certificatePath;
      identity.certName = /^[A-Za-z0-9._-]{1,64}$/.test(certName) ? certName : '';
      identity.certExpiry = certExpiry > 0 ? certExpiry : 0;
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

  /**
   * 找一张「能替代 `excludeCertId`」的账号调试证书：与本机私钥配对、未过期。
   *
   * 删除证书前必须先拿到这个答案：本机私钥只有一把，删掉在用的证书后若没有
   * 别的证书能配上它，本机就再也签不出能装上的包，而重新申请会占新槽位。
   * 返回 undefined 表示没有可用替代，调用方应该拒绝删除。
   */
  static async findReplacement(context: common.UIAbilityContext, account: DeveloperAccount,
    excludeCertId: string): Promise<LocalSigningIdentity | undefined> {
    const current = await SigningIdentityRecovery.load(context, account);
    if (current === undefined) return undefined;
    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const now = Math.floor(Date.now() / 1000);
    const dir = SigningIdentityRecovery.materialDir(context);
    for (const row of rows) {
      if (Number(row['certType'] ?? 0) !== 1) continue;
      const id = String(row['id'] ?? '');
      if (id.length === 0 || id === excludeCertId) continue;
      const expiry = SigningIdentityRecovery.expirySeconds(row['expireTime']);
      if (expiry > 0 && expiry <= now) continue;
      const objectId = String(row['certObjectId'] ?? '');
      if (objectId.length === 0) continue;
      try {
        const bytes = await agc.download(await agc.certificateUrl(objectId));
        if (!SigningIdentityRecovery.pairsWithKey(current.privateKeyPath, bytes, dir)) continue;
        const replacement = new LocalSigningIdentity();
        replacement.accountId = account.userId;
        replacement.certId = id;
        replacement.privateKeyPath = current.privateKeyPath;
        replacement.certificatePath = current.certificatePath;
        replacement.certName = String(row['certName'] ?? '');
        replacement.certExpiry = expiry;
        return replacement;
      } catch (_) {
        // 单张下载失败继续看下一张
      }
    }
    return undefined;
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

  /**
   * 首次签名的入口：保证这台设备有一份可用的签名身份。
   *
   * 顺序刻意如此，**先复用、后申请**：
   *   ① 本机已有配对身份        → 直接返回
   *   ② 旧版 Flutter 材料迁移   → 直接返回
   *   ③ 云端备份身份 + AGC 证书 → 直接返回
   *   ④ 本机私钥能配上的账号证书 → 复用（只补本地证书文件）
   *   ⑤ 都没有才向 AGC 申请新证书
   *
   * 第 ⑤ 步是唯一会占槽位的动作，并且先列出账号现有证书逐个试配对。
   * 槽位满或只剩最后一个而未获确认时，宁可报错也不占用。
   */
  static async enroll(context: common.UIAbilityContext, account: DeveloperAccount,
    options: EnrollmentOptions = new EnrollmentOptions()): Promise<EnrollmentResult> {
    if (SigningIdentityRecovery.enrolling) {
      throw new Error('签名身份正在准备中，请稍候');
    }
    SigningIdentityRecovery.enrolling = true;
    try {
      return await SigningIdentityRecovery.enrollLocked(context, account, options);
    } finally {
      SigningIdentityRecovery.enrolling = false;
    }
  }

  private static async enrollLocked(context: common.UIAbilityContext,
    account: DeveloperAccount, options: EnrollmentOptions): Promise<EnrollmentResult> {
    const reusable = await SigningIdentityRecovery.restoreAny(context, account);
    if (reusable) {
      const result = new EnrollmentResult();
      result.outcome = EnrollmentOutcome.RESTORED;
      result.identity = reusable;
      return result;
    }

    const dir = SigningIdentityRecovery.materialDir(context);
    const privateKeyPath = dir + '/identity.pem';

    // 私钥在、但没有可用证书：只有当它确实是一把可解析的 P-256 私钥时才继续用，
    // 否则重新生成，避免拿一把坏密钥去申请证书白占一个槽位。
    let generated: DeviceKeyMaterial | undefined = undefined;
    if (fileIo.accessSync(privateKeyPath) &&
      !await SigningIdentityRecovery.readablePrivateKey(privateKeyPath)) {
      fileIo.unlinkSync(privateKeyPath);
    }
    if (!fileIo.accessSync(privateKeyPath)) {
      generated = await DeviceIdentity.generate();
      // 私钥只对应用本身可读，避免同机其他进程或备份顺走。
      SigningIdentityRecovery.writeFile(privateKeyPath, generated.privateKeyPem, 0o600);
    }

    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const valid = SigningIdentityRecovery.validDebugCerts(rows);
    const freeSlots = Math.max(0, SigningIdentityRecovery.DEBUG_SLOT_LIMIT - valid.length);

    // 先看有没有现成证书能配上这把私钥 —— 配得上就不需要新槽位。
    for (const row of valid) {
      const id = String(row['id'] ?? '');
      const objectId = String(row['certObjectId'] ?? '');
      if (objectId.length === 0) continue;
      const downloaded = await SigningIdentityRecovery.tryDownloadCertificate(agc, objectId);
      if (downloaded === undefined) continue;
      if (!SigningIdentityRecovery.pairsWithKey(privateKeyPath, downloaded, dir)) continue;
      return SigningIdentityRecovery.persist(context, account, id, downloaded,
        String(row['certName'] ?? ''), SigningIdentityRecovery.expirySeconds(row['expireTime']),
        EnrollmentOutcome.RESTORED, freeSlots);
    }

    if (freeSlots <= 0) {
      throw new Error('AGC 的 ' + SigningIdentityRecovery.DEBUG_SLOT_LIMIT +
        ' 个调试证书槽位已满，且都不与本机私钥配对。请在证书管理中删除一张不用的证书后重试');
    }
    if (freeSlots === 1 && !options.allowLastSlot) {
      throw new Error('AGC 只剩最后一个调试证书槽位。确认要为这台设备新建时，请再次点击「占用最后槽位并申请」');
    }

    // CSR 必须由刚落盘的那把私钥产生，否则证书回来配不上。
    const keyPem = fileIo.readTextSync(privateKeyPath);
    const csrPem = generated !== undefined ? generated.csrPem :
      await SigningIdentityRecovery.csrForExistingKey(keyPem);
    const certName = await DeviceIdentity.certNameFor(keyPem);
    const created = await agc.createCertificate(csrPem, certName);
    const createdId = String(created['id'] ?? '');
    const createdBytes = await SigningIdentityRecovery.downloadNewCertificate(agc, created);
    if (!SigningIdentityRecovery.pairsWithKey(privateKeyPath, createdBytes, dir)) {
      // 新证书已经占了槽位但配不上：明确告诉用户删哪一张，不静默留下垃圾。
      throw new Error('新建的证书与本机私钥不配对；请在证书管理中删除「' + certName + '」后重试');
    }
    return SigningIdentityRecovery.persist(context, account, createdId, createdBytes,
      String(created['certName'] ?? certName), SigningIdentityRecovery.expirySeconds(
        created['expireTime']), EnrollmentOutcome.CREATED, freeSlots - 1);
  }

  /**
   * 只复用、不申请。任何一步失败都返回 undefined，让调用方决定是否申请新证书。
   * `restore` 会对云端备份与 AGC 的不一致直接抛错，这里不能那样：首次签名时
   * 「账号里什么都没有」是正常状态，不是错误。
   */
  private static async restoreAny(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<LocalSigningIdentity | undefined> {
    try {
      return await SigningIdentityRecovery.restore(context, account);
    } catch (_) {
      return undefined;
    }
  }

  /// AGC 调试证书槽位上限（团队共享资源，不做自动删除别人的证书）。
  private static readonly DEBUG_SLOT_LIMIT: number = 3;

  /**
   * 同一时刻只允许一次「首次签名」编排。
   *
   * 两个入口同时进来时会各自以为私钥不存在、各自生成一把、各自申请一张证书：
   * 既多占槽位，两把密钥还会互相覆盖。这里在进程内直接挡住第二次。
   */
  private static enrolling: boolean = false;

  /// 把 AGC 的 expireTime 统一成 epoch 秒；0 表示未提供。
  static expirySeconds(raw: Object | undefined): number {
    const value = Number(raw ?? 0);
    if (!Number.isFinite(value) || value <= 0) return 0;
    return value > 100000000000 ? Math.floor(value / 1000) : Math.floor(value);
  }

  /// 账号下仍在有效期内的调试证书（certType 1）。
  private static validDebugCerts(
    rows: Array<Record<string, Object>>): Array<Record<string, Object>> {
    const now = Math.floor(Date.now() / 1000);
    const out: Array<Record<string, Object>> = [];
    for (const row of rows) {
      if (Number(row['certType'] ?? 0) !== 1) continue;
      if (String(row['id'] ?? '').length === 0) continue;
      const expiry = SigningIdentityRecovery.expirySeconds(row['expireTime']);
      if (expiry > 0 && expiry <= now) continue;
      out.push(row);
    }
    return out;
  }

  /// 私钥是否可解析。坏文件不该拿去申请证书。
  private static async readablePrivateKey(path: string): Promise<boolean> {
    try {
      const pem = fileIo.readTextSync(path);
      return /^-----BEGIN PRIVATE KEY-----/.test(pem) && pem.length <= 4096;
    } catch (_) {
      return false;
    }
  }

  /**
   * 从已有私钥补建 CSR。
   *
   * 系统接口只接受密钥数据本身，所以这里把 PEM 交给 `DeviceIdentity`；
   * 私钥已经在沙箱里，不额外复制到别处。
   */
  private static async csrForExistingKey(privateKeyPem: string): Promise<string> {
    return DeviceIdentity.csrFor(privateKeyPem);
  }

  /**
   * 私钥与证书字节是否配对。
   *
   * `keyMatchesCertificate` 只收文件路径，所以证书先落一个临时文件；临时文件
   * 用完即删，正式证书由 `persist` 在校验通过后才改名就位。
   */
  private static pairsWithKey(privateKeyPath: string, certificate: ArrayBuffer,
    dir: string): boolean {
    const probe = dir + '/identity.cer.probe';
    try {
      SigningIdentityRecovery.writeFile(probe, certificate);
      return keyMatchesCertificate(privateKeyPath, probe);
    } catch (_) {
      return false;
    } finally {
      try {
        if (fileIo.accessSync(probe)) fileIo.unlinkSync(probe);
      } catch (_) {
        // 临时文件删不掉不影响判定结果
      }
    }
  }

  /// 下载某张 AGC 证书；失败返回 undefined（单张失败不该中断整体尝试）。
  private static async tryDownloadCertificate(agc: AgcClient,
    objectId: string): Promise<ArrayBuffer | undefined> {
    try {
      const url = await agc.certificateUrl(objectId);
      if (url.length === 0) return undefined;
      return await agc.download(url);
    } catch (_) {
      return undefined;
    }
  }

  /// 新建证书后必须立刻拿到字节；拿不到就报错，不能让槽位白占。
  private static async downloadNewCertificate(agc: AgcClient,
    row: Record<string, Object>): Promise<ArrayBuffer> {
    const objectId = String(row['certObjectId'] ?? '');
    if (objectId.length === 0) throw new Error('AGC 未提供新证书的下载位置');
    const url = await agc.certificateUrl(objectId);
    if (url.length === 0) throw new Error('AGC 未返回新证书的下载地址');
    return await agc.download(url);
  }

  /// 校验并落盘一份新身份，同时写入证书名与到期时间供界面展示。
  private static async persist(context: common.UIAbilityContext, account: DeveloperAccount,
    certId: string, certificate: ArrayBuffer, certName: string, certExpiry: number,
    outcome: EnrollmentOutcome, freeSlots: number): Promise<EnrollmentResult> {
    const dir = SigningIdentityRecovery.materialDir(context);
    const certTmp = dir + '/identity.cer.new';
    const identity = new LocalSigningIdentity();
    identity.accountId = account.userId;
    identity.certId = certId;
    identity.privateKeyPath = dir + '/identity.pem';
    identity.certificatePath = dir + '/identity.cer';
    identity.certName = /^[A-Za-z0-9._-]{1,64}$/.test(certName) ? certName : '';
    identity.certExpiry = certExpiry > 0 ? certExpiry : 0;
    try {
      SigningIdentityRecovery.writeFile(certTmp, certificate);
      if (!keyMatchesCertificate(identity.privateKeyPath, certTmp)) {
        throw new Error('证书与本机私钥不配对；本机身份未改动');
      }
      fileIo.renameSync(certTmp, identity.certificatePath);
    } finally {
      if (fileIo.accessSync(certTmp)) fileIo.unlinkSync(certTmp);
    }
    const store = await preferences.getPreferences(context, INDEX_NAME);
    await store.put('identity', JSON.stringify(identity));
    await store.flush();
    const result = new EnrollmentResult();
    result.outcome = outcome;
    result.identity = identity;
    result.freeSlots = freeSlots;
    return result;
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
    identity.certName = String(cert['certName'] ?? '');
    identity.certExpiry = SigningIdentityRecovery.expirySeconds(cert['expireTime']);
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
        identity.certName = String(cert['certName'] ?? '');
        identity.certExpiry = SigningIdentityRecovery.expirySeconds(cert['expireTime']);
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
