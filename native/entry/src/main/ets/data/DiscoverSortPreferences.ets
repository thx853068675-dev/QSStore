import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiscoverSort, DiscoverSortKey, SortDirection } from './DiscoverSort';

export class DiscoverSortSelection {
  key: DiscoverSortKey = 'discover';
  direction: SortDirection = 'desc';
}

export class DiscoverSortPreferences {
  private static selected: DiscoverSortKey = 'discover';
  private static directions: Map<string, SortDirection> = new Map();
  private static writes: Promise<void> = Promise.resolve();

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
      DiscoverSortPreferences.selected = DiscoverSort.key(String(await store.get('selected', 'discover')));
      for (const key of ['discover', 'stars', 'downloads', 'new']) {
        DiscoverSortPreferences.directions.set(key, DiscoverSort.direction(String(await store.get(key, 'desc'))));
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
