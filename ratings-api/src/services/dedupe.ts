/**
 * In-process promise map to collapse simultaneous in-flight requests
 * for the same identity into a single upstream execution (Section 19).
 */
export class RequestDeduplicator<T> {
  private inFlight = new Map<string, Promise<T>>();

  async execute(key: string, task: () => Promise<T>): Promise<T> {
    const existing = this.inFlight.get(key);
    if (existing) {
      return existing;
    }

    const promise = task().finally(() => {
      this.inFlight.delete(key);
    });

    this.inFlight.set(key, promise);
    return promise;
  }

  clear(): void {
    this.inFlight.clear();
  }
}
