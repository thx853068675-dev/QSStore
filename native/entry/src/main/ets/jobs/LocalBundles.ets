import { InstalledAppRegistry } from './InstalledAppRegistry';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 查本机装了哪些应用。
 *
 * 之前判断「装没装」走的是无线调试 + HDC：要先连上调试端口才能问一句。可是
 * 应用就在这台设备上，系统自己就知道装了哪些包 —— `bundleManager.getBundleInfo`
 * 同步返回，不用网络、不用无线调试、也不用起子进程。
 *
 * 于是「已安装 / 打开」这类状态不再依赖设备连接，冷启动第一次绘制就能给对。
 *
 * **但这个查询是要权限的**，SDK 里写得很清楚
 * （`@ohos.bundle.bundleManager.d.ts:1389`）：
 *
 *     @permission ohos.permission.GET_BUNDLE_INFO_PRIVILEGED
 *                 or ohos.permission.GET_BUNDLE_INFO
 *
 * PRIVILEGED 是系统级权限、普通应用拿不到，所以只能在 module.json5 里申请
 * `GET_BUNDLE_INFO`。即使申请了，设备策略不同也可能给出 201（权限不足）。
 *
 * 关键点：**「查不到」不等于「没装」。** 以前两者都返回 0，于是一旦权限
 * 不足，外部安装（没走本应用）的应用就识别不到，有安装记录的应用还会一直
 * 显示「更新」。现在把三种情况分开：
 *
 *     正数  → 已安装，这就是设备上的 versionCode
 *     0     → 确认没装（系统明确报了「包不存在」）
 *     -1    → 无法核实（权限不足等），调用方应回退到 HDC 查询，
 *             并且在拿到确定答案前不要把状态显示成「未安装」
 */
export class LocalBundles {
  /// 无法核实时的返回值。调用方必须与 0（确认未装）区别对待。
  static readonly UNKNOWN: number = -1;

  static isSelfBundle(bundleName: string): boolean {
    try {
      return bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name === bundleName;
    } catch (_) {
      return false;
    }
  }

  /** 当前安装器的签名证书指纹；覆盖安装必须沿用这张证书。 */
  static selfSigningFingerprint(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
      return String(info.signatureInfo?.fingerprint ?? '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();
    } catch (_) {
      return '';
    }
  }

  static selfAppIdentifier(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
      return String(info.signatureInfo?.appIdentifier ?? '');
    } catch (_) {
      return '';
    }
  }

  /**
   * 本机安装的版本号。
   *
   * 供页面展示。系统查询不可用时沿用 HDC 上次确认并落盘的结果，让外部
   * 侧载应用在进程重启或无线调试离线后仍能显示状态。安装完成判定必须调用
   * liveInstalledVersion，历史缓存不是实时设备证据。
   */
  static installedVersion(bundleName: string): number {
    const live = LocalBundles.liveInstalledVersion(bundleName);
    return LocalBundles.isKnown(live) ? live : InstalledAppRegistry.version(bundleName);
  }

  /** 只返回指定已安装构建的版本名，不能把当前版本名套到旧安装历史上。 */
  static installedVersionName(bundleName: string, versionCode: number): string {
    if (versionCode <= 0 || bundleName.length === 0) return '';
    try {
      const own = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (own.name === bundleName) {
        return own.versionCode === versionCode ? String(own.versionName ?? '').trim() : '';
      }
      const info = bundleManager.getBundleInfoSync(bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode === versionCode ? String(info.versionName ?? '').trim() : '';
    } catch (_) {
      return '';
    }
  }

  /** 安装决策只接受系统当前查询；显示层的历史缓存不能充当完成证据。 */
  static liveInstalledVersion(bundleName: string): number {
    // 非法包名是「调用方给错了」，不是「系统查不到」：报 UNKNOWN 会让上层
    // 白白回退一次 HDC，所以这里直接判为未装。
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) return 0;
    // 自更新重启时无需 GET_BUNDLE_INFO 权限和无线调试即可确认当前包版本。
    try {
      const own = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (own.name === bundleName && own.versionCode > 0) return own.versionCode;
    } catch (_) {}
    try {
      const info = bundleManager.getBundleInfoSync(bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const code = Number(info?.versionCode ?? 0);
      return Number.isFinite(code) && code > 0 ? code : 0;
    } catch (error) {
      // 包不存在时系统也会抛错（17700001），那才是「没装」的正常信号；
      // 其余错误（201 权限不足等）说明我们没资格下结论。
      return LocalBundles.notInstalledError(error) ? 0 : LocalBundles.UNKNOWN;
    }
  }

  /// 只把「包不存在」当作确认未装；其他一律视为无法核实。
  private static notInstalledError(error: Object): boolean {
    const code = (error as BusinessError).code;
    // 17700001: bundle not exists
    return code === 17700001;
  }

  /// 版本是否已经问出来了（用来区分 UNKNOWN）。0 也算已知。
  static isKnown(version: number): boolean {
    return version !== LocalBundles.UNKNOWN;
  }

  /// 只在「确认已装」时为 true；无法核实时返回 false，调用方需另行回退。
  static isInstalled(bundleName: string): boolean {
    return LocalBundles.installedVersion(bundleName) > 0;
  }
}
