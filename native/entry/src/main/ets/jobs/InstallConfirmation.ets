/** Route-independent install request. Only the currently visible page presents it. */
export class InstallConfirmation {
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
