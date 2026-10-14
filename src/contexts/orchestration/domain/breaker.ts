// Global circuit breaker (spec §6.2, ADR-0007). Pure: the state is recomputed from run history on
// every check, so every caller (CI workflows, the daemon, any machine) reaches the same answer.

/** `cancelled` is neither a failure nor a success: it never enters the window or settles a probe. */
export type RunOutcome = "success" | "failure" | "cancelled";

export interface RunRecord {
  readonly id: string;
  /** Epoch ms when the run was created (queued). */
  readonly startedAt: number;
  /** `null` while the run is queued or in progress. */
  readonly finished: { readonly at: number; readonly outcome: RunOutcome } | null;
}

export interface BreakerPolicy {
  /** How many of the most recent finished runs are considered. */
  readonly window: number;
  /** The breaker opens when at least this many runs in the window failed. */
  readonly maxFailures: number;
  /** Time after opening before one probe run is allowed. */
  readonly coolDownMs: number;
}

/** Returns the policy, or throws if it could never behave sensibly. */
export function breakerPolicy(policy: BreakerPolicy): BreakerPolicy {
  const { window, maxFailures, coolDownMs } = policy;
  if (!Number.isInteger(window) || window < 1) {
    throw new Error(`breaker window must be an integer >= 1, got ${window}`);
  }
  if (!Number.isInteger(maxFailures) || maxFailures < 1 || maxFailures > window) {
    throw new Error(`breaker maxFailures must be an integer in 1..${window}, got ${maxFailures}`);
  }
  if (!Number.isFinite(coolDownMs) || coolDownMs <= 0) {
    throw new Error(`breaker coolDownMs must be > 0, got ${coolDownMs}`);
  }
  return policy;
}

export const DEFAULT_BREAKER_POLICY: BreakerPolicy = breakerPolicy({
  window: 8,
  maxFailures: 5,
  coolDownMs: 30 * 60 * 1000,
});

export type BreakerState =
  | { readonly kind: "closed"; readonly failures: number; readonly considered: number }
  | { readonly kind: "open"; readonly since: number; readonly probeAfter: number }
  | { readonly kind: "half_open"; readonly since: number; readonly probing: boolean };

type Finished = RunRecord & { readonly finished: NonNullable<RunRecord["finished"]> };
type Fold =
  | { readonly state: "closed"; readonly window: readonly RunOutcome[] }
  | { readonly state: "open"; readonly since: number };

const isFinished = (r: RunRecord): r is Finished => r.finished !== null;
const failuresIn = (window: readonly RunOutcome[]) => window.filter((o) => o === "failure").length;

function step(fold: Fold, run: Finished, policy: BreakerPolicy): Fold {
  if (run.finished.outcome === "cancelled") return fold;
  if (fold.state === "closed") {
    const window = [...fold.window, run.finished.outcome].slice(-policy.window);
    return failuresIn(window) >= policy.maxFailures
      ? { state: "open", since: run.finished.at }
      : { state: "closed", window };
  }
  // Only a run started after the cool-down is a probe; runs in flight when it opened are ignored.
  if (run.startedAt < fold.since + policy.coolDownMs) return fold;
  return run.finished.outcome === "success"
    ? { state: "closed", window: [] }
    : { state: "open", since: run.finished.at };
}

const byCompletion = (a: Finished, b: Finished) =>
  a.finished.at - b.finished.at ||
  a.startedAt - b.startedAt ||
  (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/**
 * Folds finished runs in completion order (ties: start time, then id), then applies the cool-down
 * at `now`. `now` must come from the same clock as the run timestamps (GitHub server time), or
 * skew moves the cool-down edges. Runs that were in flight when it opened are ignored: only a run
 * created after the cool-down can be the probe. A probe still in flight after a further cool-down
 * is treated as abandoned, so a stuck run cannot block dispatch forever.
 */
export function evaluateBreaker(
  runs: readonly RunRecord[],
  now: number,
  rawPolicy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): BreakerState {
  const policy = breakerPolicy(rawPolicy);
  const finished = runs.filter(isFinished).sort(byCompletion);
  const fold = finished.reduce<Fold>((f, run) => step(f, run, policy), {
    state: "closed",
    window: [],
  });
  if (fold.state === "closed") {
    return { kind: "closed", failures: failuresIn(fold.window), considered: fold.window.length };
  }
  const probeAfter = fold.since + policy.coolDownMs;
  if (now < probeAfter) return { kind: "open", since: fold.since, probeAfter };
  const probing = runs.some(
    (r) =>
      r.finished === null && r.startedAt >= probeAfter && now - r.startedAt <= policy.coolDownMs,
  );
  return { kind: "half_open", since: fold.since, probing };
}

const iso = (epochMs: number) => new Date(epochMs).toISOString();

export function describeBreaker(state: BreakerState): string {
  if (state.kind === "closed") {
    return `closed (${state.failures} of the last ${state.considered} runs failed)`;
  }
  if (state.kind === "open") {
    return `open since ${iso(state.since)}; probe allowed after ${iso(state.probeAfter)}`;
  }
  const probe = state.probing ? "probe run in flight" : "one probe run allowed";
  return `half-open since ${iso(state.since)}; ${probe}`;
}

export function breakerAllowsDispatch(state: BreakerState): boolean {
  return state.kind === "closed" || (state.kind === "half_open" && !state.probing);
}

/** The incident issue opened (once per trip) when the breaker is open. */
export function breakerIncident(
  state: Extract<BreakerState, { kind: "open" }>,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): { readonly title: string; readonly body: string } {
  const minutes = Math.round(policy.coolDownMs / 60_000);
  return {
    title: "Shipwright circuit breaker is open: dispatch stopped",
    body: [
      `The global circuit breaker opened at ${iso(state.since)}: at least ${policy.maxFailures} of the last ${policy.window} pipeline runs failed.`,
      "",
      `Dispatch, auto-retry and watchdog retries are stopped. After ${minutes} minutes one probe run is allowed; if it succeeds the breaker closes, if it fails the breaker re-opens.`,
      "",
      "To keep everything stopped while you investigate, add the `shipwright:pause` label to any open issue or run `shipwright pause`.",
    ].join("\n"),
  };
}
