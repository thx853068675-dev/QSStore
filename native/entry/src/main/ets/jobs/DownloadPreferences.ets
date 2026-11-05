import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

class DownloadPreferenceSetting {
  enabled: boolean = false;
  since: number = 0;
}

/** Original downloads are kept unless the user explicitly enables successful-install cleanup. */
export class DownloadPreferences {
  private static values: Map<string, DownloadPreferenceSetting> = new Map();
  private static tails: Map<string, Promise<void>> = new Map();

  private static enqueue(context: common.UIAbilityContext,
    operation: () => Promise<DownloadPreferenceSetting>): Promise<DownloadPreferenceSetting> {
    const scope = context.filesDir;
    const previous = DownloadPreferences.tails.get(scope) ?? Promise.resolve();
    const work = previous.then(operation);
    const tail = work.then(() => {}, () => {});
    DownloadPreferences.tails.set(scope, tail);
    tail.then(() => {
      if (DownloadPreferences.tails.get(scope) === tail) DownloadPreferences.tails.delete(scope);
    });
    return work;
  }

  private static validSince(value: preferences.ValueType): number {
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
  }

  private static read(context: common.UIAbilityContext): Promise<DownloadPreferenceSetting> {
    return DownloadPreferences.enqueue(context, async (): Promise<DownloadPreferenceSetting> => {
      const cached = DownloadPreferences.values.get(context.filesDir);
      if (cached !== undefined) return cached;
      try {
        const store = await preferences.getPreferences(context, 'qingqi-download-settings');
        const value = new DownloadPreferenceSetting();
        value.enabled = (await store.get('autoCleanAfterInstall', false)) === true;
        value.since = value.enabled ? DownloadPreferences.validSince(await store.get('autoCleanEnabledSince', 0)) : 0;
        DownloadPreferences.values.set(context.filesDir, value);
        return value;
      } catch (_) {
        // Storage failures keep packages and can be retried; they do not enable cleanup.
        return new DownloadPreferenceSetting();
      }
    });
  }

  static load(context: common.UIAbilityContext): Promise<boolean> {
    return DownloadPreferences.read(context).then((value: DownloadPreferenceSetting) => value.enabled);
  }

  /** Zero means no trustworthy current opt-in boundary, so historical packages must be kept. */
  static enabledSince(context: common.UIAbilityContext): Promise<number> {
    return DownloadPreferences.read(context).then((value: DownloadPreferenceSetting) => value.enabled ? value.since : 0);
  }

  static async save(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    const next = enabled === true;
    await DownloadPreferences.enqueue(context, async (): Promise<DownloadPreferenceSetting> => {
      const store = await preferences.getPreferences(context, 'qingqi-download-settings');
      const previous = await store.get('autoCleanAfterInstall', false);
      const previousSince = await store.get('autoCleanEnabledSince', 0);
      const value = new DownloadPreferenceSetting();
      value.enabled = next;
      value.since = next ? (previous === true ? DownloadPreferences.validSince(previousSince) : Date.now()) : 0;
      try {
        await store.put('autoCleanAfterInstall', next);
        await store.put('autoCleanEnabledSince', value.since);
        await store.flush();
      } catch (error) {
        // Preferences keeps pending writes in memory. Restore a failed draft so
        // an unrelated future flush cannot silently turn on package deletion.
        try {
          await store.put('autoCleanAfterInstall', previous);
          await store.put('autoCleanEnabledSince', previousSince);
          await store.flush();
        } catch (_) {}
        const restored = new DownloadPreferenceSetting();
        restored.enabled = previous === true;
        restored.since = restored.enabled ? DownloadPreferences.validSince(previousSince) : 0;
        DownloadPreferences.values.set(context.filesDir, restored);
        throw error as Error;
      }
      DownloadPreferences.values.set(context.filesDir, value);
      return value;
    });
  }
}
