import { CatalogApp } from './CatalogApp';

/** 发现页合集里的一条：应用本身 + 该窗口内的发版次数（仅「更新最频繁」有值）。 */
export class DiscoveryEntry {
  app: CatalogApp = new CatalogApp();
  updatesInWindow: number = 0;
  /** 本周星数增量。 */
  starsDelta: number = 0;
  starsToday: number = -1;

  static fromJson(row: Record<string, Object>): DiscoveryEntry {
    const entry = new DiscoveryEntry();
    entry.app = CatalogApp.fromJson(row);
    const updates = Number(row['updates_in_window'] ?? 0);
    entry.updatesInWindow = Number.isFinite(updates) && updates > 0 ? Math.floor(updates) : 0;
    const delta = Number(row['stars_delta'] ?? 0);
    entry.starsDelta = Number.isFinite(delta) && delta > 0 ? Math.floor(delta) : 0;
    const today = Number(row['stars_today'] ?? -1);
    entry.starsToday = Number.isFinite(today) && today >= 0 ? Math.floor(today) : -1;
    return entry;
  }
}

export class DiscoveryBlock {
  key: string = '';
  basis: string = '';
  observedFrom: number = 0;
  observedDays: number = 0;
  entries: DiscoveryEntry[] = [];
  total: number = 0;
  page: number = 1;
  pageSize: number = 0;

  static fromJson(row: Record<string, Object>): DiscoveryBlock {
    const block = new DiscoveryBlock();
    block.key = String(row['key'] ?? '');
    block.basis = String(row['basis'] ?? '');
    block.observedFrom = Number(row['observed_from'] ?? 0);
    block.observedDays = Number(row['observed_days'] ?? 0);
    const rows = row['items'] as Array<Record<string, Object>> | undefined;
    block.entries = (rows ?? []).map((item: Record<string, Object>) => DiscoveryEntry.fromJson(item));
    block.total = Number(row['total'] ?? block.entries.length);
    block.page = Number(row['page'] ?? 1);
    block.pageSize = Number(row['page_size'] ?? block.entries.length);
    return block;
  }
}

export class HomeTypeGroup {
  title: string = '';
  apps: CatalogApp[] = [];

  static fromJson(data: Record<string, Object>): HomeTypeGroup {
    const group = new HomeTypeGroup();
    group.title = String(data['category'] ?? '');
    const rows = data['items'] as Array<Record<string, Object>> | undefined;
    group.apps = (rows ?? []).map((row: Record<string, Object>) => CatalogApp.fromJson(row));
    return group;
  }
}

/** `/api/v1/collections` 的发现页数据。 */
export class DiscoveryCollections {
  networkScope: string = '';
  windowDays: number = 7;
  generatedAt: number = 0;
  blocks: DiscoveryBlock[] = [];
  categories: string[] = [];
  typeGroups: HomeTypeGroup[] = [];
  showOverseasSection: boolean = false;

  static fromJson(data: Record<string, Object>): DiscoveryCollections {
    const result = new DiscoveryCollections();
    result.networkScope = String(data['network_scope'] ?? '');
    result.windowDays = Number(data['window_days'] ?? 7);
    result.generatedAt = Number(data['generated_at'] ?? 0);
    result.showOverseasSection = data['show_overseas_section'] === true;
    const rows = data['blocks'] as Array<Record<string, Object>> | undefined;
    result.blocks = (rows ?? []).map((row: Record<string, Object>) => DiscoveryBlock.fromJson(row))
      .filter((block: DiscoveryBlock) => block.key !== 'overseas' || result.showOverseasSection);
    const categories = data['categories'] as Array<Record<string, Object>> | undefined;
    result.categories = (categories ?? []).map((row: Record<string, Object>) => String(row['category'] ?? ''))
      .filter((category: string) => category.length > 0);
    const groups = data['type_groups'] as Array<Record<string, Object>> | undefined;
    result.typeGroups = (groups ?? []).map((row: Record<string, Object>) => HomeTypeGroup.fromJson(row));
    return result;
  }

  block(key: string): DiscoveryBlock {
    return this.blocks.find((item: DiscoveryBlock) => item.key === key) ?? new DiscoveryBlock();
  }

  apps(): CatalogApp[] {
    const rows = new Map<number, CatalogApp>();
    for (const block of this.blocks) {
      for (const entry of block.entries) rows.set(entry.app.id, entry.app);
    }
    for (const group of this.typeGroups) {
      for (const app of group.apps) rows.set(app.id, app);
    }
    return Array.from(rows.values());
  }

  get loaded(): boolean {
    return this.blocks.length > 0;
  }
}
