import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** Local layout preferences, independent of the developer account and catalog cache. */
export class ManagementPreferences {
  private static writes: Promise<void> = Promise.resolve();

  static async load(context: common.UIAbilityContext): Promise<void> {
    let published: boolean = false;
    let installed: boolean = false;
    try {
      await ManagementPreferences.writes;
      const store = await preferences.getPreferences(context, 'management-layout');
      published = (await store.get('publishedCollapsed', false)) === true;
      installed = (await store.get('installedCollapsed', false)) === true;
    } catch (_) { /* Unavailable preferences retain the default expanded layout. */ }
    AppStorage.setOrCreate<boolean>('managementPublishedCollapsed', published);
    AppStorage.setOrCreate<boolean>('managementInstalledCollapsed', installed);
  }

  static save(context: common.UIAbilityContext, published: boolean, collapsed: boolean): Promise<void> {
    const write = ManagementPreferences.writes.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'management-layout');
      await store.put(published ? 'publishedCollapsed' : 'installedCollapsed', collapsed);
      await store.flush();
    });
    // Rapid toggles keep their order; a failed write must not block subsequent saves.
    ManagementPreferences.writes = write.catch(() => {});
    return write;
  }
}
