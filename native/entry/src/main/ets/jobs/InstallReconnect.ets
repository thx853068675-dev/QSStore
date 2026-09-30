/** Route-independent install request. Only the currently visible page presents it. */
export class InstallReconnect {
  private static requestId: string = '';
  private static owner: number = -1;
  private static nextId: number = 0;
  private static listeners: Map<number, (jobId: string) => void> = new Map();

  static subscribe(listener: (jobId: string) => void): number {
    const id = ++InstallReconnect.nextId;
    InstallReconnect.listeners.set(id, listener);
    return id;
  }

  private static notify(id: number, jobId: string): void {
    try { InstallReconnect.listeners.get(id)?.(jobId); } catch (_) {}
  }

  static activate(id: number): void {
    if (InstallReconnect.owner !== id) InstallReconnect.notify(InstallReconnect.owner, '');
    InstallReconnect.owner = id;
    InstallReconnect.notify(id, InstallReconnect.requestId);
  }

  static deactivate(id: number): void {
    if (InstallReconnect.owner !== id) return;
    InstallReconnect.notify(id, '');
    InstallReconnect.owner = -1;
  }

  static unsubscribe(id: number): void {
    InstallReconnect.deactivate(id);
    InstallReconnect.listeners.delete(id);
  }

  static request(jobId: string): void {
    if (jobId.length === 0 || InstallReconnect.requestId === jobId) return;
    InstallReconnect.requestId = jobId;
    InstallReconnect.notify(InstallReconnect.owner, jobId);
  }

  static clear(jobId: string): void {
    if (InstallReconnect.requestId !== jobId) return;
    InstallReconnect.requestId = '';
    InstallReconnect.notify(InstallReconnect.owner, '');
  }
}
