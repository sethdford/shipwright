// The timeout and caller-abort guard of one agent call (#8696). The timer functions are injected, so tests fire a
// timeout explicitly instead of racing the wall clock.

/** The two timer functions the guard uses. Injected so tests fire the timeout explicitly, not by wall clock. */
export interface GuardTimers {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const REAL_TIMERS: GuardTimers = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** Aborts the controller on timeout or when the caller's signal fires; `dispose` undoes both. */
export function armGuard(timeoutMs: number, signal: AbortSignal | undefined, timers: GuardTimers) {
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  const timer = timers.setTimeout(() => {
    guard.timedOut = true;
    controller.abort();
  }, timeoutMs);
  signal?.addEventListener("abort", onAbort, { once: true });
  const guard = {
    controller,
    timedOut: false,
    dispose: () => {
      timers.clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    },
  };
  return guard;
}
