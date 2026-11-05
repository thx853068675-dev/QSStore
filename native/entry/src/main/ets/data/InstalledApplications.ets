import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HdcDeviceBridge } from '../jobs/HdcDeviceBridge';
import { InstalledAppRegistry, InstalledDeviceApp } from '../jobs/InstalledAppRegistry';

class InstalledLabel { bundleName: string = ''; label: string = ''; }
export class InstalledApplications {
  static parse(source: string): InstalledLabel[] {
    if (source.length > 1048576 || source.indexOf('[') < 0) throw new Error('无法读取已安装应用目录');
    const rows = JSON.parse(source.substring(source.indexOf('['))) as InstalledLabel[];
    if (!Array.isArray(rows) || rows.length > 3000) throw new Error('应用目录无效');
    const seen = new Set<string>();
    return rows.filter((row: InstalledLabel): boolean => {
      if (!row || typeof row.bundleName !== 'string' || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(row.bundleName) ||
        typeof row.label !== 'string' || row.label.length > 160 || seen.has(row.bundleName)) return false;
      seen.add(row.bundleName); return true;
    });
  }
  static async cached(context: common.UIAbilityContext): Promise<InstalledDeviceApp[]> {
    await InstalledAppRegistry.load(context);
    const store = await preferences.getPreferences(context, 'installed-app-list');
    let labels: InstalledLabel[] = [];
    try { labels = InstalledApplications.parse(String(await store.get('labels', '[]'))); } catch (_) {}
    if (labels.length === 0) labels = InstalledAppRegistry.sideloadedApps().map((item: InstalledDeviceApp): InstalledLabel => {
      const row = new InstalledLabel(); row.bundleName = item.bundleName; row.label = item.displayName; return row;
    });
    return InstalledApplications.merge(labels);
  }
  static merge(labels: InstalledLabel[]): InstalledDeviceApp[] {
    const cached = new Map<string, InstalledDeviceApp>();
    InstalledAppRegistry.sideloadedApps().forEach((item: InstalledDeviceApp) => cached.set(item.bundleName, item));
    return labels.map((item: InstalledLabel): InstalledDeviceApp => {
      const row = cached.get(item.bundleName) ?? new InstalledDeviceApp();
      row.bundleName = item.bundleName;
      row.displayName = item.label.trim() || row.displayName || item.bundleName;
      return row;
    }).sort((a: InstalledDeviceApp, b: InstalledDeviceApp): number => a.displayName.localeCompare(b.displayName));
  }
  static async refresh(context: common.UIAbilityContext): Promise<InstalledDeviceApp[]> {
    await InstalledAppRegistry.load(context);
    const source = await new HdcDeviceBridge(context).installedApplicationLabels();
    const labels = InstalledApplications.parse(source);
    if (labels.length === 0) throw new Error('设备未返回完整的已安装应用');
    const store = await preferences.getPreferences(context, 'installed-app-list');
    await store.put('labels', JSON.stringify(labels)); await store.flush();
    return InstalledApplications.merge(labels);
  }
}
