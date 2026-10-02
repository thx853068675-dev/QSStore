import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { certificateFingerprint, keyMatchesCertificate } from 'libhap_core.so';
import { DeveloperAccount } from './DeveloperAccount';
import { BackedUpIdentity, StoreClient } from './StoreClient';
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
  /** 重置时核对 AGC，不能把已被远端删除的本机证书当成可复用身份。 */
  refreshCertificate: boolean = false;
  /**
   * 账号只剩最后一个调试证书槽位时是否仍要新建。
   * 默认 false：先让用户确认，避免一次误点占掉团队最后一个槽位。
   */
  allowLastSlot: boolean = false;
  /** 用户主动续期时，跳过此时间之前到期的证书。 */
  renewBeforeSeconds: number = 0;
}

// Login only restores material; an installation or manual enrollment can prepare a certificate.
export class SigningIdentityRecovery {
  private static deletingCert: string = '';
  private static restorations: Map<string, Promise<LocalSigningIdentity | undefined>> = new Map();
  private static freshRestorations: Set<string> = new Set();

  private static notifyChanged(): void {
    AppStorage.setOrCreate<number>('signingIdentityRevision',
      (AppStorage.get<number>('signingIdentityRevision') ?? 0) + 1);
  }
  private static materialDir(context: common.UIAbilityContext): string {
    const dir = context.filesDir + '/signing-identity';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    return dir;
  }

  /// 材料仅写入应用沙箱；openSync 的第二参数是打开标志，不是 Unix 权限。
  static writeFile(path: string, bytes: ArrayBuffer | string): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
      fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  static async load(context: common.UIAbilityContext,
    account: DeveloperAccount, allowExpired: boolean = false): Promise<LocalSigningIdentity | undefined> {
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
      // 删除请求发出前先标记该证书；即使进程在 AGC 已删除、清理本机材料前
      // 退出，也不能把仍在沙箱里的旧证书当作有效身份继续签名。
      const marker = await store.get('deleting-cert', '') as string;
      const identityKey = identity.accountId + ':' + identity.certId;
      if (marker === 'pending:' + identityKey || marker === 'deleted:' + identityKey) {
        return undefined;
      }
      const expiry = Number(row['certExpiry'] ?? 0);
      identity.certExpiry = Number.isFinite(expiry) && expiry > 0 ? Math.floor(expiry) : 0;
      const dir = SigningIdentityRecovery.materialDir(context) + '/';
      if (identity.accountId !== account.userId || !/^\d{1,64}$/.test(identity.certId) ||
        identity.privateKeyPath !== dir + 'identity.pem' || identity.certificatePath !== dir + 'identity.cer' ||
        !fileIo.accessSync(identity.privateKeyPath) ||
        !fileIo.accessSync(identity.certificatePath)) return undefined;
      // 过期证书不能算「可用身份」：过期后签出来的包设备会拒绝安装。
      // 返回 undefined 让调用方走正常流程去找同私钥的另一张证书（续期），
      // 而不是把这张已经没用的证书继续返回给用户。
      const nowSeconds = Math.floor(Date.now() / 1000);
      if (!allowExpired && identity.certExpiry > 0 && identity.certExpiry <= nowSeconds) return undefined;
      return keyMatchesCertificate(identity.privateKeyPath, identity.certificatePath) ?
        identity : undefined;
    } catch (_) {
      return undefined;
    }
  }

  /** 只复用本机保留的私钥；AGC 里有证书但没有对应私钥，不能冒充可覆盖身份。 */
  static async matchingInstalledCertificate(context: common.UIAbilityContext,
    account: DeveloperAccount, fingerprint: string): Promise<LocalSigningIdentity | undefined> {
    if (!/^[0-9A-Fa-f]{64}$/.test(fingerprint)) return undefined;
    const current = await SigningIdentityRecovery.restore(context, account);
    if (!current) return undefined;
    const wanted = fingerprint.toUpperCase();
    if (certificateFingerprint(current.certificatePath) === wanted) return current;
    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const dir = SigningIdentityRecovery.materialDir(context);
    const index = await preferences.getPreferences(context, INDEX_NAME);
    const deletion = await index.get('deleting-cert', '') as string;
    let incomplete = false;
    for (const row of rows) {
      if (Number(row['certType'] ?? 0) !== 1) continue;
      const id = String(row['id'] ?? '');
      if (!/^\d{1,64}$/.test(id) || id === current.certId) continue;
      if (deletion === 'pending:' + account.userId + ':' + id ||
        deletion === 'deleted:' + account.userId + ':' + id) continue;
      const expiry = SigningIdentityRecovery.expirySeconds(row['expireTime']);
      if (expiry > 0 && expiry <= Date.now() / 1000) continue;
      const objectId = String(row['certObjectId'] ?? '');
      if (objectId.length === 0) { incomplete = true; continue; }
      const target = dir + '/cert-' + id + '.cer';
      try {
        // AGC is authoritative for whether a saved certificate still exists.
        // A cached file is useful only after that check and key-pair validation.
        if (!fileIo.accessSync(target) || certificateFingerprint(target) !== wanted) {
          const bytes = await agc.download(await agc.certificateUrl(objectId));
          const temporary = target + '.' + Date.now() + '-' +
            Math.floor(Math.random() * 1000000) + '.part';
          try {
            SigningIdentityRecovery.writeFile(temporary, bytes);
            if (certificateFingerprint(temporary) !== wanted) continue;
            if (!keyMatchesCertificate(current.privateKeyPath, temporary)) return undefined;
            fileIo.renameSync(temporary, target);
          } finally {
            if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
          }
        }
        if (!keyMatchesCertificate(current.privateKeyPath, target)) return undefined;
        const matched = new LocalSigningIdentity();
        matched.accountId = account.userId;
        matched.certId = id;
        matched.privateKeyPath = current.privateKeyPath;
        matched.certificatePath = target;
        matched.certName = String(row['certName'] ?? '');
        matched.certExpiry = expiry;
        return matched;
      } catch (_) {
        incomplete = true;
      }
    }
    if (incomplete) throw new Error('部分证书暂时无法核实，已暂停更新以保护应用数据');
    return undefined;
  }

  /** 恢复某个任务选定的本机证书，防止全局证书切换后任务用错材料。 */
  static async forJob(context: common.UIAbilityContext, account: DeveloperAccount,
    certId: string): Promise<LocalSigningIdentity | undefined> {
    const current = await SigningIdentityRecovery.load(context, account);
    if (!current) return undefined;
    if (certId.length === 0) return current;
    if (!/^\d{1,64}$/.test(certId)) return undefined;
    const index = await preferences.getPreferences(context, INDEX_NAME);
    const deletion = await index.get('deleting-cert', '') as string;
    if (deletion === 'pending:' + account.userId + ':' + certId ||
      deletion === 'deleted:' + account.userId + ':' + certId) return undefined;
    const path = SigningIdentityRecovery.materialDir(context) + '/cert-' + certId + '.cer';
    if (!fileIo.accessSync(path)) return certId === current.certId ? current : undefined;
    if (!keyMatchesCertificate(current.privateKeyPath, path)) return undefined;
    const matched = new LocalSigningIdentity();
    matched.accountId = account.userId;
    matched.certId = certId;
    matched.privateKeyPath = current.privateKeyPath;
    matched.certificatePath = path;
    return matched;
  }

  static async pinForJob(context: common.UIAbilityContext,
    identity: LocalSigningIdentity): Promise<LocalSigningIdentity> {
    if (!/^\d{1,64}$/.test(identity.certId)) throw new Error('签名证书编号无效');
    const path = SigningIdentityRecovery.materialDir(context) + '/cert-' + identity.certId + '.cer';
    if (identity.certificatePath !== path) {
      const temporary = path + '.' + Date.now() + '-' +
        Math.floor(Math.random() * 1000000) + '.part';
      try {
        await fileIo.copyFile(identity.certificatePath, temporary);
        if (!keyMatchesCertificate(identity.privateKeyPath, temporary)) {
          throw new Error('签名证书与私钥不配对');
        }
        fileIo.renameSync(temporary, path);
      } finally {
        if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
      }
    }
    const pinned = new LocalSigningIdentity();
    pinned.accountId = identity.accountId;
    pinned.certId = identity.certId;
    pinned.privateKeyPath = identity.privateKeyPath;
    pinned.certificatePath = path;
    pinned.certName = identity.certName;
    pinned.certExpiry = identity.certExpiry;
    return pinned;
  }

  /**
   * 把当前身份切换到账号下的另一张调试证书。
   *
   * 本机的私钥只有一把，所以能不能用取决于「这张证书是否与本机私钥配对」：
   * 配对成功就把证书换掉并落盘；不配对直接报错，不会静默改坏身份。
   */
  static async activate(context: common.UIAbilityContext, account: DeveloperAccount,
    certId: string): Promise<LocalSigningIdentity> {
    const current = await SigningIdentityRecovery.load(context, account, true);
    if (current === undefined) {
      throw new Error('本机还没有可用的私钥，请先完成一次签名身份核对');
    }
    const agc = new AgcClient(account);
    const cert = (await agc.certificates()).find((item: Record<string, Object>) =>
      String(item['id'] ?? '') === certId && Number(item['certType'] ?? 0) === 1);
    if (cert === undefined) throw new Error('该证书不在当前账号下，或不是调试证书');
    const expiry = SigningIdentityRecovery.expirySeconds(cert['expireTime']);
    if (expiry > 0 && expiry <= Date.now() / 1000) throw new Error('该证书已过期');
    // 切换前确认旧身份的备份版本；失败时保留当前身份。
    await new StoreClient(context).publishSigningIdentity(current.certId,
      fileIo.readTextSync(current.privateKeyPath), account);
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
      SigningIdentityRecovery.notifyChanged();
      return identity;
    } finally {
      try {
        if (fileIo.accessSync(certTmp)) fileIo.unlinkSync(certTmp);
      } catch (_) {
        // 临时文件清理失败不影响主流程
      }
    }
  }

  /** 查找与保留的私钥配对、未过期的替代证书；查询失败时不猜测替代身份。 */
  static async findReplacement(context: common.UIAbilityContext, account: DeveloperAccount,
    excludeCertId: string): Promise<LocalSigningIdentity | undefined> {
    const privateKeyPath = SigningIdentityRecovery.materialDir(context) + '/identity.pem';
    if (!fileIo.accessSync(privateKeyPath)) return undefined;
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
        if (!SigningIdentityRecovery.pairsWithKey(privateKeyPath, bytes, dir)) continue;
        const replacement = new LocalSigningIdentity();
        replacement.accountId = account.userId;
        replacement.certId = id;
        replacement.privateKeyPath = privateKeyPath;
        replacement.certificatePath = dir + '/identity.cer';
        replacement.certName = String(row['certName'] ?? '');
        replacement.certExpiry = expiry;
        return replacement;
      } catch (_) {
        // 单张下载失败继续看下一张
      }
    }
    return undefined;
  }

  /** 删除前尽量切到替代证书并备份私钥；最后一张也允许删除。 */
  static async prepareCertificateDeletion(context: common.UIAbilityContext,
    account: DeveloperAccount, certId: string): Promise<LocalSigningIdentity | undefined> {
    let current = await SigningIdentityRecovery.load(context, account, true);
    if (current !== undefined && current.certId === certId) {
      const replacement = await SigningIdentityRecovery.findReplacement(context, account, certId);
      if (replacement !== undefined) {
        current = await SigningIdentityRecovery.activate(context, account, replacement.certId);
      }
    }
    // 上次切换成功但备份失败时，重试也必须重新检查，不能绕过备份直接删除旧证书。
    if (current !== undefined) {
      await new StoreClient(context).publishSigningIdentity(current.certId,
        fileIo.readTextSync(current.privateKeyPath), account);
    }
    return current;
  }

  /** AGC 删除前落盘墓碑；只标记正在使用的证书，不影响删除无关证书。 */
  static async beginCertificateDeletion(context: common.UIAbilityContext,
    account: DeveloperAccount, certId: string): Promise<void> {
    const store = await preferences.getPreferences(context, INDEX_NAME);
    const raw = await store.get('identity', '') as string;
    if (raw.length === 0) return;
    let row: Record<string, Object>;
    try { row = JSON.parse(raw) as Record<string, Object>; }
    catch (_) { return; }
    if (row === null || typeof row !== 'object') return;
    if (String(row['accountId'] ?? '') !== account.userId ||
      String(row['certId'] ?? '') !== certId) return;
    await store.put('deleting-cert', 'pending:' + account.userId + ':' + certId);
    await store.flush();
    SigningIdentityRecovery.deletingCert = account.userId + ':' + certId;
  }

  /** AGC 明确拒绝删除时撤销墓碑，本机原证书仍可使用。 */
  static async cancelCertificateDeletion(context: common.UIAbilityContext,
    account: DeveloperAccount, certId: string): Promise<void> {
    const store = await preferences.getPreferences(context, INDEX_NAME);
    if (await store.get('deleting-cert', '') !==
      'pending:' + account.userId + ':' + certId) return;
    await store.put('deleting-cert', '');
    await store.flush();
    SigningIdentityRecovery.deletingCert = '';
  }

  /** AGC 删除成功后忘记旧证书；私钥和云端备份留给下一次申请复用。 */
  static async finishCertificateDeletion(context: common.UIAbilityContext,
    account: DeveloperAccount, certId: string): Promise<void> {
    const store = await preferences.getPreferences(context, INDEX_NAME);
    const raw = await store.get('identity', '') as string;
    SigningIdentityRecovery.deletingCert = '';
    await store.put('deleting-cert', 'deleted:' + account.userId + ':' + certId);
    await store.flush();
    if (/^\d{1,64}$/.test(certId)) {
      const pinned = SigningIdentityRecovery.materialDir(context) + '/cert-' + certId + '.cer';
      try { if (fileIo.accessSync(pinned)) fileIo.unlinkSync(pinned); } catch (_) {}
    }
    if (raw.length === 0) return;
    let row: Record<string, Object>;
    try { row = JSON.parse(raw) as Record<string, Object>; }
    catch (_) { return; }
    if (row === null || typeof row !== 'object') return;
    if (String(row['accountId'] ?? '') === account.userId &&
      String(row['certId'] ?? '') === certId) await store.put('identity', '');
    await store.flush();
    if (String(row['accountId'] ?? '') !== account.userId ||
      String(row['certId'] ?? '') !== certId) return;
    SigningIdentityRecovery.notifyChanged();
    const certificatePath = SigningIdentityRecovery.materialDir(context) + '/identity.cer';
    try {
      if (fileIo.accessSync(certificatePath)) fileIo.unlinkSync(certificatePath);
    } catch (_) {
      // 偏好设置与墓碑已经使旧证书不可用；清理文件失败不影响私钥。
    }
  }

  /** 本机配对身份优先向 AGC 刷新；缺少本机材料时才取回对应备份。 */
  static async reset(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<void> {
    const options = new EnrollmentOptions();
    options.refreshCertificate = true;
    options.allowLastSlot = true;
    await SigningIdentityRecovery.enroll(context, account, options);
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
    const scope = JSON.stringify([context.filesDir, account.userId, account.teamId,
      options.allowLastSlot, options.renewBeforeSeconds, options.refreshCertificate]);
    const pending = SigningIdentityRecovery.enrollment;
    if (pending !== undefined) {
      if (SigningIdentityRecovery.enrollmentScope === scope) return await pending;
      // 手动续期与安装的策略可能不同，先等材料写完，再按各自策略核验。
      try { await pending; } catch (_) {}
      return SigningIdentityRecovery.enroll(context, account, options);
    }
    const preparing = SigningIdentityRecovery.enrollLocked(context, account, options);
    SigningIdentityRecovery.enrollment = preparing;
    SigningIdentityRecovery.enrollmentScope = scope;
    try {
      return await preparing;
    } finally {
      SigningIdentityRecovery.enrollment = undefined;
      SigningIdentityRecovery.enrollmentScope = '';
    }
  }

  /** 用户点击安装即准备签名身份；复用优先，确实没有才申请，不要求额外确认槽位。 */
  static async ensureForInstall(context: common.UIAbilityContext,
    account: DeveloperAccount): Promise<LocalSigningIdentity> {
    const options = new EnrollmentOptions();
    options.allowLastSlot = true;
    const startedAt = Date.now();
    try {
      return (await SigningIdentityRecovery.enroll(context, account, options)).identity;
    } finally {
      console.info('SigningIdentity prepare: elapsedMs=' + (Date.now() - startedAt));
    }
  }

  private static async enrollLocked(context: common.UIAbilityContext,
    account: DeveloperAccount, options: EnrollmentOptions): Promise<EnrollmentResult> {
    // 「确认没有身份」和「暂时核实不了」必须分开：后者接着往下走就会申请新证书，
    // 白占一个团队共享的槽位。所以这里把核实失败直接抛给用户重试。
    let reusable: LocalSigningIdentity | undefined = undefined;
    try {
      reusable = await SigningIdentityRecovery.restore(context, account, options.refreshCertificate);
    } catch (error) {
      throw new Error('暂时无法核实本机签名身份（' + String(error) +
        '）。为避免重复占用调试证书槽位，本次不申请新证书，请稍后重试。');
    }
    if (reusable && (options.renewBeforeSeconds <= 0 || reusable.certExpiry <= 0 ||
      reusable.certExpiry > options.renewBeforeSeconds)) {
      const result = new EnrollmentResult();
      result.outcome = EnrollmentOutcome.RESTORED;
      result.identity = reusable;
      return result;
    }
    if (reusable !== undefined) {
      // 提前续期前确认旧版本，首次升级到版本化备份的设备也能安全轮换。
      await new StoreClient(context).publishSigningIdentity(reusable.certId,
        fileIo.readTextSync(reusable.privateKeyPath), account);
    }

    const dir = SigningIdentityRecovery.materialDir(context);
    const privateKeyPath = dir + '/identity.pem';

    // 私钥在、但没有可用证书：只有当它确实是一把可解析的 EC 私钥时才继续用，
    // 否则重新生成，避免拿一把坏密钥去申请证书白占一个槽位。
    let generated: DeviceKeyMaterial | undefined = undefined;
    if (fileIo.accessSync(privateKeyPath) &&
      !await SigningIdentityRecovery.readablePrivateKey(privateKeyPath)) {
      throw new Error('本机私钥暂无法解析，已保留原文件，本次不申请新证书');
    }
    if (!fileIo.accessSync(privateKeyPath)) {
      generated = await DeviceIdentity.generate();
      // 私钥只对应用本身可读，避免同机其他进程或备份顺走。
      SigningIdentityRecovery.writeFile(privateKeyPath, generated.privateKeyPem);
    }

    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const valid = SigningIdentityRecovery.validDebugCerts(rows);
    const freeSlots = Math.max(0, SigningIdentityRecovery.DEBUG_SLOT_LIMIT - valid.length);
    const index = await preferences.getPreferences(context, INDEX_NAME);
    let deletion = await index.get('deleting-cert', '') as string;
    const pendingPrefix = 'pending:' + account.userId + ':';
    if (deletion.startsWith(pendingPrefix)) {
      const pendingId = deletion.substring(pendingPrefix.length);
      if (rows.some((row: Record<string, Object>) => String(row['id'] ?? '') === pendingId)) {
        throw new Error('上次证书删除尚未确认，请在证书管理中重新删除后再申请');
      }
      await SigningIdentityRecovery.finishCertificateDeletion(context, account, pendingId);
      deletion = 'deleted:' + account.userId + ':' + pendingId;
    }

    // 先看有没有现成证书能配上这把私钥 —— 配得上就不需要新槽位。
    //
    // 关键：**只有「每一张都确实下载并比对过」才能断定配不上。** 某张证书
    // 因为网络/服务抖动没下下来时，结论是未知，不是没有；此时继续申请新证书
    // 就会在本来能复用的情况下多占一个槽位。所以记下失败次数，最后据此收口。
    let undownloaded = 0;
    for (const row of valid) {
      const expiry = SigningIdentityRecovery.expirySeconds(row['expireTime']);
      if (options.renewBeforeSeconds > 0 && expiry > 0 && expiry <= options.renewBeforeSeconds) continue;
      const id = String(row['id'] ?? '');
      if (deletion === 'pending:' + account.userId + ':' + id ||
        deletion === 'deleted:' + account.userId + ':' + id) continue;
      const objectId = String(row['certObjectId'] ?? '');
      if (objectId.length === 0) { undownloaded++; continue; }
      const downloaded = await SigningIdentityRecovery.tryDownloadCertificate(agc, objectId);
      if (downloaded === undefined) {
        undownloaded++;
        continue;
      }
      if (!SigningIdentityRecovery.pairsWithKey(privateKeyPath, downloaded, dir)) continue;
      return SigningIdentityRecovery.persist(context, account, id, downloaded,
        String(row['certName'] ?? ''), SigningIdentityRecovery.expirySeconds(row['expireTime']),
        EnrollmentOutcome.RESTORED, freeSlots);
    }

    if (undownloaded > 0) {
      throw new Error('有 ' + undownloaded +
        ' 张账号证书暂时下载失败，无法确认本机私钥能否与它们配对。' +
        '为避免重复占用调试证书槽位，本次不申请新证书，请稍后重试。');
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

  /// AGC 调试证书槽位上限（团队共享资源，不做自动删除别人的证书）。
  private static readonly DEBUG_SLOT_LIMIT: number = 3;

  /**
   * 同一时刻只准备一份材料；相同请求共享结果，其他策略等待后再核验。
   * 避免首次安装和手动申请同时生成私钥、重复占用证书槽位。
   */
  private static enrollment: Promise<EnrollmentResult> | undefined = undefined;
  private static enrollmentScope: string = '';

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
    await store.put('deleting-cert', '');
    await store.flush();
    SigningIdentityRecovery.notifyChanged();
    const result = new EnrollmentResult();
    result.outcome = outcome;
    result.identity = identity;
    result.freeSlots = freeSlots;
    return result;
  }

  static async restore(context: common.UIAbilityContext,
    account: DeveloperAccount, refresh: boolean = false): Promise<LocalSigningIdentity | undefined> {
    const scope = JSON.stringify([context.filesDir, account.userId, account.teamId]);
    const pending = SigningIdentityRecovery.restorations.get(scope);
    if (pending !== undefined) {
      const fresh = SigningIdentityRecovery.freshRestorations.has(scope);
      const identity = await pending;
      if (!refresh || fresh) return identity;
      return SigningIdentityRecovery.restore(context, account, true);
    }
    const startedAt = Date.now();
    if (refresh) SigningIdentityRecovery.freshRestorations.add(scope);
    const task = SigningIdentityRecovery.restoreLocked(context, account, refresh).finally(() => {
      SigningIdentityRecovery.restorations.delete(scope);
      SigningIdentityRecovery.freshRestorations.delete(scope);
      console.info('SigningIdentity restore: elapsedMs=' + (Date.now() - startedAt));
    });
    SigningIdentityRecovery.restorations.set(scope, task);
    return await task;
  }

  private static async restoreLocked(context: common.UIAbilityContext,
    account: DeveloperAccount, refresh: boolean): Promise<LocalSigningIdentity | undefined> {
    if (!refresh) {
      const current = await SigningIdentityRecovery.load(context, account);
      if (current) return current;
      const legacy = await SigningIdentityRecovery.migrateLegacy(context, account);
      if (legacy) return legacy;
    }
    const client = new StoreClient(context);
    const previous = await SigningIdentityRecovery.load(context, account, true);
    let backup: BackedUpIdentity | undefined = undefined;
    const localRefresh = refresh && previous !== undefined;
    if (localRefresh) {
      // A valid local key/certificate pair needs no store-server round trip to
      // refresh its AGC certificate. Another device's backup cannot block reset.
      backup = new BackedUpIdentity();
      backup.certId = previous!.certId;
      backup.privateKeyPem = fileIo.readTextSync(previous!.privateKeyPath);
    } else {
      backup = await client.signingIdentity(account, previous?.certId ?? '');
    }
    if (!backup && previous !== undefined) {
      // A second device may have never had its own slot. Back up the verified
      // local pair before refreshing it; no account-wide identity is replaced.
      await client.publishSigningIdentity(previous.certId,
        fileIo.readTextSync(previous.privateKeyPath), account);
      backup = await client.signingIdentity(account, previous.certId);
    }
    if (!backup) return undefined;
    if (refresh) {
      if (previous !== undefined && previous.certId !== backup.certId) {
        throw new Error('备份证书与本机不同，已保留原身份，请先完成备份同步');
      }
    }
    const agc = new AgcClient(account);
    const rows = await agc.certificates();
    const backedUpCertId = backup.certId;
    let cert = rows.find((row: Record<string, Object>) =>
      String(row['id'] ?? '') === backedUpCertId && Number(row['certType'] ?? 0) === 1);
    const index = await preferences.getPreferences(context, INDEX_NAME);
    const marker = account.userId + ':' + backup.certId;
    const deletion = await index.get('deleting-cert', '') as string;
    if (deletion === 'pending:' + marker || deletion === 'deleted:' + marker) {
      if (SigningIdentityRecovery.deletingCert === marker) {
        throw new Error('证书正在删除，请稍后再准备签名身份');
      }
      // AGC 删除后列表可能短暂返回旧数据。墓碑未清除前不能复活旧证书。
      cert = undefined;
    }
    const dir = SigningIdentityRecovery.materialDir(context);
    const privateKeyPath = dir + '/identity.pem';
    if (fileIo.accessSync(privateKeyPath) &&
      fileIo.readTextSync(privateKeyPath).trim() !== backup.privateKeyPem.trim()) {
      // With no valid local index, another device's default backup must not
      // block enrollment's existing-key/AGC matching path.
      if (previous === undefined && !refresh) return undefined;
      throw new Error('云端与本机私钥不同，已保留本机材料，未覆盖身份');
    }
    const expirySeconds = cert === undefined ? 0 :
      SigningIdentityRecovery.expirySeconds(cert['expireTime']);
    if (cert === undefined || (expirySeconds > 0 && expirySeconds <= Date.now() / 1000)) {
      // 确认失效后保留/恢复原私钥，显式 enroll 才继续查替代证书或申请。
      await DeviceIdentity.csrFor(backup.privateKeyPem);
      if (!fileIo.accessSync(privateKeyPath)) {
        const keyTmp = privateKeyPath + '.restore';
        SigningIdentityRecovery.writeFile(keyTmp, backup.privateKeyPem);
        fileIo.renameSync(keyTmp, privateKeyPath);
      }
      if (!localRefresh) await client.rememberSigningIdentity(account, backup);
      return undefined;
    }
    const objectId = String(cert['certObjectId'] ?? '');
    if (objectId.length === 0) throw new Error('AGC 未提供已有证书的下载位置');
    const url = await agc.certificateUrl(objectId);
    const bytes = await agc.download(url);
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
      SigningIdentityRecovery.notifyChanged();
      if (!localRefresh) await client.rememberSigningIdentity(account, backup);
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
        SigningIdentityRecovery.notifyChanged();
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
