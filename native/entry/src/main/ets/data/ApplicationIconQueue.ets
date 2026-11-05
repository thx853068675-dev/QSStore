class IconWork {
  run: () => Promise<string> = async () => '';
  resolve: (value: string) => void = () => {};
  reject: (reason: Error) => void = () => {};
}

/** Bounded parallel reads: one slow market response must not hold up every visible row. */
export class ApplicationIconQueue {
  private active: number = 0;
  private waiting: IconWork[] = [];
  submit(run: () => Promise<string>): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const work = new IconWork(); work.run = run; work.resolve = resolve; work.reject = reject;
      this.waiting.push(work);
      this.drain();
    });
  }
  private drain(): void {
    while (this.active < 4 && this.waiting.length > 0) {
      const work = this.waiting.shift()!;
      this.active++;
      // Defer execution until the caller has registered its deduplication/interest state.
      Promise.resolve().then(() => work.run()).then((value: string) => {
        work.resolve(value); this.active--; this.drain();
      }, (error: Error) => {
        work.reject(error); this.active--; this.drain();
      });
    }
  }
}
