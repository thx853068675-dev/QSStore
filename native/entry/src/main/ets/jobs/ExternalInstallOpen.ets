import { Want } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { LocalImport } from './LocalImport';

/** One pending user selection; receiving a file never creates or starts an install. */
export class ExternalInstallOpen {
  private static uri: string = '';
  private static revision: number = 0;
  private static routeTimer: number = -1;
  private static routeAttempts: number = 0;
  private static routing: boolean = false;
  static receive(want: Want): boolean {
    console.info('FileOpen receive: action=' + (want.action ?? '') +
      ' fileUri=' + Boolean(want.uri?.startsWith('file://')));
    if (want.action !== 'ohos.want.action.viewData' || !want.uri?.startsWith('file://')) return false;
    try {
      const name = decodeURIComponent(want.uri.split('?')[0]).split('/').pop() ?? '';
      if (!LocalImport.supportsName(name)) return false;
    } catch (_) { return false; }
    ExternalInstallOpen.uri = want.uri;
    ExternalInstallOpen.routeAttempts = 0;
    AppStorage.setOrCreate<number>('externalFileOpenRevision', ++ExternalInstallOpen.revision);
    return true;
  }
  static take(): string {
    const uri = ExternalInstallOpen.uri; ExternalInstallOpen.uri = ''; return uri;
  }
  static openPending(): void {
    if (!ExternalInstallOpen.uri || ExternalInstallOpen.routeTimer !== -1 || ExternalInstallOpen.routing) return;
    const current = router.getState();
    // loadContent 的完成回调早于首个页面注册。此时 pushUrl 不报错，
    // 却会被首页初始化覆盖；保留文件，等路由有真实页面后再跳转。
    if (!current.path && !current.name) {
      if (++ExternalInstallOpen.routeAttempts <= 30) {
        ExternalInstallOpen.routeTimer = setTimeout(() => {
          ExternalInstallOpen.routeTimer = -1;
          ExternalInstallOpen.openPending();
        }, 32);
      } else promptAction.showToast({ message: '页面尚未就绪，请重新打开文件' });
      return;
    }
    console.info('FileOpen route: current=' + current.path + ' name=' + current.name);
    if (current.path === 'pages/LocalInstall' || current.name === 'LocalInstall') return;
    ExternalInstallOpen.routing = true;
    const selection = ExternalInstallOpen.revision;
    router.pushUrl({ url: 'pages/LocalInstall', params: { external: true } }, router.RouterMode.Single)
      .catch((error: Error) => {
        console.warn('FileOpen route failed: ' + String(error));
        promptAction.showToast({ message: '暂时无法打开签装预览，请重新打开文件' });
      }).finally(() => {
        ExternalInstallOpen.routing = false;
        if (selection !== ExternalInstallOpen.revision) ExternalInstallOpen.openPending();
      });
  }
  static suspendRouting(): void {
    if (ExternalInstallOpen.routeTimer !== -1) clearTimeout(ExternalInstallOpen.routeTimer);
    ExternalInstallOpen.routeTimer = -1;
    ExternalInstallOpen.routeAttempts = 0;
  }
}
