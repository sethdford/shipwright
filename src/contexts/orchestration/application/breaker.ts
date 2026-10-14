import { idempotencyKey } from "../../../shared/kernel/durability";
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
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

export interface BreakerReport {
  readonly state: BreakerState;
  readonly allowed: boolean;
  /** Set only by checkBreaker when the breaker is open. */
  readonly incident: IncidentOutcome | null;
}

/** Read-only: evaluates the breaker over recent runs. */
export async function breakerStatus(
  ports: Pick<SafetyPorts, "runs" | "now">,
  policy: BreakerPolicy = DEFAULT_BREAKER_POLICY,
): Promise<Result<BreakerReport, AdapterError>> {
  const runs = await ports.runs.recentRuns(RUN_HISTORY_LIMIT);
  if (!runs.ok) return runs;
  const state = evaluateBreaker(runs.value, ports.now(), policy);
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
  return incident.ok ? ok({ ...status.value, incident: incident.value }) : incident;
}
