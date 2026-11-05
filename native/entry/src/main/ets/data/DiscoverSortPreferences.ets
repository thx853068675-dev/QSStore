import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiscoverSort, DiscoverSortKey, SortDirection } from './DiscoverSort';

export class DiscoverSortSelection {
  key: DiscoverSortKey = 'stars';
  direction: SortDirection = 'desc';
}

export class DiscoverSortPreferences {
  private static layout: string = 'normal';
  private static selected: DiscoverSortKey = 'stars';
  private static directions: Map<string, SortDirection> = new Map();
  private static writes: Promise<void> = Promise.resolve();

  static currentLayout(): string { return DiscoverSortPreferences.layout; }
  static async saveLayout(context: common.UIAbilityContext, layout: string): Promise<void> {
    DiscoverSortPreferences.layout = layout === 'sidebar' ? 'sidebar' : 'normal';
    const value = DiscoverSortPreferences.layout;
    const write = DiscoverSortPreferences.writes.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'discover-sort');
      await store.put('layout', value);
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
      const savedKey = String(await store.get('selected', 'stars'));
      DiscoverSortPreferences.selected = DiscoverSort.key(savedKey);
      for (const key of ['stars', 'downloads', 'new']) {
        DiscoverSortPreferences.directions.set(key, DiscoverSort.direction(String(await store.get(key, 'desc'))));
      }
      if (savedKey === 'discover') {
        const direction = DiscoverSort.direction(String(await store.get('discover', 'desc')));
        await DiscoverSortPreferences.save(context, 'stars', direction);
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
