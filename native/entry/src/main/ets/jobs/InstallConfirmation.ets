/** Route-independent install request. Only the currently visible page presents it. */
export class InstallConfirmation {
  static dataLossTitle(renewal: boolean): string {
    return renewal ? '无法保留数据续签' : '需要卸载旧版';
  }

  static dataLossMessage(renewal: boolean, self: boolean): string {
    if (self) return '继续会先卸载轻启·安装器，再安装' + (renewal ? '续签后的版本' : '新版') +
      '。登录状态、本地安装记录、无线调试配对和本地签名材料会清除；签名身份会在卸载前备份。是否继续？';
    return (renewal ? '当前签名身份无法保留数据续签。' : '系统无法保留数据覆盖更新。') +
      '继续会先卸载旧版，再安装' + (renewal ? '续签后的同版本应用' : '新版') +
      '；该应用的缓存、设置和登录状态都会清除。取消会保留旧应用。是否继续？';
  }

  static dataLossAction(renewal: boolean): string {
    return renewal ? '清除数据并续签' : '清除数据并安装';
  }

  private static requestId: string = '';
  private static owner: number = -1;
  private static nextId: number = 0;
  private static listeners: Map<number, (jobId: string) => void> = new Map();

  static subscribe(listener: (jobId: string) => void): number {
    const id = ++InstallConfirmation.nextId;
    InstallConfirmation.listeners.set(id, listener);
    return id;
  }

  private static notify(id: number, jobId: string): void {
    try { InstallConfirmation.listeners.get(id)?.(jobId); } catch (_) {}
  }

  static activate(id: number): void {
    if (InstallConfirmation.owner !== id) InstallConfirmation.notify(InstallConfirmation.owner, '');
    InstallConfirmation.owner = id;
    InstallConfirmation.notify(id, InstallConfirmation.requestId);
  }

  static isOwner(id: number): boolean {
    return id > 0 && InstallConfirmation.owner === id && InstallConfirmation.listeners.has(id);
  }

  static isRequested(id: string): boolean { return InstallConfirmation.requestId === id; }

  static deactivate(id: number): void {
    if (InstallConfirmation.owner !== id) return;
    InstallConfirmation.notify(id, '');
    InstallConfirmation.owner = -1;
  }

  static unsubscribe(id: number): void {
    InstallConfirmation.deactivate(id);
    InstallConfirmation.listeners.delete(id);
  }

  static request(jobId: string): void {
    if (jobId.length === 0 || InstallConfirmation.requestId === jobId) return;
    InstallConfirmation.requestId = jobId;
    InstallConfirmation.notify(InstallConfirmation.owner, jobId);
  }

  static clear(jobId: string): void {
    if (InstallConfirmation.requestId !== jobId) return;
    InstallConfirmation.requestId = '';
    InstallConfirmation.notify(InstallConfirmation.owner, '');
  }
}
