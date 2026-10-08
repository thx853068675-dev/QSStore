import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { CatalogApp } from './CatalogApp';
import { DiscoverSort } from './DiscoverSort';

const STORE_NAME = 'catalog-cache';

/** 缓存里的一条图标记录。ArkTS 不接受匿名对象字面量，必须显式声明。 */
export class CachedIcon {
  id: string = '';
  rev: string = '';
  data: string = '';
}
const KEY_CATALOG = 'catalog';
const KEY_ICONS = 'icons';
const ICON_PREFIX = 'icon-';

/**
 * 目录快照缓存。
 *
 * 之前每次冷启动都要等一轮网络才能显示任何内容：先请求列表，再逐个请求图标。
 * 服务端往返实测约 1 秒，图标更慢，于是打开应用先看到一片空白。
 *
 * 现在把上一次的列表原样存下来，启动时先画出来，再去后端刷新。刷新拿到新数据
 * 就替换并覆盖缓存；网络不可用时至少还能浏览上次看到的内容。
 *
 * 只缓存第一页。「服务端最新状态」与分页混在一起会得到半新半旧的列表，所以
 * 追加页不写缓存，缓存永远等于「某一次干净的第一页」。
 */
export class CatalogCache {
  /** 单张图标的字节上限，超过就不缓存（不是真的图标）。 */
  private static readonly MAX_ICON_BYTES: number = 512 * 1024;

  private static async store(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, STORE_NAME);
  }

  /** 图标和目录实际保存的缓存数据；不计入 Preferences 容器本身的固定开销。 */
  static async size(context: common.UIAbilityContext): Promise<number> {
    try {
      const store = await CatalogCache.store(context);
      const values = await store.getAll() as Record<string, Object>;
      const encoder = new util.TextEncoder();
      let bytes = 0;
      for (const key of Object.keys(values)) {
        if (key !== KEY_CATALOG && key !== KEY_ICONS && !/^icon-[1-9][0-9]*$/.test(key) &&
          !/^catalog-(discover|stars|downloads|new)-(asc|desc)$/.test(key)) continue;
        if (typeof values[key] === 'string') bytes += encoder.encodeInto(values[key] as string).byteLength;
      }
      return bytes;
    } catch (_) { return 0; }
  }

  static async clear(context: common.UIAbilityContext): Promise<void> {
    const store = await CatalogCache.store(context);
    await store.clear();
    await store.flush();
  }

  static async load(context: common.UIAbilityContext, sort: string = 'discover', direction: string = 'desc'): Promise<CatalogApp[]> {
    try {
      const store = await CatalogCache.store(context);
      const key = KEY_CATALOG + '-' + DiscoverSort.cacheKey(sort, direction);
      let raw = await store.get(key, '') as string;
      if (raw.length === 0 && sort === 'discover' && direction === 'desc') raw = await store.get(KEY_CATALOG, '') as string;
      if (raw.length === 0 || raw.length > 1024 * 1024) return [];
      const parsed = JSON.parse(raw) as Array<Record<string, Object>>;
      if (!Array.isArray(parsed)) return [];
      return parsed.map((row: Record<string, Object>) => CatalogApp.fromJson(row));
    } catch (_) {
      // 缓存坏了就当没有：重新请求即可，不该影响启动
      return [];
    }
  }

  static async save(context: common.UIAbilityContext, apps: CatalogApp[],
    rows: Array<Record<string, Object>>, sort: string = 'discover', direction: string = 'desc'): Promise<void> {
    try {
      const store = await CatalogCache.store(context);
      // Four modes × two directions, one first page each; never mix sort scopes.
      await store.put(KEY_CATALOG + '-' + DiscoverSort.cacheKey(sort, direction), JSON.stringify(rows));
      await store.delete(KEY_CATALOG);
      await store.flush();
    } catch (_) {
      // 写缓存失败不影响本次展示
    }
  }

  /** 每个应用单独存一条，避免整页图标挤进 preferences 的单个值。 */
  static async saveIcons(context: common.UIAbilityContext,
    icons: CachedIcon[]): Promise<void> {
    if (icons.length === 0) return;
    try {
      const store = await CatalogCache.store(context);
      for (const icon of icons) {
        const id = Number(icon.id);
        if (!Number.isInteger(id) || id <= 0 || icon.rev.length === 0 ||
          icon.data.length === 0 || icon.data.length > 700 * 1024) continue;
        await store.put(ICON_PREFIX + id, JSON.stringify(icon));
      }
      await store.flush();
    } catch (_) {
      // 同上
    }
  }

  static async loadIcons(context: common.UIAbilityContext,
    apps: CatalogApp[]): Promise<Map<number, ArrayBuffer>> {
    const out = new Map<number, ArrayBuffer>();
    try {
      const store = await CatalogCache.store(context);
      // Read the old combined cache once for upgrades from earlier versions.
      const legacyRaw = await store.get(KEY_ICONS, '') as string;
      let legacy: Array<Record<string, Object>> = [];
      try {
        if (legacyRaw.length > 0) legacy = JSON.parse(legacyRaw) as Array<Record<string, Object>>;
      } catch (_) {}
      for (const app of apps) {
        try {
          const raw = await store.get(ICON_PREFIX + app.id, '') as string;
          const row = raw.length > 0 ? JSON.parse(raw) as Record<string, Object> :
            legacy.find((item: Record<string, Object>) => Number(item['id'] ?? 0) === app.id);
          if (row === undefined) continue;
          const id = Number(row['id'] ?? 0);
          const rev = String(row['rev'] ?? '');
          const base64 = String(row['data'] ?? '');
          if (id <= 0 || rev.length === 0 || base64.length === 0 ||
            app.id !== id || app.iconRev !== rev) continue;
          const bytes = new util.Base64Helper().decodeSync(base64);
          out.set(id, bytes.buffer.slice(bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
        } catch (_) {
          // A broken icon record must not hide the rest of the catalog.
        }
      }
    } catch (_) {
      // 图标缓存坏了就当没有
    }
    return out;
  }

  /** 单个图标是否值得缓存。 */
  static iconWithinLimit(bytes: ArrayBuffer): boolean {
    return bytes.byteLength > 0 && bytes.byteLength <= CatalogCache.MAX_ICON_BYTES;
  }
}
