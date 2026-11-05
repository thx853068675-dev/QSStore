import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { I18n } from './I18n';

/** A device-local update opt-out belongs to a bundle, never to a repository or account. */
export class UpdatePolicy {
  private static scopes: Map<string, Set<string>> = new Map();
  private static activeScope: string = '';
  private static tail: Promise<void> = Promise.resolve();

  private static validBundle(bundleName: string): boolean {
    return bundleName.length <= 128 && /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundleName);
  }

  private static enqueue(operation: () => Promise<void>): Promise<void> {
    const work = UpdatePolicy.tail.then(operation);
    UpdatePolicy.tail = work.then(() => {}, () => {});
    return work;
  }

  private static notify(): void {
    AppStorage.setOrCreate<number>('updatePolicyRevision', (AppStorage.get<number>('updatePolicyRevision') ?? 0) + 1);
  }

  private static activate(scope: string): void {
    if (UpdatePolicy.activeScope === scope) return;
    UpdatePolicy.activeScope = scope;
    UpdatePolicy.notify();
  }

  private static async saved(context: common.UIAbilityContext): Promise<Set<string>> {
    const existing = UpdatePolicy.scopes.get(context.filesDir);
    if (existing !== undefined) return existing;
    const store = await preferences.getPreferences(context, 'qingqi-update-policy');
    const raw = await store.getAll() as Record<string, Object>;
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('停更设置读取失败，请重试');
    const values = new Set<string>();
    for (const key of Object.keys(raw)) {
      if (!key.startsWith('bundle.')) continue;
      const bundleName = key.substring(7);
      if (raw[key] === true && UpdatePolicy.validBundle(bundleName)) values.add(bundleName);
    }
    // A failed read never becomes a loaded empty scope that could erase saved rules.
    UpdatePolicy.scopes.set(context.filesDir, values);
    return values;
  }

  static restore(context: common.UIAbilityContext): Promise<void> {
    return UpdatePolicy.enqueue(async (): Promise<void> => {
      await UpdatePolicy.saved(context);
      UpdatePolicy.activate(context.filesDir);
    });
  }

  static disabled(bundleName: string,deviceKey:string='local'): boolean {
    const key=deviceKey==='local'?bundleName:deviceKey+':'+bundleName;
    return UpdatePolicy.validBundle(bundleName) &&
      (UpdatePolicy.scopes.get(UpdatePolicy.activeScope)?.has(key) ?? false);
  }

  static async setDisabled(context: common.UIAbilityContext, bundleName: string, disabled: boolean): Promise<void> {
    if (!UpdatePolicy.validBundle(bundleName)) throw new Error(I18n.t('应用包名无效'));
    const next = disabled === true;
    await UpdatePolicy.enqueue(async (): Promise<void> => {
      const previous = await UpdatePolicy.saved(context);
      if (previous.has(bundleName) === next) {
        UpdatePolicy.activate(context.filesDir);
        return;
      }
      const store = await preferences.getPreferences(context, 'qingqi-update-policy');
      const key = 'bundle.' + bundleName;
      const previousValue = await store.get(key, false);
      try {
        await store.put(key, next);
        await store.flush();
      } catch (error) {
        // Preferences also exposes pending memory writes; restore those before
        // a later successful save can accidentally flush a rejected choice.
        try { await store.put(key, previousValue); await store.flush(); } catch (_) {}
        throw error as Error;
      }
      const values = new Set<string>(previous);
      if (next) values.add(bundleName); else values.delete(bundleName);
      UpdatePolicy.scopes.set(context.filesDir, values);
      UpdatePolicy.activeScope = context.filesDir;
      UpdatePolicy.notify();
    });
  }
}
