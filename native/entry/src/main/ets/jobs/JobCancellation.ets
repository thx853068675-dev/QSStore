/** 取消标记与任务互斥同生命周期，防止旧执行重新写回已取消的记录。 */
export class JobCancellation {
  private static cancelled: Set<string> = new Set();

  static cancel(id: string): void { JobCancellation.cancelled.add(id); }
  static isCancelled(id: string): boolean { return JobCancellation.cancelled.has(id); }
  static clear(id: string): void { JobCancellation.cancelled.delete(id); }
  static assertActive(id: string): void {
    if (JobCancellation.isCancelled(id)) throw new Error('安装任务已取消');
  }
}
