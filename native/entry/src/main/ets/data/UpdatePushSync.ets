import { FollowingRegistry } from './FollowingRegistry';
import { UpdatePolicy } from './UpdatePolicy';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { CatalogApp } from './CatalogApp';
import { AccountSession, DeveloperAccount } from './DeveloperAccount';
import { StoreClient, UpdatePushWatchItem } from './StoreClient';
import { InstalledAppRegistry } from '../jobs/InstalledAppRegistry';
import { JobStore } from '../jobs/JobStore';
import { PrivacyConsent } from './PrivacyConsent';
import { I18n } from './I18n';

/** Only confirmed local installations are sent. Historical jobs provide app IDs without a catalog request. */
export class UpdatePushSync {
  private static readonly STORE: string = 'update-push';
  private static readonly DAILY_MS: number = 24 * 60 * 60 * 1000;
  private static catalog: Map<string, number> = new Map();
  private static tail: Promise<void> = Promise.resolve();
  private static timer: number = -1;
  private static restoreAt:Map<string,number>=new Map();

  static observeCatalog(apps: CatalogApp[]): void {
    for (const app of apps) {
      if (!Number.isSafeInteger(app.id) || app.id <= 0) continue;
      for (const asset of app.latestAssets) {
        if (asset.bundleName.length > 0) UpdatePushSync.catalog.set(app.id + ':' + asset.bundleName, app.id);
      }
      if (app.latestAsset && app.latestAsset.bundleName.length > 0) {
        UpdatePushSync.catalog.set(app.id + ':' + app.latestAsset.bundleName, app.id);
      }
    }
    while (UpdatePushSync.catalog.size > 500) {
      UpdatePushSync.catalog.delete(Array.from(UpdatePushSync.catalog.keys())[0]);
    }
  }

  static async clientId(context: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(context, UpdatePushSync.STORE);
    const saved = String(await store.get('clientId', ''));
    if (/^[0-9a-f]{32}$/.test(saved)) return saved;
    const id = util.generateRandomUUID().replace(/-/g, '').toLowerCase();
    await store.put('clientId', id);
    await store.flush();
    return id;
  }

  static async setConfigured(context: common.UIAbilityContext,
    account: DeveloperAccount, configured: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, UpdatePushSync.STORE);
    const previousAccount = String(await store.get('accountId', ''));
    const previousConfigured = await store.get('configured', false) === true;
    await store.put('accountId', account.userId);
    await store.put('configured', configured);
    if (previousAccount !== account.userId || previousConfigured !== configured) {
      await store.put('snapshot', '');
      await store.put('sentAt', 0);
      await store.put('linksRegistered',false);
    }
    await store.flush();
  }

  static schedule(context: common.UIAbilityContext): void {
    if (UpdatePushSync.timer !== -1) clearTimeout(UpdatePushSync.timer);
    UpdatePushSync.timer = setTimeout(() => {
      UpdatePushSync.timer = -1;
      UpdatePushSync.syncBestEffort(context);
    }, 2500);
  }

  static async syncBestEffort(context: common.UIAbilityContext): Promise<void> {
    try { await UpdatePushSync.sync(context); } catch (_) {
      // Foreground resume, settings and the next inventory change retry without a polling loop.
    }
  }

  static sync(context: common.UIAbilityContext, force: boolean = false): Promise<void> {
    const next = UpdatePushSync.tail.then(() => UpdatePushSync.syncOnce(context, force));
    UpdatePushSync.tail = next.catch(() => {});
    return next;
  }

  private static async items(context: common.UIAbilityContext,
    previous: string): Promise<UpdatePushWatchItem[]> {
    await InstalledAppRegistry.load(context);
    const ids = new Map<string, number>(UpdatePushSync.catalog);
    const old = new Map<string, UpdatePushWatchItem>();
    try {
      const saved = JSON.parse(previous) as UpdatePushWatchItem[];
      if (Array.isArray(saved)) {
        for (const item of saved) {
          if (item.app_id > 0 && item.bundle_name.length > 0 && item.version_code > 0) {
            const key = item.app_id + ':' + item.bundle_name;
            old.set(key, item); ids.set(key, item.app_id);
          }
        }
      }
    } catch (_) {}
    const jobs = await (await JobStore.open(context)).listAll();
    for (const job of jobs) {
      if (job.appId > 0 && job.bundleName.length > 0) ids.set(job.appId + ':' + job.bundleName, job.appId);
    }
    const result: UpdatePushWatchItem[] = [];
    for (const key of ids.keys()) {
      const separator = key.indexOf(':');
      const bundle = key.substring(separator + 1);
      if(UpdatePolicy.disabled(bundle))continue;
      const version = InstalledAppRegistry.version(bundle);
      if (version < 0) {
        const last = old.get(key);
        if (last) result.push(last);
        continue;
      }
      if (version === 0) continue;
      const item = new UpdatePushWatchItem();
      item.app_id = ids.get(key) ?? 0;
      item.bundle_name = bundle;
      item.version_code = version;
      result.push(item);
    }
    result.sort((a: UpdatePushWatchItem, b: UpdatePushWatchItem) =>
      a.app_id - b.app_id || a.bundle_name.localeCompare(b.bundle_name));
    if (result.length > 200) throw new Error(I18n.t('已安装的商店应用超过 200 个，请稍后重试'));
    return result;
  }

  private static async syncOnce(context: common.UIAbilityContext, force: boolean): Promise<void> {
    if (!PrivacyConsent.isBusinessAllowed()) return;
    const account = await AccountSession.load(context);
    if (!account) return;
    await UpdatePolicy.restore(context);
    try{await FollowingRegistry.sync(context);}catch(_){ /* Keep independent inventory notifications working during rollout. */ }
    const store = await preferences.getPreferences(context, UpdatePushSync.STORE);
    if(String(await store.get('accountId',''))!==account.userId||await store.get('configured',false)!==true){
      if(!force&&Date.now()-(UpdatePushSync.restoreAt.get(account.userId)??0)<60000)return;
      UpdatePushSync.restoreAt.set(account.userId,Date.now());
      while(UpdatePushSync.restoreAt.size>20)UpdatePushSync.restoreAt.delete(Array.from(UpdatePushSync.restoreAt.keys())[0]);
      const cloud=await new StoreClient(context).updatePushState(account,await UpdatePushSync.clientId(context));
      if(!PrivacyConsent.isBusinessAllowed()||(await AccountSession.load(context))?.userId!==account.userId)return;
      await UpdatePushSync.setConfigured(context,account,cloud['configured']===true);
      if(cloud['configured']!==true)return;
    }
    const previous = String(await store.get('snapshot', ''));
    const items = await UpdatePushSync.items(context, previous);
    const snapshot = JSON.stringify(items);
    const sentAt = Number(await store.get('sentAt', 0));
    if (!force && snapshot === previous && Date.now() - sentAt < UpdatePushSync.DAILY_MS && await store.get('linksRegistered',false)===true) return;
    const clientId = await UpdatePushSync.clientId(context);
    if(!PrivacyConsent.isBusinessAllowed()||(await AccountSession.load(context))?.userId!==account.userId)return;
    await new StoreClient(context).updatePushWatchlist(account, clientId, items);
    await store.put('snapshot', snapshot);
    await store.put('sentAt', Date.now());
    await store.put('linksRegistered',true);
    await store.flush();
  }
}
