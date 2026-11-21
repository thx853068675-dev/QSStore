import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class StartupNotice {
  versionCode: number = 0;
  versionName: string = '';
}

/** Informational acknowledgement, separate from privacy consent and account authorization. */
export class StartupReleaseNotice {
  private static versionFlight: Promise<bundleManager.BundleInfo> | undefined;
  private static acknowledged: Map<string, number> = new Map();
  private static reads: Map<string, Promise<number>> = new Map();
  private static writes: Map<string, Promise<void>> = new Map();

  private static read(context: common.UIAbilityContext): Promise<number> {
    const scope = context.filesDir;
    const known = StartupReleaseNotice.acknowledged.get(scope);
    if (known !== undefined) return Promise.resolve(known);
    const pending = StartupReleaseNotice.reads.get(scope);
    if (pending !== undefined) return pending;
    const flight = (async (): Promise<number> => {
      let code = 0;
      try {
        const store = await preferences.getPreferences(context, 'startup-release-notice');
        const saved = Number(await store.get('acknowledgedBuild', 0));
        if (Number.isSafeInteger(saved) && saved > 0) code = saved;
      } catch (_) { /* The notice remains dismissible when preferences are unavailable. */ }
      const newest = Math.max(code, StartupReleaseNotice.acknowledged.get(scope) ?? 0);
      StartupReleaseNotice.acknowledged.set(scope, newest);
      return newest;
    })();
    StartupReleaseNotice.reads.set(scope, flight);
    return flight;
  }

  static async pending(context: common.UIAbilityContext): Promise<StartupNotice | undefined> {
    try {
      if (StartupReleaseNotice.versionFlight === undefined) {
        StartupReleaseNotice.versionFlight = bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      }
      const info = await StartupReleaseNotice.versionFlight;
      if (!Number.isSafeInteger(info.versionCode) || info.versionCode <= 0) return undefined;
      if (await StartupReleaseNotice.read(context) >= info.versionCode) return undefined;
      const notice = new StartupNotice();
      notice.versionCode = info.versionCode;
      notice.versionName = String(info.versionName ?? '').trim();
      return notice;
    } catch (_) {
      StartupReleaseNotice.versionFlight = undefined;
      return undefined; // An information notice must never prevent startup.
    }
  }

  static async acknowledge(context: common.UIAbilityContext, notice: StartupNotice): Promise<void> {
    if (!Number.isSafeInteger(notice.versionCode) || notice.versionCode <= 0) return;
    const scope = context.filesDir;
    const previous = Math.max(await StartupReleaseNotice.read(context),
      StartupReleaseNotice.acknowledged.get(scope) ?? 0);
    if (previous >= notice.versionCode) return;
    // Remember within this process even if a disk write fails. Retry on the next launch.
    StartupReleaseNotice.acknowledged.set(scope, notice.versionCode);
    const tail = StartupReleaseNotice.writes.get(scope) ?? Promise.resolve();
    const write = tail.catch(() => {}).then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'startup-release-notice');
      await store.put('acknowledgedBuild', StartupReleaseNotice.acknowledged.get(scope) ?? notice.versionCode);
      await store.flush();
    });
    StartupReleaseNotice.writes.set(scope, write);
    await write;
  }
}
