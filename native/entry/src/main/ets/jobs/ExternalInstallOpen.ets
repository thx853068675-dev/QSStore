import { Want } from '@kit.AbilityKit';
import { router, promptAction, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalImport } from './LocalImport';
import { StorePageMotion } from '../theme/StorePageMotion';

/** One pending user selection; receiving a file never creates or starts an install. */
export class ExternalInstallOpen {
  private static uri: string = '';
  private static revision: number = 0;
  private static routeTimer: number = -1;
  private static routeAttempts: number = 0;
  private static routing: boolean = false;
  private static ui?: UIContext;

  static configure(ui: UIContext): void { ExternalInstallOpen.ui = ui; }

  private static fileUri(want: Want): string {
    // Explicit FileOpen callers may omit action. A primary URI must not be
    // replaced by one of its dependency streams when its format is unsupported.
    if (typeof want.uri === 'string' && want.uri.length > 0) return want.uri;
    const stream = want.parameters?.['ability.params.stream'];
    if (typeof stream === 'string') return stream;
    if (Array.isArray(stream) && stream.length === 1 && typeof stream[0] === 'string') {
      return stream[0] as string;
    }
    return '';
  }

  static receive(want: Want): boolean {
    const uri = ExternalInstallOpen.fileUri(want);
    hilog.info(0x0000, 'QingqiFileOpen', 'receive action=%{public}s fileUri=%{public}s',
      want.action ?? '', String(uri.startsWith('file://')));
    // The file payload, not a caller-specific action, determines a file open.
    // Opening is preview-only; fileIo enforces the system's read grant on import.
    if (!uri.startsWith('file://')) return false;
    try {
      const name = decodeURIComponent(uri.split('?')[0]).split('/').pop() ?? '';
      if (!LocalImport.supportsName(name)) {
        hilog.warn(0x0000, 'QingqiFileOpen', 'unsupported file extension=%{public}s', name.split('.').pop() ?? '');
        return false;
      }
    } catch (_) { return false; }
    ExternalInstallOpen.uri = uri;
    ExternalInstallOpen.routeAttempts = 0;
    AppStorage.setOrCreate<number>('externalFileOpenRevision', ++ExternalInstallOpen.revision);
    return true;
  }
  static take(): string {
    const uri = ExternalInstallOpen.uri; ExternalInstallOpen.uri = ''; return uri;
  }
  static openPending(): void {
    if (!ExternalInstallOpen.uri || ExternalInstallOpen.routeTimer !== -1 || ExternalInstallOpen.routing) return;
    const current = ExternalInstallOpen.ui ? ExternalInstallOpen.ui.getRouter().getState() : router.getState();
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
    hilog.info(0x0000, 'QingqiFileOpen', 'route current=%{public}s name=%{public}s', current.path, current.name);
    if (current.path === 'pages/LocalInstall' || current.name === 'LocalInstall') return;
    ExternalInstallOpen.routing = true;
    const selection = ExternalInstallOpen.revision;
    StorePageMotion.pushUrl({ url: 'pages/LocalInstall', params: { external: true } }, router.RouterMode.Single,
      ExternalInstallOpen.ui)
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
    ExternalInstallOpen.ui = undefined;
  }
}
