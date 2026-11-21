class ResourceWaiter {
  id: string = '';
  local: boolean = false;
  resolve: (release: () => void) => void = () => {};
  reject: (error: Error) => void = () => {};
}
class ResourceLane {
  capacity: number = 1;
  used: number = 0;
  localStreak: number = 0;
  waiting: ResourceWaiter[] = [];
}

/** Event-driven phase permits. Two local turns then one ready store turn prevent starvation. */
export class InstallResourceQueue {
  private lanes: Map<string, ResourceLane> = new Map();

  acquire(key: string, id: string, local: boolean, capacity: number, onWait?: () => void): Promise<() => void> {
    let lane = this.lanes.get(key);
    if (!lane) { lane = new ResourceLane(); lane.capacity = capacity; this.lanes.set(key, lane); }
    if (capacity < 1 || capacity !== lane.capacity) return Promise.reject(new Error('Invalid installation resource capacity'));
    const current = lane;
    return new Promise<() => void>((resolve, reject) => {
      if (current.used >= current.capacity) onWait?.();
      const waiter = new ResourceWaiter(); waiter.id = id; waiter.local = local;
      waiter.resolve = resolve; waiter.reject = reject; current.waiting.push(waiter);
      this.drain(key, current);
    });
  }

  cancel(id: string): void {
    for (const key of Array.from(this.lanes.keys())) {
      const lane = this.lanes.get(key)!;
      const removed = lane.waiting.filter((row: ResourceWaiter) => row.id === id);
      lane.waiting = lane.waiting.filter((row: ResourceWaiter) => row.id !== id);
      removed.forEach((row: ResourceWaiter) => row.reject(new Error('安装任务已取消')));
      this.drain(key, lane);
    }
  }

  private drain(key: string, lane: ResourceLane): void {
    while (lane.used < lane.capacity && lane.waiting.length > 0) {
      const local = lane.waiting.findIndex((row: ResourceWaiter) => row.local);
      const store = lane.waiting.findIndex((row: ResourceWaiter) => !row.local);
      const index = store >= 0 && (local < 0 || lane.localStreak >= 2) ? store : local >= 0 ? local : 0;
      const row = lane.waiting.splice(index, 1)[0];
      lane.localStreak = row.local ? Math.min(2, lane.localStreak + 1) : 0;
      lane.used++;
      let held = true;
      row.resolve(() => {
        if (!held) return;
        held = false; lane.used--; this.drain(key, lane);
      });
    }
    if (lane.used === 0 && lane.waiting.length === 0 && this.lanes.get(key) === lane) this.lanes.delete(key);
  }
}
