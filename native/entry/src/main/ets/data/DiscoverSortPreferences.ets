import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiscoverSort, DiscoverSortKey, SortDirection } from './DiscoverSort';

export class DiscoverSortSelection {
  key: DiscoverSortKey = 'stars';
  direction: SortDirection = 'desc';
}

export class DiscoverSortPreferences {
  private static layout: string = 'normal';
  private static toolbarRows: number = 1;
  private static selected: DiscoverSortKey = 'stars';
  private static directions: Map<string, SortDirection> = new Map();
  private static categoryOrder: string[] = [];
  private static writes: Promise<void> = Promise.resolve();

  static currentToolbarRows(): number { return DiscoverSortPreferences.toolbarRows; }
  static saveToolbarRows(context: common.UIAbilityContext, rows: number): Promise<void> {
    DiscoverSortPreferences.toolbarRows = rows === 2 ? 2 : 1;
    return DiscoverSortPreferences.saveDisplayOption(context, 'toolbarRows', DiscoverSortPreferences.toolbarRows);
  }
  static currentLayout(): string { return DiscoverSortPreferences.layout; }
  static saveLayout(context: common.UIAbilityContext, layout: string): Promise<void> {
    DiscoverSortPreferences.layout = layout === 'sidebar' ? 'sidebar' : 'normal';
    return DiscoverSortPreferences.saveDisplayOption(context, 'layout', DiscoverSortPreferences.layout);
  }

  static orderedCategories(categories: string[]): string[] {
    const available = new Set(categories);
    const ordered = DiscoverSortPreferences.categoryOrder.filter((category: string) => available.delete(category));
    return ordered.concat(Array.from(available));
  }

  static async saveCategoryOrder(context: common.UIAbilityContext, order: string[]): Promise<void> {
    const next = Array.from(new Set(order));
    await DiscoverSortPreferences.saveDisplayOption(context, 'categoryOrder', JSON.stringify(next));
    DiscoverSortPreferences.categoryOrder = next;
  }

  private static saveDisplayOption(context: common.UIAbilityContext, key: string, value: string | number): Promise<void> {
    const write = DiscoverSortPreferences.writes.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'discover-sort');
      await store.put(key, value);
      await store.flush();
    });
    DiscoverSortPreferences.writes = write.catch(() => {});
    return write;
  }
  static current(): DiscoverSortSelection {
    const selection = new DiscoverSortSelection();
    selection.key = DiscoverSortPreferences.selected;
    selection.direction = DiscoverSortPreferences.directionFor(selection.key);
    return selection;
  }
  static directionFor(key: string): SortDirection {
    return DiscoverSortPreferences.directions.get(key) ?? 'desc';
  }
  static async load(context: common.UIAbilityContext): Promise<void> {
    try {
      await DiscoverSortPreferences.writes;
      const store = await preferences.getPreferences(context, 'discover-sort');
      DiscoverSortPreferences.layout = String(await store.get('layout', 'normal')) === 'sidebar' ? 'sidebar' : 'normal';
      DiscoverSortPreferences.toolbarRows = Number(await store.get('toolbarRows', 1)) === 2 ? 2 : 1;
      const savedKey = String(await store.get('selected', 'stars'));
      DiscoverSortPreferences.selected = DiscoverSort.key(savedKey);
      for (const key of ['stars', 'downloads', 'new']) {
        DiscoverSortPreferences.directions.set(key, DiscoverSort.direction(String(await store.get(key, 'desc'))));
      }
      if (savedKey === 'discover') {
        const direction = DiscoverSort.direction(String(await store.get('discover', 'desc')));
        await DiscoverSortPreferences.save(context, 'stars', direction);
      }
      const order: string[] = JSON.parse(String(await store.get('categoryOrder', '[]')));
      if (Array.isArray(order)) {
        DiscoverSortPreferences.categoryOrder = order.filter(
          (category: string) => typeof category === 'string' && category.length > 0);
      }
    } catch (_) { /* Keep the in-memory choice if storage is temporarily unavailable. */ }
  }
  static save(context: common.UIAbilityContext, key: DiscoverSortKey, direction: SortDirection): Promise<void> {
    DiscoverSortPreferences.selected = key;
    DiscoverSortPreferences.directions.set(key, direction);
    const write = DiscoverSortPreferences.writes.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'discover-sort');
      await store.put('selected', key);
      await store.put(key, direction);
      await store.flush();
    });
    DiscoverSortPreferences.writes = write.catch(() => {});
    return write;
  }
}
