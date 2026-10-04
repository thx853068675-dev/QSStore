/** Durable jobs retain the wait; this bus moves its prompt to the visible route. */
export class InstallCertificateSlots {
  private static requestId: string = '';
  private static owner: number = -1;
  private static nextId: number = 0;
  private static scopes: Map<string, string> = new Map();
  private static listeners: Map<number, (id: string) => void> = new Map();

  static subscribe(listener: (id: string) => void): number {
    const id = ++InstallCertificateSlots.nextId;
    InstallCertificateSlots.listeners.set(id, listener);
    return id;
  }
  private static notify(id: number, job: string): void {
    try { InstallCertificateSlots.listeners.get(id)?.(job); } catch (_) {}
  }
  static activate(id: number): void {
    if (InstallCertificateSlots.owner !== id) InstallCertificateSlots.notify(InstallCertificateSlots.owner, '');
    InstallCertificateSlots.owner = id;
    InstallCertificateSlots.notify(id, InstallCertificateSlots.requestId);
  }
  static deactivate(id: number): void {
    if (InstallCertificateSlots.owner !== id) return;
    InstallCertificateSlots.notify(id, '');
    InstallCertificateSlots.owner = -1;
  }
  static unsubscribe(id: number): void {
    InstallCertificateSlots.deactivate(id);
    InstallCertificateSlots.listeners.delete(id);
  }
  static isOwner(id: number): boolean { return InstallCertificateSlots.owner === id && id > 0; }
  static isRequested(id: string): boolean { return InstallCertificateSlots.requestId === id; }
  static scope(id: string): string { return InstallCertificateSlots.scopes.get(id) ?? ''; }
  static request(id: string, scope: string = ''): void {
    if (scope) InstallCertificateSlots.scopes.set(id, scope);
    if (!id || InstallCertificateSlots.requestId === id) return;
    InstallCertificateSlots.requestId = id;
    InstallCertificateSlots.notify(InstallCertificateSlots.owner, id);
  }
  static clear(id: string): void {
    InstallCertificateSlots.scopes.delete(id);
    if (InstallCertificateSlots.requestId !== id) return;
    InstallCertificateSlots.requestId = '';
    InstallCertificateSlots.notify(InstallCertificateSlots.owner, '');
  }
}
