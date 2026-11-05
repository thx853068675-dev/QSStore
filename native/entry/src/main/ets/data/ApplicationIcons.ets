import { http } from '@kit.NetworkKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { ApplicationIconQueue } from './ApplicationIconQueue';
function validInstalledBundle(value: string): boolean { return /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(value); }

const MARKET_URL: string = 'https://web-drcn.hispace.dbankcloud.com/edge/webedge/appinfo';
const DAY: number = 86400000;
export class ApplicationIconMetadata {
  pkgName: string = ''; icon: string = ''; ctype: number = 0;
}
class IconReceipt { bundle: string = ''; checkedAt: number = 0; retryAt: number = 0; available: boolean = false; }
export class ApplicationIconCacheStats { icons: number = 0; bytes: number = 0; }
export function marketApplicationIcon(bundle: string, source: string): string {
  if (!validInstalledBundle(bundle) || source.length > 262144) { return ''; }
  try {
    const metadata = JSON.parse(source) as ApplicationIconMetadata;
    // The catalogue contains native HarmonyOS apps. Do not substitute an Android
    // result with the same display name, or any market search approximation.
    if (metadata.pkgName !== bundle || metadata.ctype !== 17 || typeof metadata.icon !== 'string') { return ''; }
    return /^https:\/\/(?:[a-z0-9-]+\.)*dbankcdn\.com\/[^\s]*$/i.test(metadata.icon) && metadata.icon.length <= 4096 ? metadata.icon : '';
  } catch (_) { return ''; }
}
async function getText(bundle: string): Promise<string> {
  const request = http.createHttp();
  try {
    const response = await request.request(MARKET_URL, { method: http.RequestMethod.POST, expectDataType: http.HttpDataType.STRING, maxLimit: 262144,
      connectTimeout: 3000, readTimeout: 5000, usingCache: false, header: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      extraData: JSON.stringify({ pkgName: bundle, appId: bundle, locale: 'zh_CN', countryCode: 'CN', orderApp: 1 }) });
    if (response.responseCode !== 200 || typeof response.result !== 'string') { throw new Error('应用图标查询未完成'); }
    return response.result;
  } finally { request.destroy(); }
}
async function getThumbnail(url: string): Promise<ArrayBuffer> {
  const request = http.createHttp(); let source: image.ImageSource | undefined; let pixels: image.PixelMap | undefined; let packer: image.ImagePacker | undefined;
  try {
    const response = await request.request(url, { method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: 2097152,
      connectTimeout: 3000, readTimeout: 5000, usingCache: true });
    if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) || response.result.byteLength > 2097152) { throw new Error('应用图标下载未完成'); }
    source = image.createImageSource(response.result); const info = await source.getImageInfo();
    if (info.size.width < 1 || info.size.height < 1 || info.size.width > 4096 || info.size.height > 4096) { throw new Error('应用图标尺寸无效'); }
    const ratio = Math.min(1, 128 / Math.max(info.size.width, info.size.height));
    pixels = await source.createPixelMap({ desiredSize: { width: Math.max(1, Math.round(info.size.width * ratio)), height: Math.max(1, Math.round(info.size.height * ratio)) } });
    packer = image.createImagePacker(); const result = await packer.packToData(pixels, { format: 'image/png', quality: 100 });
    if (result.byteLength > 131072) { throw new Error('应用图标超过缓存上限'); } return result;
  } finally { request.destroy(); try { await packer?.release(); } catch (_) {} try { await pixels?.release(); } catch (_) {} try { await source?.release(); } catch (_) {} }
}
export class ApplicationIconRepository {
  private directory: string;
  private pending: Map<string, Promise<string>> = new Map();
  private attempts: Map<string, number> = new Map();
  private interests: Map<string, Array<() => boolean>> = new Map();
  private queue: ApplicationIconQueue = new ApplicationIconQueue();
  private generation: number = 0;
  constructor(cacheDirectory: string) { this.directory = cacheDirectory + '/application-icons'; }
  private cacheFiles(): string[] {
    try { return fs.listFileSync(this.directory).filter((name: string) => {
      const match = /^(.+)\.(?:png|json)(?:\.[a-fA-F0-9-]+\.next)?$/.exec(name);
      return !!match && validInstalledBundle(match[1]);
    }); } catch (_) { return []; }
  }
  stats(): ApplicationIconCacheStats {
    const result = new ApplicationIconCacheStats();
    this.cacheFiles().forEach((name: string) => { try { const stat = fs.statSync(this.directory + '/' + name); result.bytes += stat.size; if (name.endsWith('.png') && stat.size > 0) { result.icons++; } } catch (_) {} });
    return result;
  }
  clear(): ApplicationIconCacheStats {
    // Invalidate queued and in-flight generations before deleting files. A late
    // market response must not immediately recreate a cache the user cleared.
    this.generation++; this.attempts.clear(); this.interests.clear(); this.pending.clear();
    this.cacheFiles().forEach((name: string) => { try { fs.unlinkSync(this.directory + '/' + name); } catch (_) {} });
    return this.stats();
  }
  private path(bundle: string, suffix: string): string { return this.directory + '/' + bundle + suffix; }
  private receipt(bundle: string): IconReceipt {
    try { const path = this.path(bundle, '.json'); if (fs.statSync(path).size > 2048) { return new IconReceipt(); }
      const value = JSON.parse(fs.readTextSync(path)) as IconReceipt;
      return value.bundle === bundle && Number.isFinite(value.checkedAt) && Number.isFinite(value.retryAt) && typeof value.available === 'boolean' ? value : new IconReceipt();
    } catch (_) { return new IconReceipt(); }
  }
  cached(bundle: string): string {
    if (!validInstalledBundle(bundle)) { return ''; }
    try { const path = this.path(bundle, '.png'), size = fs.statSync(path).size; return size > 0 && size <= 131072 ? fileUri.getUriFromPath(path) : ''; } catch (_) { return ''; }
  }
  private write(path: string, data: string | ArrayBuffer): void {
    const temp = path + '.' + util.generateRandomUUID() + '.next';
    try { const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { const expected = typeof data === 'string' ? -1 : data.byteLength; const size = fs.writeSync(file.fd, data); if (expected >= 0 && size !== expected) { throw new Error('应用图标缓存写入失败'); } fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
      fs.renameSync(temp, path);
    } finally { try { if (fs.accessSync(temp)) { fs.unlinkSync(temp); } } catch (_) {} }
  }
  private trim(): void {
    const files = fs.listFileSync(this.directory).filter((name: string) => /\.(?:json|png)$/.test(name));
    if (files.length <= 1024) { return; }
    const records = files.filter((name: string) => name.endsWith('.json')).sort((a: string, b: string) => fs.statSync(this.directory + '/' + a).mtime - fs.statSync(this.directory + '/' + b).mtime);
    for (const name of records.slice(0, Math.max(1, records.length - 500))) {
      try { fs.unlinkSync(this.directory + '/' + name); } catch (_) {} try { fs.unlinkSync(this.directory + '/' + name.replace(/\.json$/, '.png')); } catch (_) {}
    }
  }
  load(bundle: string, wanted: () => boolean = () => true): Promise<string> {
    if (!validInstalledBundle(bundle)) { return Promise.resolve(''); }
    const existing = this.pending.get(bundle); if (existing) { this.interests.get(bundle)?.push(wanted); return existing; }
    const cached = this.cached(bundle), receipt = this.receipt(bundle), now = Date.now();
    if (now < (this.attempts.get(bundle) || 0) || now < receipt.retryAt) { return Promise.resolve(cached); }
    // Four workers bound traffic while stale/offscreen interests are skipped before any request.
    this.interests.set(bundle, [wanted]);
    const generation = this.generation;
    const task = this.queue.submit(async (): Promise<string> => {
      if (generation !== this.generation) { return ''; }
      if (!this.interests.get(bundle)?.some((interest: () => boolean) => interest())) { return cached; }
      let available = false, retryAt = Date.now() + 300000; this.attempts.set(bundle, retryAt);
      try {
        const result = await (async (): Promise<ArrayBuffer | undefined> => { const url = marketApplicationIcon(bundle, await getText(bundle)); return generation === this.generation && url ? await getThumbnail(url) : undefined; })();
        if (generation !== this.generation) { return ''; }
        if (!fs.accessSync(this.directory)) { fs.mkdirSync(this.directory, true); }
        if (result) { this.write(this.path(bundle, '.png'), result); available = true; }
        retryAt = Date.now() + (available ? 30 * DAY : DAY);
      } catch (_) { /* An unavailable catalogue entry never blocks the list. */ }
      if (generation !== this.generation) { return ''; }
      try { if (!fs.accessSync(this.directory)) { fs.mkdirSync(this.directory, true); } const value = new IconReceipt(); value.bundle = bundle; value.checkedAt = Date.now(); value.retryAt = retryAt; value.available = available || !!cached;
        this.write(this.path(bundle, '.json'), JSON.stringify(value)); this.trim(); } catch (_) {}
      this.attempts.set(bundle, retryAt); return this.cached(bundle);
    });
    this.pending.set(bundle, task);
    const settle = (): void => { if (this.pending.get(bundle) === task) { this.pending.delete(bundle); this.interests.delete(bundle); } };
    task.then(settle, settle); return task;
  }
}
const repositories: Map<string, ApplicationIconRepository> = new Map();
export function applicationIcons(cacheDirectory: string): ApplicationIconRepository {
  let value = repositories.get(cacheDirectory); if (!value) { value = new ApplicationIconRepository(cacheDirectory); repositories.set(cacheDirectory, value); } return value;
}
