import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { CatalogApp } from './CatalogApp';

const STORE_NAME = 'catalog-cache';

/** 缓存里的一条图标记录。ArkTS 不接受匿名对象字面量，必须显式声明。 */
export class CachedIcon {
  id: string = '';
  data: string = '';
}
const KEY_CATALOG = 'catalog';
const KEY_ICONS = 'icons';

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
  /** 缓存最多保留多少个图标，避免 preferences 条目过大。 */
  private static readonly MAX_ICONS: number = 8;
  /** 单张图标的字节上限，超过就不缓存（不是真的图标）。 */
  private static readonly MAX_ICON_BYTES: number = 512 * 1024;

  private static async store(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, STORE_NAME);
  }

  static async load(context: common.UIAbilityContext): Promise<CatalogApp[]> {
    try {
      const store = await CatalogCache.store(context);
      const raw = await store.get(KEY_CATALOG, '') as string;
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
    rows: Array<Record<string, Object>>): Promise<void> {
    if (rows.length === 0) return;
    try {
      const store = await CatalogCache.store(context);
      await store.put(KEY_CATALOG, JSON.stringify(rows));
      await store.flush();
    } catch (_) {
      // 写缓存失败不影响本次展示
    }
  }

  /**
   * 缓存图标字节（base64）。只存前几个：列表首屏能立刻看到图标就够了，
   * 剩下的由后台刷新补齐。
   */
  static async saveIcons(context: common.UIAbilityContext,
    icons: CachedIcon[]): Promise<void> {
    if (icons.length === 0) return;
    try {
      const store = await CatalogCache.store(context);
      await store.put(KEY_ICONS, JSON.stringify(icons.slice(0, CatalogCache.MAX_ICONS)));
      await store.flush();
    } catch (_) {
      // 同上
    }
  }

  static async loadIcons(context: common.UIAbilityContext): Promise<Map<number, ArrayBuffer>> {
    const out = new Map<number, ArrayBuffer>();
    try {
      const store = await CatalogCache.store(context);
      const raw = await store.get(KEY_ICONS, '') as string;
      if (raw.length === 0) return out;
      const parsed = JSON.parse(raw) as Array<Record<string, Object>>;
      for (const row of parsed) {
        const id = Number(row['id'] ?? 0);
        const base64 = String(row['data'] ?? '');
        if (id <= 0 || base64.length === 0) continue;
        const bytes = new util.Base64Helper().decodeSync(base64);
        out.set(id, bytes.buffer.slice(bytes.byteOffset,
          bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
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
