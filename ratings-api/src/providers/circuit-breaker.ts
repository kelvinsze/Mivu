export interface CircuitBreakerOptions {
  failureThreshold?: number; // Number of failures before tripping (default 5)
  resetTimeoutMs?: number;   // Cool-down window in ms (default 60,000ms = 1 minute)
}

interface ProviderCircuitState {
  failures: number;
  lastFailureTime: number;
  state: 'CLOSED' | 'OPEN' | 'HALF_OPEN';
}

export class CircuitBreaker {
  private states = new Map<string, ProviderCircuitState>();
  private failureThreshold: number;
  private resetTimeoutMs: number;

  constructor(options: CircuitBreakerOptions = {}) {
    this.failureThreshold = options.failureThreshold ?? 5;
    this.resetTimeoutMs = options.resetTimeoutMs ?? 60000;
  }

  private getState(provider: string): ProviderCircuitState {
    let state = this.states.get(provider);
    if (!state) {
      state = {
        failures: 0,
        lastFailureTime: 0,
        state: 'CLOSED',
      };
      this.states.set(provider, state);
    }
    return state;
  }

  isOpen(provider: string): boolean {
    const state = this.getState(provider);
    const now = Date.now();

    if (state.state === 'OPEN') {
      if (now - state.lastFailureTime > this.resetTimeoutMs) {
        state.state = 'HALF_OPEN';
        return false;
      }
      return true;
    }

    return false;
  }

  recordSuccess(provider: string): void {
    const state = this.getState(provider);
    state.failures = 0;
    state.state = 'CLOSED';
  }

  recordFailure(provider: string): void {
    const state = this.getState(provider);
    state.failures += 1;
    state.lastFailureTime = Date.now();

    if (state.failures >= this.failureThreshold) {
      state.state = 'OPEN';
    }
  }

  reset(provider?: string): void {
    if (provider) {
      this.states.delete(provider);
    } else {
      this.states.clear();
    }
  }
}

// Global in-memory circuit breaker instance for worker runtime
export const globalCircuitBreaker = new CircuitBreaker();
