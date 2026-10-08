import hapCore from 'libhap_core.so';

/** Native, automatically expiring cadence request for the window opening. */
export class ResumeFramePacing {
  static start(): void {
    try { hapCore.setResumeFramePacing(true); } catch (_) {}
  }
  static stop(): void {
    try { hapCore.setResumeFramePacing(false); } catch (_) {}
  }
}
