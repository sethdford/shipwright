import {
  type AdaptiveMode,
  EARLY_STOP_RULE,
  type EarlyStopRule,
  type StopProbe,
  spendAfterStop,
  stopTrigger,
  wouldStopAt,
} from "../domain/early-stop";
import type { CandidateVerifier, DeliveryPorts } from "../ports";
import { type AttemptResult, hasPatch, runAttempt, type TournamentRequest } from "./attempts";

/** How adaptive attempts actually ran, after checking the verifier. */
export interface AdaptivePlan {
  readonly requested: AdaptiveMode;
  /** Effective mode: enforce falls back to shadow, and both to off without a verifier. */
  readonly mode: AdaptiveMode;
  readonly verifier: CandidateVerifier | null;
  readonly notes: readonly string[];
}

/** The early-stop section of the tournament report (null when adaptive was off). */
export interface EarlyStopReport {
  readonly mode: AdaptiveMode;
  readonly requested: AdaptiveMode;
  readonly threshold: number;
  /** Attempts asked for. */
  readonly of: number;
  readonly ran: number;
  readonly wouldStopAt: number | null;
  readonly triggeredBy: string | null;
  /** Shadow: what the attempts after the stop point cost. Enforce: unspent per-attempt budget. */
  readonly savedUsd: number;
  readonly savedBasis: "spend-after-stop" | "unspent-budget";
  /** Whether the triggering attempt is the final winner or in its identical-patch group. */
  readonly sameWinner: boolean | null;
  readonly probes: readonly { readonly id: string; readonly p: number | null }[];
  readonly notes: readonly string[];
}

export interface AttemptRun {
  readonly attempts: readonly AttemptResult[];
  readonly probes: readonly StopProbe[];
}

const ruleOf = (req: TournamentRequest): EarlyStopRule => ({
  ...EARLY_STOP_RULE,
  threshold: req.stopAt,
});

async function readinessOf(v: CandidateVerifier): Promise<string | null> {
  if (!v.readiness) return "the verifier has no readiness check";
  try {
    return await v.readiness();
  } catch (e) {
    return `the readiness check failed: ${e instanceof Error ? e.message : String(e)}`;
  }
}

/** Decides the effective mode. Enforce needs a wired verifier whose readiness() returns null. */
export async function resolveAdaptive(
  ports: DeliveryPorts,
  req: TournamentRequest,
): Promise<AdaptivePlan> {
  const requested = req.adaptive;
  const verifier = ports.verifier ?? null;
  if (requested === "off") return { requested, mode: "off", verifier, notes: [] };
  if (verifier === null) {
    const note = `no merge verifier is wired, so early stop (${requested}) was not evaluated`;
    return { requested, mode: "off", verifier, notes: [note] };
  }
  if (requested === "shadow") return { requested, mode: "shadow", verifier, notes: [] };
  const why = await readinessOf(verifier);
  if (why === null) return { requested, mode: "enforce", verifier, notes: [] };
  const note = `enforce fell back to shadow: the verifier is not trusted to stop early (${why})`;
  return { requested, mode: "shadow", verifier, notes: [note] };
}

const eligible = (a: AttemptResult): boolean => hasPatch(a) && a.ownTests?.passed === true;

/** The verifier on this attempt alone: no cross-tests or rubric, which depend on other work. */
async function probe(
  v: CandidateVerifier,
  req: TournamentRequest,
  a: AttemptResult,
  index: number,
): Promise<StopProbe> {
  if (!eligible(a)) return { id: a.id, index, eligible: false, p: null };
  const p = await v.score({
    goal: req.goal,
    patch: a.snapshot?.patch ?? "",
    ownTestsPass: true,
    cross: null,
    rubric: null,
  });
  return { id: a.id, index, eligible: true, p };
}

/** Enforce: one attempt at a time, probed as it finishes, until the rule says stop. */
async function runSequential(
  ports: DeliveryPorts,
  req: TournamentRequest,
  base: string,
  budgetUsd: number,
  v: CandidateVerifier,
): Promise<AttemptRun> {
  const attempts: AttemptResult[] = [];
  const probes: StopProbe[] = [];
  for (let i = 0; i < req.attempts; i++) {
    const a = await runAttempt(ports, req, base, i, budgetUsd);
    attempts.push(a);
    probes.push(await probe(v, req, a, i));
    if (wouldStopAt(probes, ruleOf(req)) !== null) break;
  }
  return { attempts, probes };
}

/** Runs the attempts as the plan says: in parallel (off, shadow) or sequentially (enforce). */
export async function runAttempts(
  ports: DeliveryPorts,
  req: TournamentRequest,
  base: string,
  budgetUsd: number,
  plan: AdaptivePlan,
): Promise<AttemptRun> {
  const v = plan.verifier;
  if (plan.mode === "enforce" && v) return runSequential(ports, req, base, budgetUsd, v);
  const indexes = Array.from({ length: req.attempts }, (_, i) => i);
  const attempts = await Promise.all(
    indexes.map((i) => runAttempt(ports, req, base, i, budgetUsd)),
  );
  if (plan.mode !== "shadow" || !v) return { attempts, probes: [] };
  const probes = await Promise.all(attempts.map((a, i) => probe(v, req, a, i)));
  return { attempts, probes };
}

export interface Outcome {
  readonly winner: string | null;
  readonly candidates: readonly { readonly id: string; readonly members: readonly string[] }[];
}

function sameWinner(trigger: string | null, outcome: Outcome): boolean | null {
  if (trigger === null) return null;
  if (outcome.winner === null) return false;
  const group = outcome.candidates.find((c) => c.id === outcome.winner);
  return trigger === outcome.winner || (group?.members.includes(trigger) ?? false);
}

function saved(
  plan: AdaptivePlan,
  req: TournamentRequest,
  run: AttemptRun,
  k: number | null,
  perAttemptUsd: number,
) {
  if (plan.mode === "enforce") {
    const unspent = (req.attempts - run.attempts.length) * perAttemptUsd;
    return { savedUsd: Math.round(unspent * 100) / 100, savedBasis: "unspent-budget" as const };
  }
  const costs = run.attempts.map((a, index) => ({ index, costUsd: a.costUsd }));
  return { savedUsd: spendAfterStop(costs, k), savedBasis: "spend-after-stop" as const };
}

/** The report section: what early stopping did (enforce) or would have done (shadow). */
export function earlyStopReport(
  plan: AdaptivePlan,
  req: TournamentRequest,
  run: AttemptRun,
  outcome: Outcome,
  perAttemptUsd: number,
): EarlyStopReport | null {
  if (plan.requested === "off") return null;
  const k = wouldStopAt(run.probes, ruleOf(req));
  const trigger = stopTrigger(run.probes, ruleOf(req))?.id ?? null;
  return {
    mode: plan.mode,
    requested: plan.requested,
    threshold: req.stopAt,
    of: req.attempts,
    ran: run.attempts.length,
    wouldStopAt: k,
    triggeredBy: trigger,
    ...saved(plan, req, run, k, perAttemptUsd),
    sameWinner: sameWinner(trigger, outcome),
    probes: run.probes.map((p) => ({ id: p.id, p: p.p })),
    notes: plan.notes,
  };
}
