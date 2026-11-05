import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { I18n } from '../data/I18n';

export class DownloadDirectoryLocation {
  path: string = '';
  uri: string = '';
  displayPath: string = '';
  knownPaths: string[] = [];
}

class DownloadRoot {
  path: string = '';
  appPath: string = '';
  authority: string = '';
}

/** DOWNLOAD supplies the authority each process; no guessed storage/user path or extra Picker UI. */
export class PublicDownloadDirectory {
  private static readonly folderName: string = 'download';
  // 旧版下载目录名是磁盘上的真实身份，不随界面语言变化。
  private static readonly legacyFolderName: string = '轻启·安装器';
  private static cached: Map<string, DownloadDirectoryLocation> = new Map();
  private static opening: Map<string, Promise<DownloadDirectoryLocation>> = new Map();

  private static copy(value: DownloadDirectoryLocation): DownloadDirectoryLocation {
    const result = new DownloadDirectoryLocation();
    result.path = value.path; result.uri = value.uri; result.displayPath = value.displayPath;
    result.knownPaths = value.knownPaths.slice();
    return result;
  }

  private static parse(uri: string, context: common.UIAbilityContext): DownloadRoot {
    const authority = /^(file:\/\/[^/?#]*)(\/[^?#]*)$/.exec(uri);
    if (authority === null || /[\\\u0000-\u001f\u007f]/.test(uri)) throw new Error(I18n.t('系统未返回有效下载目录'));
    const file = new fileUri.FileUri(uri);
    if (file.isRemoteUri()) throw new Error(I18n.t('下载目录不是本机目录'));
    const path = file.path.replace(/\/+$/, '');
    const parts = path.split('/');
    if (!path.startsWith('/') || /[\\\u0000-\u001f\u007f]/.test(path) ||
      parts.slice(1).some((part: string) => !part || part === '.' || part === '..') ||
      [context.filesDir, context.cacheDir].some((privatePath: string) => !!privatePath &&
        (path === privatePath || path.startsWith(privatePath + '/')))) throw new Error('系统未返回公共下载目录');
    const root = parts.findIndex((part: string) => /^(?:downloads?|下载)$/i.test(part));
    if (root < 1 || parts.length - root > 2) throw new Error(I18n.t('系统返回的下载目录结构无效'));
    if (parts.length - root !== 2) throw new Error(I18n.t('系统未返回应用下载目录'));
    const result = new DownloadRoot();
    result.path = parts.slice(0, root + 1).join('/'); result.appPath = path; result.authority = authority[1];
    return result;
  }

  private static uri(root: DownloadRoot, path: string): string {
    return root.authority + path.split('/').map((part: string) => encodeURIComponent(part)).join('/');
  }

  private static async directory(path: string): Promise<void> {
    const stat = await fileIo.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('下载目录已被替换');
  }

  private static async writable(path: string): Promise<void> {
    await PublicDownloadDirectory.directory(path);
    if (!await fileIo.access(path, fileIo.AccessModeType.READ_WRITE)) throw new Error('下载目录不可写');
  }

  private static async child(root: DownloadRoot): Promise<DownloadDirectoryLocation> {
    // Only the directory actually supplied by DOWNLOAD is an authorized parent.
    await PublicDownloadDirectory.writable(root.appPath);
    const path = root.appPath + '/' + PublicDownloadDirectory.folderName;
    if (!await fileIo.access(path)) await fileIo.mkdir(path);
    await PublicDownloadDirectory.writable(path);
    const result = new DownloadDirectoryLocation();
    result.path = path; result.uri = PublicDownloadDirectory.uri(root, path);
    result.displayPath = '下载' + path.substring(root.path.length);
    result.knownPaths = [path];
    // Legacy locations are a read/migration allowlist, never alternative write targets.
    const legacyPaths = [root.path + '/' + PublicDownloadDirectory.legacyFolderName,
      root.appPath + '/' + PublicDownloadDirectory.legacyFolderName];
    legacyPaths.forEach((legacyPath: string) => {
      if (!result.knownPaths.includes(legacyPath)) result.knownPaths.push(legacyPath);
    });
    return result;
  }

  private static async prepare(context: common.UIAbilityContext): Promise<DownloadDirectoryLocation> {
    const previous = PublicDownloadDirectory.cached.get(context.filesDir);
    if (previous !== undefined) {
      try {
        await PublicDownloadDirectory.writable(previous.path.substring(0, previous.path.lastIndexOf('/')));
        await PublicDownloadDirectory.writable(previous.path);
        return PublicDownloadDirectory.copy(previous);
      } catch (_) {
        PublicDownloadDirectory.cached.delete(context.filesDir);
      }
    }
    const uris = await new picker.DocumentViewPicker(context).save({ pickerMode: picker.DocumentPickerMode.DOWNLOAD });
    if (uris.length !== 1) throw new Error(I18n.t('无法取得公共下载目录，请稍后重试'));
    const root = PublicDownloadDirectory.parse(uris[0], context);
    let location: DownloadDirectoryLocation;
    try { location = await PublicDownloadDirectory.child(root); }
    catch (_) { throw new Error('公共下载目录暂不可用，请稍后重试'); }
    PublicDownloadDirectory.cached.set(context.filesDir, PublicDownloadDirectory.copy(location));
    return location;
  }

  static ensure(context: common.UIAbilityContext): Promise<DownloadDirectoryLocation> {
    let work = PublicDownloadDirectory.opening.get(context.filesDir);
    if (work === undefined) {
      work = PublicDownloadDirectory.prepare(context);
      PublicDownloadDirectory.opening.set(context.filesDir, work);
      const current = work;
      const done = (): void => {
        if (PublicDownloadDirectory.opening.get(context.filesDir) === current) {
          PublicDownloadDirectory.opening.delete(context.filesDir);
        }
      };
      work.then(done, done);
    }
    return work.then((location: DownloadDirectoryLocation) => PublicDownloadDirectory.copy(location));
  }
}
