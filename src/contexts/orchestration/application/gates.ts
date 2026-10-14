// The dispatch gate composition (ADR-0007): pause → breaker → budget → review WIP → fix loop.
// Short-circuits at the first closed gate, so a paused system never writes a breaker incident.
// Fails closed: a source that cannot be read, a port that throws, or data that cannot be judged
// closes its gate with verdict "error". Only "allowed" and "skipped" (no-GitHub mode) pass.
import type { AdapterError } from "../../../shared/kernel/ports";
import { describeBreaker } from "../domain/breaker";
import { describeBudget } from "../domain/budget";
import { DEFAULT_FLOW_POLICY, describeWip, fixLoopAllows, reviewWip } from "../domain/flow";
import type { SafetyPorts } from "../ports";
import { checkBreaker, RUN_HISTORY_LIMIT } from "./breaker";
import { checkBudget } from "./budget";
import { readPause } from "./pause";

export const GATE_ORDER = ["pause", "breaker", "budget", "review_wip", "fix_loop"] as const;
export type GateName = (typeof GATE_ORDER)[number];
export type GateVerdict = "allowed" | "blocked" | "error" | "skipped";

export interface GateResult {
  readonly gate: GateName;
  readonly verdict: GateVerdict;
  readonly detail: string;
  /** Passed, but nothing was actually checked (budget with no cost files, as on CI). */
  readonly warning?: true;
}

export interface GateOptions {
  /** False in no-GitHub mode: the breaker and review-WIP gates are skipped. */
  readonly github: boolean;
  /**
   * How many times this issue has already been retried: 0 for a first dispatch. Callers must pass
   * it explicitly (the daemon its retry count, auto-retry its bot-marker count); an invalid value
   * closes the fix-loop gate.
   */
  readonly retry: number;
}

export interface GatesReport {
  /** True only when every gate was reached and each one allowed (or was skipped). */
  readonly allowed: boolean;
  /** The gates reached, in order; the last one closed the run when `allowed` is false. */
  readonly results: readonly GateResult[];
}

export const gatePasses = (r: GateResult): boolean =>
  r.verdict === "allowed" || r.verdict === "skipped";

const result = (gate: GateName, allowed: boolean, detail: string): GateResult => ({
  gate,
  verdict: allowed ? "allowed" : "blocked",
  detail,
});
const unreadable = (gate: GateName, e: AdapterError): GateResult => ({
  gate,
  verdict: "error",
  detail: `cannot verify (${e.kind}): ${e.message}`,
});
const skipped = (gate: GateName): GateResult => ({
  gate,
  verdict: "skipped",
  detail: "skipped (no GitHub)",
});

async function pauseGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  const r = await readPause(ports, { github: o.github });
  if (!r.ok) return unreadable("pause", r.error);
  const detail = r.value.paused ? r.value.reasons.join("; ") : "not paused";
  return result("pause", !r.value.paused, detail);
}

async function breakerGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  if (!o.github) return skipped("breaker");
  const r = await checkBreaker(ports);
  if (!r.ok) return unreadable("breaker", r.error);
  const incident = r.value.incidentError ? `; incident not recorded: ${r.value.incidentError}` : "";
  return result("breaker", r.value.allowed, `${describeBreaker(r.value.state)}${incident}`);
}

async function budgetGate(ports: SafetyPorts): Promise<GateResult> {
  const r = await checkBudget(ports, 0);
  if (!r.ok) return unreadable("budget", r.error);
  const gate = result("budget", r.value.allowed, describeBudget(r.value));
  return r.value.noData ? { ...gate, warning: true } : gate;
}

async function reviewGate(ports: SafetyPorts, o: GateOptions): Promise<GateResult> {
  if (!o.github) return skipped("review_wip");
  const [pulls, runs] = await Promise.all([
    ports.pulls.open(),
    ports.runs.recentRuns(RUN_HISTORY_LIMIT),
  ]);
  if (!pulls.ok) return unreadable("review_wip", pulls.error);
  if (!runs.ok) return unreadable("review_wip", runs.error);
  const inFlight = runs.value.filter((r) => r.finished === null).length;
  // Every fetched run unfinished: the window may hide more in-flight runs, so the count is unknown.
  if (runs.value.length > 0 && inFlight === runs.value.length) {
    return {
      gate: "review_wip",
      verdict: "error",
      detail: `cannot verify: all ${inFlight} fetched runs are unfinished, so the in-flight count is unknown`,
    };
  }
  const v = reviewWip(pulls.value, inFlight);
  return result("review_wip", v.allowed, describeWip(v));
}

function fixLoopGate(o: GateOptions): GateResult {
  const cap = DEFAULT_FLOW_POLICY.fixLoopCap;
  const { retry } = o;
  if (!Number.isSafeInteger(retry) || retry < 0) {
    return { gate: "fix_loop", verdict: "error", detail: `retry count unknown (got ${retry})` };
  }
  const allowed = fixLoopAllows(retry);
  if (!allowed) return result("fix_loop", false, `retry ${retry} exceeds the cap of ${cap}`);
  const detail = retry === 0 ? `first dispatch (retry 0 of ${cap})` : `retry ${retry} of ${cap}`;
  return result("fix_loop", true, detail);
}

async function guarded(gate: GateName, run: () => Promise<GateResult>): Promise<GateResult> {
  try {
    return await run();
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return { gate, verdict: "error", detail: `cannot verify: ${message}` };
  }
}

export async function checkDispatchGates(
  ports: SafetyPorts,
  options: GateOptions,
): Promise<GatesReport> {
  const gates: Record<GateName, () => Promise<GateResult>> = {
    pause: () => pauseGate(ports, options),
    breaker: () => breakerGate(ports, options),
    budget: () => budgetGate(ports),
    review_wip: () => reviewGate(ports, options),
    fix_loop: async () => fixLoopGate(options),
  };
  const results: GateResult[] = [];
  for (const name of GATE_ORDER) {
    const r = await guarded(name, gates[name]);
    results.push(r);
    if (!gatePasses(r)) return { allowed: false, results };
  }
  return { allowed: true, results };
}
