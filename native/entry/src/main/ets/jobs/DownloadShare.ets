import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { DownloadLibrary, DownloadedPackage } from './DownloadLibrary';
import { I18n } from '../data/I18n';

/** The system chooses registered file-sharing targets. No app trust list or private receipt is exposed. */
export class DownloadShare {
  private generation: number = 0;
  private inFlight: boolean = false;
  private cancelCurrent: (() => void) | undefined = undefined;
  private panelCancel: (() => void) | undefined = undefined;

  async open(context: common.UIAbilityContext, id: string): Promise<void> {
    if (this.inFlight) throw new Error(I18n.t('分享正在准备，请稍候'));
    this.inFlight = true;
    const generation = ++this.generation;
    let canceled: () => void = () => {};
    const cancellation = new Promise<void>((resolve: () => void) => { canceled = resolve; });
    this.cancelCurrent = canceled;
    try { await Promise.race([this.run(context, id, generation), cancellation]); }
    finally {
      if (this.cancelCurrent === canceled) { this.cancelCurrent = undefined; this.inFlight = false; }
    }
  }

  cancel(): void {
    this.generation++;
    this.panelCancel?.();
    this.cancelCurrent?.();
  }

  private static typeOf(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.hap')) return uniformTypeDescriptor.UniformDataType.OPENHARMONY_HAP;
    if (lower.endsWith('.zip')) return uniformTypeDescriptor.UniformDataType.ZIP_ARCHIVE;
    const dot = lower.lastIndexOf('.');
    if (dot < 0) return uniformTypeDescriptor.UniformDataType.FILE;
    try {
      return uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(lower.substring(dot)) ||
        uniformTypeDescriptor.UniformDataType.FILE;
    } catch (_) { return uniformTypeDescriptor.UniformDataType.FILE; }
  }

  private static async uri(context: common.UIAbilityContext, row: DownloadedPackage): Promise<string> {
    // A verified old original remains shareable when public-directory authorization is temporarily unavailable.
    const legacy = context.filesDir + '/downloads/';
    if (row.path.startsWith(legacy)) {
      const name = row.path.substring(legacy.length);
      if (name && !/[\\/\u0000-\u001f]/.test(name) && name !== '.' && name !== '..') {
        return fileUri.getUriFromPath(row.path);
      }
      throw new Error(I18n.t('下载文件位置无效'));
    }
    const location = await DownloadLibrary.getLocation(context);
    const directory = location.path.replace(/\/$/, '');
    if (row.path.startsWith(directory + '/')) {
      const name = row.path.substring(directory.length + 1);
      if (!name || name === '.' || name === '..' || /[\\/\u0000-\u001f]/.test(name) || !location.uri) throw new Error(I18n.t('下载文件位置无效'));
      return location.uri.replace(/\/$/, '') + '/' + encodeURIComponent(name);
    }
    // The helper derives these previous public roots from the system-authorized Download directory each process.
    const authority = /^(file:\/\/[^/?#]+)(\/[^?#]*)$/.exec(location.uri);
    for (const known of location.knownPaths ?? []) {
      const previous = known.replace(/\/$/, '');
      if (!row.path.startsWith(previous + '/') || authority === null) continue;
      const name = row.path.substring(previous.length + 1);
      // An older app folder may contain the duplicated child directory. Try
      // that more specific authorized directory before rejecting a nested path.
      if (!name || name === '.' || name === '..' || /[\\/\u0000-\u001f]/.test(name)) continue;
      return authority[1] + row.path.split('/').map((part: string) => encodeURIComponent(part)).join('/');
    }
    throw new Error(I18n.t('下载文件位置无效'));
  }

  private async run(context: common.UIAbilityContext, id: string, generation: number): Promise<void> {
    const release = DownloadLibrary.reserve(context, id);
    let controller: systemShare.ShareController | undefined = undefined;
    let finish: () => void = () => {};
    let listening = false;
    try {
      const row = await DownloadLibrary.verify(context, id);
      if (generation !== this.generation) return;
      const uri = await DownloadShare.uri(context, row);
      if (generation !== this.generation) return;
      const data = new systemShare.SharedData({ utd: DownloadShare.typeOf(row.name), uri,
        title: row.name || row.title });
      controller = new systemShare.ShareController(data);
      const dismissed = new Promise<void>((resolve: () => void) => { finish = resolve; });
      this.panelCancel = finish;
      controller.on('dismiss', finish); listening = true;
      // show() may resolve when the panel appears; its lifetime ends at dismiss, not at that resolution.
      await Promise.race([controller.show(context, { previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE }), dismissed]);
      await dismissed;
    } finally {
      if (listening) { try { controller?.off('dismiss', finish); } catch (_) {} }
      if (this.panelCancel === finish) this.panelCancel = undefined;
      release();
    }
  }
}
