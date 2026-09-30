import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { profileMatchesCertificate, readSignedProfile } from 'libhap_core.so';
import { AgcClient } from './AgcClient';
import { DeveloperAccount } from './DeveloperAccount';
import { LocalSigningIdentity, SigningIdentityRecovery } from './SigningIdentity';

// Match the existing client's AGC allowlist. Normal HAP permissions must not
// be sent as ACLs; unknown privileged permissions need explicit review.
const GRANTABLE_ACLS: string[] = [
  'ohos.permission.SYSTEM_FLOAT_WINDOW', 'ohos.permission.READ_CONTACTS',
  'ohos.permission.WRITE_CONTACTS', 'ohos.permission.READ_AUDIO',
  'ohos.permission.WRITE_AUDIO', 'ohos.permission.READ_IMAGEVIDEO',
  'ohos.permission.WRITE_IMAGEVIDEO', 'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY',
  'ohos.permission.ACCESS_DDK_USB', 'ohos.permission.ACCESS_DDK_HID',
  'ohos.permission.READ_PASTEBOARD', 'ohos.permission.FILE_ACCESS_PERSIST',
  'ohos.permission.INTERCEPT_INPUT_EVENT', 'ohos.permission.INPUT_MONITORING',
  'ohos.permission.SHORT_TERM_WRITE_IMAGEVIDEO', 'ohos.permission.READ_WRITE_USER_FILE',
  'ohos.permission.READ_WRITE_USB_DEV', 'ohos.permission.GET_WIFI_PEERS_MAC',
  'ohos.permission.SET_TELEPHONY_ESIM_STATE_OPEN',
  'ohos.permission.kernel.DISABLE_CODE_MEMORY_PROTECTION',
  'ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY',
  'ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY',
  'ohos.permission.MANAGE_PASTEBOARD_APP_SHARE_OPTION',
  'ohos.permission.MANAGE_UDMF_APP_SHARE_OPTION',
  'ohos.permission.ACCESS_DISK_PHY_INFO', 'ohos.permission.PRELOAD_FILE',
  'ohos.permission.SET_PAC_URL', 'ohos.permission.PERSONAL_MANAGE_RESTRICTIONS',
  'ohos.permission.START_PROVISIONING_MESSAGE',
  'ohos.permission.USE_FRAUD_CALL_LOG_PICKER',
  'ohos.permission.USE_FRAUD_MESSAGES_PICKER',
  'ohos.permission.PERSISTENT_BLUETOOTH_PEERS_MAC',
  'ohos.permission.ACCESS_VIRTUAL_SCREEN', 'ohos.permission.MANAGE_APN_SETTING',
  'ohos.permission.GET_WIFI_LOCAL_MAC',
  'ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE',
  'ohos.permission.GET_ETHERNET_LOCAL_MAC',
  'ohos.permission.kernel.DISABLE_GOTPLT_RO_PROTECTION',
  'ohos.permission.USE_FRAUD_APP_PICKER', 'ohos.permission.ACCESS_DDK_DRIVERS',
  'ohos.permission.ACCESS_DDK_SCSI_PERIPHERAL',
  'ohos.permission.kernel.SUPPORT_PLUGIN', 'ohos.permission.CUSTOM_SANDBOX',
  'ohos.permission.MANAGE_SCREEN_TIME_GUARD',
  'ohos.permission.CUSTOMIZE_SAVE_BUTTON', 'ohos.permission.GET_ABILITY_INFO',
  'ohos.permission.ACCESS_FIDO2_ONLINEAUTH', 'ohos.permission.USE_FLOAT_BALL',
  'ohos.permission.DLP_GET_HIDE_STATUS',
  'ohos.permission.READ_LOCAL_DEVICE_NAME',
  'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM', 'ohos.permission.LINKTURBO',
  'ohos.permission.ACCESS_NET_TRACE_INFO',
  'ohos.permission.READ_WHOLE_CALENDAR',
  'ohos.permission.WRITE_WHOLE_CALENDAR',
  'ohos.permission.SET_SYSTEMSHARE_APPLAUNCHTRUSTLIST',
  'ohos.permission.HOOK_KEY_EVENT', 'ohos.permission.WEB_NATIVE_MESSAGING',
  'ohos.permission.SUBSCRIBE_NOTIFICATION',
  'ohos.permission.CUSTOM_SCREEN_RECORDING',
  'ohos.permission.GET_IP_MAC_INFO', 'ohos.permission.ACCESS_USER_FULL_DISK',
  'ohos.permission.kernel.LOAD_INDEPENDENT_LIBRARY',
  'ohos.permission.CRYPTO_EXTENSION_REGISTER'
];

export class AgcProfile {
  private static async fingerprintOfPem(pem: string): Promise<string> {
    const match = /-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----/.exec(pem);
    if (!match) throw new Error('签名证书格式无效');
    const der = new util.Base64Helper().decodeSync(match[1].replace(/\s/g, ''));
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: der });
    const digest = (await md.digest()).data;
    let fingerprint = '';
    for (let i = 0; i < digest.length; i++) {
      fingerprint += digest[i].toString(16).padStart(2, '0');
    }
    return fingerprint.toUpperCase();
  }

  /** 对 Profile 内实际签包证书求指纹，而不是误用 .cer 文件里的根证书。 */
  static async signingFingerprint(path: string): Promise<string> {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
    const pem = String(bundle?.['development-certificate'] ?? '');
    return AgcProfile.fingerprintOfPem(pem);
  }

  static appIdentifier(path: string): string {
    const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
    const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
    return String(bundle?.['app-identifier'] ?? '');
  }

  static effectiveAcls(requested: string[]): string[] {
    return requested.filter((name: string, index: number) =>
      GRANTABLE_ACLS.includes(name) && requested.indexOf(name) === index).sort();
  }

  static valid(path: string, bundleName: string, udid: string,
    certificatePath: string, acls: string[]): boolean {
    if (!fileIo.accessSync(path)) return false;
    try {
      const profile = JSON.parse(readSignedProfile(path)) as Record<string, Object>;
      const bundle = profile['bundle-info'] as Record<string, Object> | undefined;
      const validity = profile['validity'] as Record<string, Object> | undefined;
      const debug = profile['debug-info'] as Record<string, Object> | undefined;
      const grants = profile['acls'] as Record<string, Object> | undefined;
      const deviceIds = debug?.['device-ids'] as string[] | undefined;
      const allowed = grants?.['allowed-acls'] as string[] | undefined;
      const now = Date.now() / 1000;
      return String(profile['type'] ?? '') === 'debug' &&
        String(bundle?.['bundle-name'] ?? '') === bundleName &&
        Number(validity?.['not-before'] ?? 0) <= now &&
        Number(validity?.['not-after'] ?? 0) > now + 3600 &&
        (deviceIds ?? []).includes(udid) &&
        acls.every((acl: string) => (allowed ?? []).includes(acl)) &&
        profileMatchesCertificate(path, certificatePath);
    } catch (_) {
      return false;
    }
  }

  static async ensure(context: common.UIAbilityContext, account: DeveloperAccount,
    identity: LocalSigningIdentity, bundleName: string, udid: string,
    requestedPermissions: string[]): Promise<string> {
    if (identity.accountId !== account.userId || !/^\d{1,64}$/.test(identity.certId)) {
      throw new Error('签名证书与当前账号不一致');
    }
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName) ||
      !/^[0-9a-fA-F]{32,128}$/.test(udid)) {
      throw new Error('应用包名或设备 UDID 无效');
    }
    const dir = context.filesDir + '/signing-profiles';
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
    const path = dir + '/' + bundleName + '-' + identity.certId + '-' +
      udid.substring(0, 12).toLowerCase() + '.p7b';
    const acls = AgcProfile.effectiveAcls(requestedPermissions);
    if (AgcProfile.valid(path, bundleName, udid, identity.certificatePath, acls)) return path;

    const agc = new AgcClient(account);
    let devices = await agc.devices();
    if (!devices.some((item: Record<string, Object>) => String(item['udid'] ?? '') === udid)) {
      await agc.registerDevice(udid);
      devices = await agc.devices();
    }
    const ids = devices.filter((item: Record<string, Object>) =>
      String(item['udid'] ?? '') === udid).map((item: Record<string, Object>) =>
      String(item['id'] ?? '')).filter((id: string) => id.length > 0);
    if (ids.length === 0) throw new Error('AGC 设备登记尚未生效');
    const name = ('qingqi-' + bundleName + '-' + udid.substring(0, 8)).substring(0, 64);
    const url = await agc.createProfile(name, identity.certId, ids, acls, bundleName);
    const bytes = await agc.download(url);
    const temporary = path + '.part';
    try {
      SigningIdentityRecovery.writeFile(temporary, bytes);
      if (!AgcProfile.valid(temporary, bundleName, udid, identity.certificatePath, acls)) {
        throw new Error('AGC 返回的设备授权与应用、设备或证书不匹配');
      }
      fileIo.renameSync(temporary, path);
      return path;
    } finally {
      if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
    }
  }
}
