import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { PackageIdentity } from './PackageInspector';

export class EditedPackageOrigin {
  sha256: string = '';
  assetName: string = '';
}

/** Local proof of a presentation edit; no package or signing material is retained. */
export class EditedPackageProvenance {
  private static tails: Map<string, Promise<void>> = new Map();

  private static digest(value: string): string {
    return /^[0-9a-fA-F]{64}$/.test(value) ? value.toLowerCase() : '';
  }

  private static original(value: string, identity: PackageIdentity): EditedPackageOrigin {
    const origin = new EditedPackageOrigin();
    try {
      const proof = JSON.parse(value) as Record<string, Object>;
      if (proof === null || Array.isArray(proof) ||
        proof['bundle'] !== identity.bundleName || proof['code'] !== identity.versionCode ||
        proof['version'] !== identity.versionName || typeof proof['source'] !== 'string' ||
        typeof proof['asset'] !== 'string' || !proof['asset'] || /[\x00-\x1f]/.test(proof['asset'] as string)) return origin;
      origin.sha256 = EditedPackageProvenance.digest(proof['source'] as string);
      if (origin.sha256) origin.assetName = proof['asset'] as string;
    } catch (_) {}
    return origin;
  }

  private static enqueue(context: common.UIAbilityContext,
    operation: () => Promise<EditedPackageOrigin>): Promise<EditedPackageOrigin> {
    const scope = context.filesDir;
    const previous = EditedPackageProvenance.tails.get(scope) ?? Promise.resolve();
    const work = previous.then(operation);
    const tail = work.then(() => {}, () => {});
    EditedPackageProvenance.tails.set(scope, tail);
    tail.then(() => {
      if (EditedPackageProvenance.tails.get(scope) === tail) EditedPackageProvenance.tails.delete(scope);
    });
    return work;
  }

  /** A marker inside an imported package is never evidence; only our local ledger is read. */
  static source(context: common.UIAbilityContext, sha256: string,
    identity: PackageIdentity): Promise<EditedPackageOrigin> {
    const key = EditedPackageProvenance.digest(sha256);
    if (!key) return Promise.resolve(new EditedPackageOrigin());
    return EditedPackageProvenance.enqueue(context, async (): Promise<EditedPackageOrigin> => {
      try {
        const store = await preferences.getPreferences(context, 'qingqi-package-edits');
        return EditedPackageProvenance.original(String(await store.get(key, '')), identity);
      } catch (_) { return new EditedPackageOrigin(); }
    });
  }

  /** Called only after the editor has verified that bundle and both version fields are unchanged. */
  static async record(context: common.UIAbilityContext, sourceSha256: string,
    editedSha256: string, identity: PackageIdentity, assetName: string): Promise<void> {
    const source = EditedPackageProvenance.digest(sourceSha256);
    const output = EditedPackageProvenance.digest(editedSha256);
    if (!source || !output || !identity.bundleName || !Number.isSafeInteger(identity.versionCode) ||
      identity.versionCode <= 0 || !assetName || /[\x00-\x1f]/.test(assetName)) throw new Error('编辑来源校验失败');
    await EditedPackageProvenance.enqueue(context, async (): Promise<EditedPackageOrigin> => {
      const store = await preferences.getPreferences(context, 'qingqi-package-edits');
      const previous = String(await store.get(output, ''));
      const root = EditedPackageProvenance.original(String(await store.get(source, '')), identity);
      if (!root.sha256) { root.sha256 = source; root.assetName = assetName; }
      const payload: Record<string, Object> = { 'source': root.sha256, 'asset': root.assetName,
        'bundle': identity.bundleName, 'code': identity.versionCode, 'version': identity.versionName };
      const value = JSON.stringify(payload);
      try {
        await store.put(output, value);
        await store.flush();
      } catch (error) {
        // Do not let an unflushed Preferences write be adopted by a later import.
        try {
          if (previous) await store.put(output, previous);
          else await store.delete(output);
          await store.flush();
        } catch (_) {}
        throw error as Error;
      }
      return root;
    });
  }
}
