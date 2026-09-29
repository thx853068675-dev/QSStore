import { bundleManager } from '@kit.AbilityKit';

/**
 * 查本机装了哪些应用。
 *
 * 之前判断「装没装」走的是无线调试 + HDC：要先连上调试端口才能问一句。可是
 * 应用就在这台设备上，系统自己就知道装了哪些包 —— `bundleManager.getBundleInfo`
 * 同步返回，不用网络、不用无线调试、也不用起子进程。
 *
 * 于是「已安装 / 打开」这类状态不再依赖设备连接，冷启动第一次绘制就能给对。
 */
export class LocalBundles {
  /**
   * 本机安装的版本号；没装返回 0。
   *
   * 只对格式合法的包名查询：非法名字系统会抛参数错误，和「没装」混在一起不好查。
   */
  static installedVersion(bundleName: string): number {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName)) return 0;
    try {
      const info = bundleManager.getBundleInfoSync(bundleName,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const code = Number(info?.versionCode ?? 0);
      return Number.isFinite(code) && code > 0 ? code : 0;
    } catch (_) {
      // 未安装时系统直接抛错，这就是「没装」的正常信号
      return 0;
    }
  }

  static isInstalled(bundleName: string): boolean {
    return LocalBundles.installedVersion(bundleName) > 0;
  }
}
