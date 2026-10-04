class ListEntry<T> {
  row: T;
  identity: string;
  signature: string;
  key: string;

  constructor(row: T, identity: string, signature: string, key: string) {
    this.row = row; this.identity = identity; this.signature = signature; this.key = key;
  }
}

/** LazyForEach 数据源：只创建可见卡片，追加分页保留已有节点和滚动位置。 */
export class ListDataSource<T> implements IDataSource {
  private entries: ListEntry<T>[] = [];
  private byIdentity: Map<string, ListEntry<T>> = new Map();
  private listeners: DataChangeListener[] = [];
  private revision: number = 0;
  private identity: (row: T) => string;
  private signature: (row: T) => string;

  constructor(identity: (row: T) => string, signature: (row: T) => string) {
    this.identity = identity; this.signature = signature;
  }

  totalCount(): number { return this.entries.length; }
  getData(index: number): T { return this.entries[index].row; }
  key(row: T): string { return this.byIdentity.get(this.identity(row))!.key; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener) => item !== listener);
  }

  update(rows: T[]): void {
    const next: ListEntry<T>[] = [];
    const index = new Map<string, ListEntry<T>>();
    for (const row of rows) {
      const id = this.identity(row), signature = this.signature(row);
      const old = this.byIdentity.get(id);
      const entry = old !== undefined && old.signature === signature ? old :
        new ListEntry(row, id, signature, id + ':' + (++this.revision));
      next.push(entry); index.set(id, entry);
    }
    const count = this.entries.length;
    const prefixUnchanged = next.length >= count &&
      this.entries.every((entry: ListEntry<T>, i: number) => entry === next[i]);
    this.byIdentity = index;
    if (prefixUnchanged) {
      for (let i = count; i < next.length; i++) {
        this.entries.push(next[i]);
        this.listeners.forEach((listener: DataChangeListener) => listener.onDataAdd(i));
      }
    } else {
      this.entries = next;
      // 内容变化的条目使用新 key；未变化的卡片继续复用。
      this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
    }
  }
}
