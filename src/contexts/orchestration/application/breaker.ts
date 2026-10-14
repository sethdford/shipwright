import { idempotencyKey } from "../../../shared/kernel/durability";
import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import type { IncidentOutcome } from "../../integrations";
import {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  breakerIncident,
  DEFAULT_BREAKER_POLICY,
  evaluateBreaker,
} from "../domain/breaker";
import type { SafetyPorts } from "../ports";

/** Runs read per check: the 8-run window plus room for in-flight and uncounted runs. */
export const RUN_HISTORY_LIMIT = 50;

const fail = (message: string) => err<AdapterError>({ kind: "failed", message });

export interface BreakerReport {
  readonly state: BreakerState;
  readonly allowed: boolean;
  /** Set only by checkBreaker when the breaker is open. */
  readonly incident: IncidentOutcome | null;
  /** Set when the breaker is open but the incident write failed; the state still stands. */
  readonly incidentError?: string;
}

/**
 * Read-only: evaluates the breaker over recent runs. Fails closed (error) when the history is
 * full-length yet holds too few finished runs to judge, or when the policy is invalid. Validate a
 * custom policy once at wiring with `breakerPolicy`.
 *
 * While the breaker is open, every `checkBreaker` reconciles the incident (an idempotent read,
 * no write once recorded). That cost is accepted; Wave 1b caches it in SideEffects.
 */
export async function breakerStatus(
  ports: Pick<SafetyPorts, "runs" | "now">,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): Promise<Result<BreakerReport, AdapterError>> {
  const runs = await ports.runs.recentRuns(RUN_HISTORY_LIMIT);
  if (!runs.ok) return runs;
  let state: BreakerState;
  try {
    state = evaluateBreaker(runs.value, ports.now(), policy);
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
  const counted = runs.value.filter(
    (r) => r.finished !== null && r.finished.outcome !== "cancelled",
  ).length;
  if (
    state.kind === "closed" &&
    runs.value.length >= RUN_HISTORY_LIMIT &&
    counted < policy.window
  ) {
    return fail(
      `breaker indeterminate: fewer than ${policy.window} finished runs in the last ${RUN_HISTORY_LIMIT}`,
    );
  }
  return ok({ state, allowed: breakerAllowsDispatch(state), incident: null });
}

/** The dispatch gate: like breakerStatus, and an open breaker ensures one incident per trip. */
export async function checkBreaker(
  ports: Pick<SafetyPorts, "runs" | "now" | "github">,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): Promise<Result<BreakerReport, AdapterError>> {
  const status = await breakerStatus(ports, policy);
  if (!status.ok || status.value.state.kind !== "open") return status;
  const { state } = status.value;
  const key = idempotencyKey("breaker", "open", String(state.since));
  const incident = await ports.github.ensureIncident(key, breakerIncident(state, policy));
  return incident.ok
    ? ok({ ...status.value, incident: incident.value })
    : ok({ ...status.value, incidentError: incident.error.message });
}
