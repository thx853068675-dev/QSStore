import { AppBackground } from '../data/AppBackgroundPreferences';
import { AppThemeBackground } from '../components/AppThemeBackground';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { ungrabHapz } from 'libhap_core.so';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { BackgroundInstallTask } from '../jobs/BackgroundInstallTask';
import { LocalImport } from '../jobs/LocalImport';
import { DownloadLibrary, DownloadedPackage } from '../jobs/DownloadLibrary';
import { PackageArchive } from '../jobs/PackageArchive';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { WirelessDebugLifecycle } from '../jobs/WirelessDebugLifecycle';
import { Palette } from '../theme/Palette';
import { StoreLayout, StorePageHeader } from '../theme/StoreDesign';
import { StorePageMotion } from '../theme/StorePageMotion';
import { I18n } from '../data/I18n';

const GRAB_OWNER = 'appgallery-grab';
const GRAB_TIMEOUT_MS = 8 * 60 * 1000;

class GrabTask {
  url: string;
  label: string;
  state: string;
  detail: string;
  at: number;
  constructor(url: string, label: string, state: string, detail: string) {
    this.url = url; this.label = label; this.state = state; this.detail = detail; this.at = Date.now();
  }
}

@Entry
@Component
struct AppGalleryGrab {
  @StorageProp('appBackground') private themeState: AppBackground = new AppBackground();
  @StorageProp('darkMode') private darkMode: boolean = false;
  @StorageProp('statusBarInset') private statusBarInset: number = 0;
  @StorageProp('windowWidth') private windowWidth: number = 0;
  @StorageProp('navigationBottomInset') private navigationBottomInset: number = 0;
  @State private phase: string = 'idle';
  @State private message: string = '';
  @State private detail: string = '';
  @State private progress: number = 0;
  @State private url: string = '';
  @State private resultPath: string = '';
  @State private files: DownloadedPackage[] = [];
  @State private grabbedCount: number = 0;
  @State private tasks: GrabTask[] = [];
  private ctx: common.UIAbilityContext | null = null;
  private timer: number = -1;
  private startedAt: number = 0;
  private polls: number = 0;
  private lastActivityAt: number = 0;
  private handled: Set<string> = new Set<string>();
  private censoredHandled: Set<string> = new Set<string>();
  private queue: GrabTask[] = [];
  private downloading: boolean = false;
  private polling: boolean = false;
  private disposed: boolean = false;
  private working: boolean = false;

  private colors(): Palette { return Palette.forMode(this.darkMode); }
  private cardSurface(): string { return Palette.containerPaint(this.colors().surface, this.themeState.containerOpacity); }

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    BackgroundInstallTask.configure(this.ctx);
    this.loadFiles();
    setTimeout(() => { if (!this.disposed) this.start(); }, 320);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopTimer();
    this.restoreLogs();
  }

  onBackPress(): boolean {
    this.restoreLogs();
    router.back();
    return true;
  }

  private stopTimer(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private async loadFiles(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) return;
    try {
      const rows = await DownloadLibrary.list(ctx);
      if (!this.disposed) this.files = rows.filter((row: DownloadedPackage) => /\.(hap|app)$/i.test(row.path));
    } catch (_) { if (!this.disposed) this.files = []; }
  }

  private fail(error: Object): void {
    if (this.disposed) return;
    this.phase = 'error';
    this.message = error instanceof Error ? error.message : String(error);
    this.detail = '';
    this.stopTimer();
    this.restoreLogs();
  }

  private async restoreLogs(): Promise<void> {
    const ctx = this.ctx;
    WirelessDebugLifecycle.endGrab(GRAB_OWNER);
    this.stopTimer();
    if (ctx !== null) {
      try { await HdcDeviceBridge.grabLog(ctx, 'capture_stop'); } catch (_) {}
      try { await HdcDeviceBridge.grabLog(ctx, 'restore'); } catch (_) {}
    }
    try { await BackgroundInstallTask.release(GRAB_OWNER); } catch (_) {}
  }

  private async start(): Promise<void> {
    if (this.working || this.disposed) return;
    this.working = true;
    this.stopTimer();
    this.phase = 'preparing';
    this.message = I18n.t('正在准备提取…');
    this.detail = I18n.t('检查无线调试连接并调整应用市场日志级别');
    this.progress = 0;
    this.url = '';
    this.resultPath = '';
    this.grabbedCount = 0;
    this.tasks = [];
    this.handled = new Set<string>();
    this.censoredHandled = new Set<string>();
    this.queue = [];
    try {
      const ctx = this.ctx;
      if (ctx === null) throw new Error(I18n.t('无法获取应用上下文'));
      await BackgroundInstallTask.acquire(GRAB_OWNER);
      // Keep the debug channel alive while the user installs several apps in
      // AppGallery; otherwise backgrounding releases HDC and detection stalls.
      WirelessDebugLifecycle.beginGrab(GRAB_OWNER);
      const output = await HdcDeviceBridge.grabLog(ctx, 'prepare');
      if (/\[Fail\]|error:/i.test(output)) throw new Error(I18n.t('无法调整应用市场日志：') + output);
      // Shell-side stream keeps writing while the app is suspended in the
      // background, so links are not lost to the small hilog ring buffer.
      try { await HdcDeviceBridge.grabLog(ctx, 'capture_start'); } catch (_) {}
      this.phase = 'watching';
      this.polls = 0;
      this.startedAt = Date.now();
      this.lastActivityAt = this.startedAt;
      this.message = I18n.t('请在应用市场点「下载」');
      this.detail = I18n.t('可连续安装多个应用，提取完一个会继续等待下一个');
      this.timer = setInterval(() => { this.poll(); }, 2000);
    } catch (error) {
      this.fail(error);
    } finally {
      this.working = false;
    }
  }

  private async poll(): Promise<void> {
    if (this.polling || this.disposed ||
      (this.phase !== 'watching' && this.phase !== 'fetching')) return;
    this.polling = true;
    try {
      const ctx = this.ctx;
      if (ctx === null) return;
      // Detection continues while a queued download runs; only an idle
      // session (nothing downloading and nothing queued) times out.
      if (!this.downloading && this.queue.length === 0 &&
        Date.now() - this.lastActivityAt > GRAB_TIMEOUT_MS) {
        this.fail(new Error(I18n.t('等待超时：8 分钟内没有新的下载链接')));
        return;
      }
      const capture = await HdcDeviceBridge.grabLog(ctx, 'capture_read');
      let urls = this.pickUrls(capture);
      for (const jsonUrl of this.pickJsonUrls(capture)) {
        if (!urls.includes(jsonUrl)) urls.push(jsonUrl);
      }
      if (urls.length === 0) {
        // The shell stream may not have started; fall back to a direct dump.
        urls = this.pickUrls(await HdcDeviceBridge.grabLog(ctx, 'poll'));
      }
      this.polls++;
      let added = 0;
      for (const found of urls) {
        if (this.handled.has(found)) continue;
        this.handled.add(found);
        await this.enqueueUrl(ctx, found);
        added++;
      }
      this.markCensored(capture);
      if (added === 0 && urls.length === 0 && this.polls % 5 === 1 && !this.downloading) {
        this.detail = I18n.t('已检查 ') + this.polls + I18n.t(' 次，继续等待…');
      }
    } catch (_) {
      // A transient HDC failure must not end the watch; keep polling.
    } finally {
      this.polling = false;
    }
  }

  /** Some responses carry the package URL directly; unescape and accept it. */
  private pickJsonUrls(text: string): string[] {
    const result: string[] = [];
    const matches = text.match(/"(?:packageUrl|downloadUrl)":"(https:[^"]+)"/g);
    if (matches === null) return result;
    for (const raw of matches) {
      const start = raw.indexOf('https:');
      if (start < 0) continue;
      let url = raw.substring(start, raw.length - 1).replace(/\\\//g, '/');
      if (!/\.(hapz|app|hap)(\?|$)/i.test(url)) continue;
      if (url.includes('/apk/profiles/')) continue;
      if (!result.includes(url)) result.push(url);
    }
    return result;
  }

  /** Log the app when AppGallery censors packageUrl and never prints a URL. */
  private markCensored(text: string): void {
    const lines = text.split('\n');
    for (const line of lines) {
      if (!line.includes('fetchHarmonyFiles') || !line.includes('"packageUrl":"*"')) continue;
      const found = line.match(/"pkgName":"([A-Za-z0-9_.]+)"/g);
      if (found === null) continue;
      for (const raw of found) {
        const pkg = raw.substring(raw.indexOf(':') + 2, raw.length - 1);
        if (pkg.length === 0 || this.censoredHandled.has(pkg)) continue;
        this.censoredHandled.add(pkg);
        if (this.tasks.some((task: GrabTask) => task.label.includes(pkg))) continue;
        const name = InstalledAppRegistry.displayName(pkg);
        const label = name.length > 0 ? name + '（' + pkg + '）' : pkg;
        this.tasks = [new GrabTask('censored:' + pkg, label, 'skipped',
          I18n.t('应用市场未打印下载直链（packageUrl 被脱敏）')), ...this.tasks].slice(0, 20);
        this.message = I18n.t('已检测到 ') + label + I18n.t('，但应用市场未打印直链');
        this.detail = I18n.t('该应用无法从日志提取');
      }
    }
  }

  private async enqueueUrl(ctx: common.UIAbilityContext, found: string): Promise<void> {
    this.url = found;
    this.lastActivityAt = Date.now();
    const encOutput = await HdcDeviceBridge.grabLog(ctx, 'encType');
    const pkgName = this.pickPackage(encOutput);
    const appLabel = pkgName.length === 0 ? I18n.t('识别中…') :
      (InstalledAppRegistry.displayName(pkgName).length > 0 ?
        InstalledAppRegistry.displayName(pkgName) + '（' + pkgName + '）' : pkgName);
    const protectedApp = this.pickEncType(encOutput) === 3;
    const task = new GrabTask(found, appLabel,
      protectedApp ? 'skipped' : 'queued',
      protectedApp ? I18n.t('受应用市场保护（encType:3）') : I18n.t('等待下载'));
    this.tasks = [task, ...this.tasks].slice(0, 20);
    if (protectedApp) {
      this.message = I18n.t('已跳过受保护的应用');
      this.detail = appLabel;
    } else {
      this.queue.push(task);
      this.message = I18n.t('已捕获，开始排队…');
      this.detail = I18n.t('队列中 ') + this.queue.length + I18n.t(' 个');
      this.drainQueue();
    }
  }

  /** Downloads queued packages one at a time; detection keeps running. */
  private async drainQueue(): Promise<void> {
    if (this.downloading || this.disposed) return;
    this.downloading = true;
    try {
      while (!this.disposed && this.queue.length > 0) {
        const task = this.queue.shift();
        if (task === undefined) break;
        this.phase = 'fetching';
        this.progress = 0;
        task.state = 'downloading';
        task.detail = '';
        this.updateTask(task);
        this.message = I18n.t('正在下载 ') + task.label;
        try {
          const ctx = this.ctx;
          if (ctx === null) break;
          const saved = await this.fetch(ctx, task.url);
          task.state = 'saved';
          task.detail = saved.substring(saved.lastIndexOf('/') + 1);
          this.grabbedCount++;
          this.updateTask(task);
          await this.loadFiles();
          this.message = this.queue.length > 0 ?
            I18n.t('已保存一个，继续下载队列…') : I18n.t('已保存，继续检测下一个…');
        } catch (error) {
          if (this.disposed) break;
          task.state = 'skipped';
          task.detail = error instanceof Error ? error.message : String(error);
          this.updateTask(task);
          this.message = I18n.t('已跳过：') + task.detail;
          this.detail = this.queue.length > 0 ?
            I18n.t('队列中还有 ') + this.queue.length + I18n.t(' 个') :
            I18n.t('继续等待下一个下载…');
        }
        this.lastActivityAt = Date.now();
      }
    } finally {
      this.downloading = false;
      if (!this.disposed && this.phase === 'fetching') this.phase = 'watching';
    }
  }

  private async fetch(ctx: common.UIAbilityContext, url: string): Promise<string> {
    this.phase = 'fetching';
    this.message = I18n.t('正在下载…');
    this.detail = '';
    try {
      const dir = await DownloadLibrary.directory(ctx);
      const stamp = Date.now();
      const isApp = /\.app(\?|$)/i.test(url);
      const source = ctx.cacheDir + '/grab-' + stamp + (isApp ? '.app' : '.hapz');
      if (fileIo.accessSync(source)) fileIo.unlinkSync(source);
      await this.download(ctx, url, source);
      let extracted = source;
      if (!isApp) {
        extracted = dir + '/grab-' + stamp + '.hap';
        this.detail = I18n.t('解压 hapz…');
        await ungrabHapz(source, extracted);
        if (fileIo.accessSync(source)) fileIo.unlinkSync(source);
      }
      let bundleName = '';
      let versionName = '';
      let displayName = 'grab-' + stamp + (isApp ? '.app' : '.hap');
      try {
        const identity = await PackageArchive.inspect(extracted);
        bundleName = identity.bundleName;
        versionName = identity.versionName;
        if (bundleName.length > 0) {
          displayName = bundleName + (versionName.length > 0 ? '_' + versionName : '') + (isApp ? '.app' : '.hap');
        }
      } catch (_) {}
      const finalPath = await DownloadLibrary.keepGrabbed(ctx, extracted, displayName, bundleName, versionName);
      this.resultPath = finalPath;
      this.progress = 0;
      return finalPath;
    } catch (error) {
      // Let drainQueue() decide whether to keep watching; do not tear down the
      // log session after a single protected/failed package.
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  private async download(ctx: common.UIAbilityContext, url: string, dest: string): Promise<void> {
    const task = await request.agent.create(ctx, {
      action: request.agent.Action.DOWNLOAD,
      url: url,
      mode: request.agent.Mode.BACKGROUND,
      title: I18n.t('应用市场提取'),
      description: I18n.t('下载应用市场安装包'),
      gauge: true,
      saveas: dest,
      overwrite: true,
      retry: true,
      redirect: true,
      timeout: { connectionTimeout: 30 }
    });
    await task.start();
    for (;;) {
      if (this.disposed) { try { await task.pause(); } catch (_) {} throw new Error(I18n.t('已取消')); }
      const info = await request.agent.show(task.tid);
      const processed = info.progress.processed;
      const total = info.progress.sizes.length > 0 ? info.progress.sizes[0] : 0;
      if (total > 0) this.progress = processed / total;
      this.detail = (processed / 1048576).toFixed(1) + ' MB' +
        (total > 0 ? ' / ' + (total / 1048576).toFixed(1) + ' MB' : '');
      if (info.progress.state === request.agent.State.COMPLETED) return;
      if (info.progress.state === request.agent.State.FAILED ||
        info.progress.state === request.agent.State.REMOVED) {
        throw new Error(I18n.t('下载失败'));
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 800));
    }
  }

  private pickUrls(text: string): string[] {
    const matches = text.replace(/\\\//g, '/').match(/https?:\/\/[^\s"'<>\\]+/g);
    const result: string[] = [];
    if (matches === null) return result;
    for (const raw of matches) {
      let url = raw;
      while (url.length > 0 && '),]}"\';'.includes(url.substring(url.length - 1))) {
        url = url.substring(0, url.length - 1);
      }
      if (!/\.(hapz|app|hap)(\?|$)/i.test(url)) continue;
      if (url.includes('/apk/profiles/')) continue;
      if (!url.includes('dbankcdn.com') && !url.includes('hicloud.com') &&
        !url.includes('huawei.com')) continue;
      if (!result.includes(url)) result.push(url);
    }
    return result;
  }

  private pickUrl(text: string): string {
    const matches = text.replace(/\\\//g, '/').match(/https?:\/\/[^\s"'<>\\]+/g);
    if (matches === null) return '';
    for (const raw of matches) {
      let url = raw;
      while (url.length > 0 && '),]}"\';'.includes(url.substring(url.length - 1))) {
        url = url.substring(0, url.length - 1);
      }
      if (!/\.(hapz|app|hap)(\?|$)/i.test(url)) continue;
      if (!url.includes('/dl/appdl/application/')) continue;
      if (url.includes('/apk/profiles/')) continue;
      return url;
    }
    return '';
  }

  private pickEncType(text: string): number {
    const matches = text.match(/encType\s*[:=]\s*(\d+)/gi);
    if (matches === null) return 0;
    let last = 0;
    for (const match of matches) {
      const digits = match.match(/(\d+)$/);
      if (digits !== null) {
        const value = Number(digits[0]);
        if (value > 0) last = value;
      }
    }
    return last;
  }

  private pickPackage(text: string): string {
    // Continuous sessions can contain several downloads; the last task is
    // the one whose URL we just picked.
    const matches = text.match(/dlPkgName\s*=\s*([A-Za-z0-9_.]+)/g);
    if (matches === null || matches.length === 0) return '';
    const last = matches[matches.length - 1];
    return last.substring(last.indexOf('=') + 1).trim();
  }

  private updateTask(task: GrabTask): void {
    this.tasks = this.tasks.map((item: GrabTask) => item.url === task.url ? task : item);
  }

  private async openAppGallery(): Promise<void> {
    try {
      const ctx = this.ctx as common.UIAbilityContext;
      await ctx.startAbility({ bundleName: 'com.huawei.hmsapp.appgallery', abilityName: 'MainAbility' });
    } catch (_) {
      promptAction.showToast({ message: I18n.t('没能打开应用市场，请手动切换') });
    }
  }

  private async remove(row: DownloadedPackage): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) return;
    try {
      await DownloadLibrary.remove(ctx, row.id);
      await this.loadFiles();
      promptAction.showToast({ message: I18n.t('已删除') + ' ' + row.name });
    } catch (error) {
      promptAction.showToast({ message: error instanceof Error ? error.message : String(error) });
    }
  }

  private async install(path: string): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null) return;
    try {
      const name = path.substring(path.lastIndexOf('/') + 1);
      const previews = await LocalImport.previewsFromUri(ctx, fileUri.getUriFromPath(path));
      if (previews.length !== 1) throw new Error(I18n.t('无法读取安装包'));
      await StorePageMotion.pushUrl({ url: 'pages/LocalInstall', params: { preview: previews[0], direct: true } });
    } catch (error) {
      promptAction.showToast({ message: error instanceof Error ? error.message : String(error) });
    }
  }

  @Builder private action(label: string, primary: boolean, run: () => void) {
    Button(label, { type: ButtonType.Normal })
      .height(StoreLayout.fieldHeight)
      .width('100%')
      .borderRadius(StoreLayout.cardActionRadius)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .backgroundColor(primary ? this.colors().accent : this.colors().fill)
      .fontColor(primary ? this.colors().onAccent : this.colors().text)
      .onClick(run);
  }

  @Builder private statusCard() {
    Column({ space: 10 }) {
      Text(this.message.length > 0 ? this.message : I18n.t('应用市场提取'))
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.colors().text).width('100%');
      if (this.detail.length > 0) {
        Text(this.detail).fontSize(12).lineHeight(18).fontColor(this.colors().textSecondary).width('100%');
      }
      if (this.phase === 'fetching' || this.phase === 'preparing' || this.phase === 'watching') {
        Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
          .height(6).color(this.colors().accent).backgroundColor(this.colors().fill).width('100%');
      }
      if (this.grabbedCount > 0 || this.queue.length > 0) {
        Text(I18n.t('本次已提取 ') + this.grabbedCount + I18n.t(' 个') +
          (this.queue.length > 0 ? I18n.t('，队列中 ') + this.queue.length + I18n.t(' 个') : ''))
          .fontSize(12).fontColor(this.colors().accent).width('100%');
      }
      if (this.phase === 'idle') {
        this.action(I18n.t('开始提取'), true, () => { this.start(); });
      } else if (this.phase === 'watching') {
        this.action(I18n.t('打开应用市场'), true, () => { this.openAppGallery(); });
        this.action(I18n.t('立即读取'), false, () => { this.poll(); });
        this.action(I18n.t('停止'), false, () => {
          this.phase = 'idle';
          this.message = I18n.t('已停止提取');
          this.detail = '';
          this.url = '';
          this.queue = [];
          this.restoreLogs();
        });
      } else if (this.phase === 'done' || this.phase === 'error') {
        if (this.resultPath.length > 0) {
          this.action(I18n.t('签名并安装'), true, () => { this.install(this.resultPath); });
        }
        this.action(I18n.t('再提取一个'), false, () => { this.start(); });
      }
    }.width('100%').padding(18).backgroundColor(this.cardSurface()).borderRadius(StoreLayout.cardRadius);
  }

  private taskStateText(state: string): string {
    if (state === 'saved') return I18n.t('已保存');
    if (state === 'skipped') return I18n.t('已跳过');
    if (state === 'downloading') return I18n.t('下载中');
    return I18n.t('排队中');
  }

  private taskStateColor(state: string): string {
    if (state === 'saved') return this.colors().success;
    if (state === 'skipped') return this.colors().danger;
    if (state === 'downloading') return this.colors().accent;
    return this.colors().textSecondary;
  }

  @Builder private taskRow(task: GrabTask) {
    Row({ space: 10 }) {
      Column().width(8).height(8).borderRadius(4).backgroundColor(this.taskStateColor(task.state));
      Column({ space: 3 }) {
        Text(task.label.length > 0 ? task.label : task.url)
          .fontSize(13).fontColor(this.colors().text).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (task.detail.length > 0) {
          Text(task.detail).fontSize(11).fontColor(this.colors().textTertiary).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Text(this.taskStateText(task.state))
        .fontSize(11).fontColor(this.taskStateColor(task.state));
    }.width('100%').padding({ top: 6, bottom: 6 });
  }

  @Builder private fileRow(row: DownloadedPackage) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.square_and_arrow_down')).fontSize(22).fontColor([this.colors().accent]);
      Column({ space: 3 }) {
        Text(row.name).fontSize(14).fontColor(this.colors().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text((row.version.length > 0 ? row.version + ' · ' : '') + (row.bytes / 1048576).toFixed(1) + ' MB')
          .fontSize(11).fontColor(this.colors().textTertiary);
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button(I18n.t('安装'), { type: ButtonType.Normal })
        .height(34).borderRadius(StoreLayout.cardActionRadius).fontSize(13)
        .backgroundColor(this.colors().accentSoft).fontColor(this.colors().accent)
        .onClick(() => { this.install(row.path); });
      Button(I18n.t('删除'), { type: ButtonType.Normal })
        .height(34).borderRadius(StoreLayout.cardActionRadius).fontSize(13)
        .backgroundColor(this.colors().fill).fontColor(this.colors().danger)
        .onClick(() => { this.remove(row); });
    }.width('100%').padding({ top: 8, bottom: 8 });
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      AppThemeBackground()
      Scroll() {
        Column({ space: 14 }) {
          Text(I18n.t('在应用市场点下载，自动保存 HAP / APP'))
            .fontSize(13).fontColor(this.colors().textSecondary).width('100%');
          this.statusCard();
          if (this.tasks.length > 0) {
            Column({ space: 6 }) {
              Row() {
                Text(I18n.t('本次检测')).fontSize(15).fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().text).layoutWeight(1);
                Text(I18n.t('已提取 ') + this.grabbedCount + I18n.t(' 个') +
                  (this.queue.length > 0 ? I18n.t(' · 队列 ') + this.queue.length : ''))
                  .fontSize(11).fontColor(this.colors().textSecondary);
              }.width('100%');
              ForEach(this.tasks.slice(0, 8), (task: GrabTask) => { this.taskRow(task); },
                (task: GrabTask) => task.url);
            }.width('100%').padding(18).backgroundColor(this.cardSurface()).borderRadius(StoreLayout.cardRadius);
          }
          Column({ space: 6 }) {
            Row() {
              Text(I18n.t('下载目录')).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1);
              Text(I18n.t('刷新')).fontSize(13).fontColor(this.colors().accent).onClick(() => { this.loadFiles(); });
            }.width('100%');
            if (this.files.length === 0) {
              Text(I18n.t('还没有提取过文件。上面开始提取后，成品会自动出现在这里。'))
                .fontSize(12).lineHeight(18).fontColor(this.colors().textSecondary).width('100%').padding({ top: 6, bottom: 6 });
            } else {
              ForEach(this.files, (row: DownloadedPackage) => { this.fileRow(row); }, (row: DownloadedPackage) => row.id);
            }
          }.width('100%').padding(18).backgroundColor(this.cardSurface()).borderRadius(StoreLayout.cardRadius);
          Text(I18n.t('只对应用市场以明文（encType:1）下发的应用有效；微信、QQ 等受 CodeProtect 保护的应用下载到的是加密 hapz，无法解开。提取过程不修改应用市场，结束后会自动恢复日志级别并停止后台任务。'))
            .fontSize(12).lineHeight(19).fontColor(this.colors().textSecondary).width('100%')
            .padding(16).backgroundColor(this.colors().fill).borderRadius(StoreLayout.cardRadius);
        }
        .width('100%')
        .constraintSize({ maxWidth: StoreLayout.frameMaxWidth(this.windowWidth) })
        .padding({ left: StoreLayout.inset(this.windowWidth), right: StoreLayout.inset(this.windowWidth),
          top: this.statusBarInset + 78, bottom: Math.max(36, this.navigationBottomInset + 24) });
      }
      .width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top);

      StorePageHeader({
        title: I18n.t('应用市场提取'), statusInset: this.statusBarInset, visible: true,
        active: this.phase !== 'preparing' && this.phase !== 'fetching',
        action: () => { this.onBackPress(); }, backAction: () => { this.onBackPress(); }
      }).position({ x: 0, y: 0 });
    }
    .width('100%').height('100%').backgroundColor(this.colors().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM]);
  }
}
