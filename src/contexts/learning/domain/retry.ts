import { FAILURE_CLASSES, type FailureClass } from "./failure";

export interface Attempt {
  readonly cls: FailureClass;
  readonly fingerprint: string;
}

export interface RetryPolicy {
  /** Total runs allowed, first run included. */
  readonly maxAttempts: number;
  readonly maxTransient: number;
  readonly baseDelayMs: number;
  readonly maxDelayMs: number;
}

export type RetryDecision =
  | { readonly action: "retry"; readonly delayMs: number; readonly reason: string }
  | { readonly action: "escalate"; readonly reason: string };

/** Adaptation may only tighten these caps; it never raises them (ADR-0007, ADR-0009). */
export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  maxAttempts: 4,
  maxTransient: 3,
  baseDelayMs: 30_000,
  maxDelayMs: 3_600_000,
};

/** Identical fingerprints in a row before any class, transient included, is escalated. */
const SAME_FINGERPRINT_CAP = 3;

// A retry repeats real side effects (contamination) or cannot help (auth, invalid input).
const NEVER_RETRY: ReadonlySet<FailureClass> = new Set<FailureClass>([
  "auth",
  "invalid_input",
  "contamination",
]);

/** Decides from the attempt history of one issue. Pure; the caller records the decision. */
export function decideRetry(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const last = history.at(-1);
  if (last === undefined) return { action: "escalate", reason: "no attempt to decide on" };
  if (NEVER_RETRY.has(last.cls)) {
    return { action: "escalate", reason: `${last.cls}: retrying cannot help; a human must act` };
  }
  if (history.length >= policy.maxAttempts) {
    return { action: "escalate", reason: `attempt cap ${policy.maxAttempts} reached` };
  }
  if (last.cls === "environment") return environmentDecision(history);
  const prev = history.at(-2);
  if (prev !== undefined && prev.fingerprint === last.fingerprint && last.cls !== "transient") {
    return { action: "escalate", reason: `same failure twice (${last.fingerprint})` };
  }
  // Belt and braces: a transient class can be wrong (free text, a repeated structured line). The cap
  // is on the fingerprint: the same fingerprint three runs in a row stops the loop, whatever the class.
  if (trailingRun(history, last.fingerprint) >= SAME_FINGERPRINT_CAP) {
    return {
      action: "escalate",
      reason: `same transient failure ${SAME_FINGERPRINT_CAP}× (${last.fingerprint})`,
    };
  }
  if (last.cls === "transient") return retryTransient(history, policy);
  return { action: "retry", delayMs: 0, reason: `${last.cls}: retry within caps` };
}

/** Consecutive identical fingerprints at the end of the history. */
function trailingRun(history: readonly Attempt[], fingerprint: string): number {
  let run = 0;
  for (let i = history.length - 1; i >= 0 && history[i]?.fingerprint === fingerprint; i--) run++;
  return run;
}

function environmentDecision(history: readonly Attempt[]): RetryDecision {
  const environmentRuns = history.filter((a) => a.cls === "environment").length;
  if (environmentRuns > 1) {
    return { action: "escalate", reason: "environment: fix the setup; retrying will not help" };
  }
  return { action: "retry", delayMs: 0, reason: "environment: one retry, then escalate" };
}

function retryTransient(history: readonly Attempt[], policy: RetryPolicy): RetryDecision {
  const transients = history.filter((a) => a.cls === "transient").length;
  if (transients > policy.maxTransient) {
    return { action: "escalate", reason: `transient failures exceed ${policy.maxTransient}` };
  }
  const delayMs = Math.min(policy.baseDelayMs * 2 ** (transients - 1), policy.maxDelayMs);
  return { action: "retry", delayMs, reason: `transient (${transients}): backoff` };
}

const CLASS_SET: ReadonlySet<string> = new Set<string>(FAILURE_CLASSES);

/** Validates the `--attempts FILE` JSON: an array of {cls, fingerprint}. Fails closed. */
export function parseAttempts(
  value: unknown,
):
  | { readonly ok: true; readonly attempts: readonly Attempt[] }
  | { readonly ok: false; readonly reason: string } {
  if (!Array.isArray(value)) return { ok: false, reason: "attempts must be a JSON array" };
  const attempts: Attempt[] = [];
  for (const [i, item] of value.entries()) {
    if (typeof item !== "object" || item === null)
      return { ok: false, reason: `attempt ${i} is not an object` };
    const { cls, fingerprint } = item as Record<string, unknown>;
    if (typeof cls !== "string" || !CLASS_SET.has(cls))
      return { ok: false, reason: `attempt ${i}: unknown class` };
    if (typeof fingerprint !== "string" || fingerprint.length === 0) {
      return { ok: false, reason: `attempt ${i}: missing fingerprint` };
    }
    attempts.push({ cls: cls as FailureClass, fingerprint });
  }
  return { ok: true, attempts };
}
