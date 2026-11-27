import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { planBudget } from "../domain/budget";
import { crossPassRate, type TestMatrix } from "../domain/cross-tests";
import type { Rubric } from "../domain/rubric";
import {
  type CandidateScore,
  compositeScore,
  finalists,
  groupIdentical,
  type Selection,
  select,
} from "../domain/selection";
import type { DeliveryPorts } from "../ports";
import {
  type EarlyStopReport,
  earlyStopReport,
  readinessOf,
  resolveAdaptive,
  runAttempts,
} from "./adaptive";
import { type AttemptResult, hasPatch, type TournamentRequest } from "./attempts";
import {
  type Contender,
  crossTest,
  draftRubric,
  gradeContender,
  type JudgeResult,
  judge,
} from "./judging";

export interface ScoredCandidate extends CandidateScore {
  readonly members: readonly string[];
  readonly composite: number;
  /** The verifier's chance while it is not trusted: reported, not counted in `composite`. */
  readonly verifierShadow?: number;
}

export interface TournamentReport {
  readonly baseSha: string;
  readonly attempts: readonly Omit<AttemptResult, "workspace">[];
  readonly rubric: Rubric | null;
  readonly matrix: TestMatrix | null;
  readonly candidates: readonly ScoredCandidate[];
  readonly judge: JudgeResult | null;
  readonly selection: Selection;
  readonly winnerSha: string | null;
  readonly adopted: boolean;
  readonly costUsd: number;
  readonly notes: readonly string[];
  /** Adaptive attempts: what early stopping did or would have done; null when it was off. */
  readonly earlyStop: EarlyStopReport | null;
}

class Spend {
  costUsd = 0;
  readonly notes: string[] = [];
  add<T>(c: { value: T; costUsd: number; note: string | null }): T {
    this.costUsd += c.costUsd;
    if (c.note) this.notes.push(c.note);
    return c.value;
  }
}

function scoreOf(
  c: Contender,
  votes: readonly string[],
  cross: number | null,
  rubric: number | null,
): ScoredCandidate {
  const base = {
    id: c.id,
    built: true,
    ownTestsPass: c.ownTests?.passed === true,
    cross,
    rubric,
    votes: votes.length,
  };
  return { ...base, members: votes, composite: compositeScore(base) };
}

async function scoreContenders(
  ports: DeliveryPorts,
  req: TournamentRequest,
  attempts: readonly AttemptResult[],
  rubric: Rubric | null,
  spend: Spend,
) {
  const groups = groupIdentical(
    attempts.filter(hasPatch).map((a) => ({ ...a, patch: a.snapshot.patch })) as (Contender & {
      patch: string;
    })[],
  );
  const cs = groups.map((g) => g.lead);
  const plan = planBudget(req.budgetUsd, req.attempts);
  const [matrix, grades] = await Promise.all([
    cs.length > 1 ? crossTest(ports, req, cs) : Promise.resolve(null),
    Promise.all(
      cs.map((c) => (rubric ? gradeContender(ports, req, rubric, c, plan.perGradeUsd) : null)),
    ),
  ]);
  const scored = cs.map((c, i) => {
    const grade = grades[i] ? spend.add(grades[i]) : null;
    const cross = matrix ? crossPassRate(matrix, i) : null;
    return scoreOf(c, groups[i]?.members ?? [c.id], cross, grade);
  });
  return { cs, matrix, scored: await withVerifier(ports, req, cs, scored, spend) };
}

function verifierInputs(
  req: TournamentRequest,
  cs: readonly Contender[],
  scored: readonly ScoredCandidate[],
) {
  return scored.map((s, i) => ({
    goal: req.goal,
    patch: cs[i]?.snapshot.patch ?? "",
    ownTestsPass: s.ownTestsPass,
    cross: s.cross,
    rubric: s.rubric,
  }));
}

/**
 * Scores every eligible candidate with the merge verifier when one is wired. A trusted verifier
 * (the ADR-0012 evidence bar) counts in the composite; until then its chance is only reported as
 * `verifierShadow` and selection is unchanged (ADR-0018). A verifier that cannot score leaves the
 * candidate as it was.
 */
async function withVerifier(
  ports: DeliveryPorts,
  req: TournamentRequest,
  cs: readonly Contender[],
  scored: readonly ScoredCandidate[],
  spend: Spend,
): Promise<ScoredCandidate[]> {
  const v = ports.verifier;
  if (!v) return [...scored];
  const inputs = verifierInputs(req, cs, scored);
  const [untrusted, chances] = await Promise.all([
    readinessOf(v),
    Promise.all(inputs.map((x) => (x.ownTestsPass ? v.score(x) : Promise.resolve(null)))),
  ]);
  if (untrusted !== null)
    spend.notes.push(`merge verifier in shadow, not used for selection: ${untrusted}`);
  return scored.map((s, i) => {
    const verifier = chances[i] ?? null;
    if (verifier === null) return s;
    if (untrusted !== null) return { ...s, verifierShadow: verifier };
    const next = { ...s, verifier };
    return { ...next, composite: compositeScore(next) };
  });
}

async function choose(
  ports: DeliveryPorts,
  req: TournamentRequest,
  cs: readonly Contender[],
  scored: readonly ScoredCandidate[],
  spend: Spend,
) {
  const finals = finalists(scored);
  if (finals.length < 2) return { judged: null, selection: select(scored, null) };
  const ids = new Set(finals.map((f) => f.id));
  const plan = planBudget(req.budgetUsd, req.attempts);
  const judged = spend.add(
    await judge(
      ports,
      req,
      cs.filter((c) => ids.has(c.id)),
      plan.judgeUsd,
    ),
  );
  return { judged, selection: select(scored, judged.choice) };
}

async function cleanup(ports: DeliveryPorts, attempts: readonly AttemptResult[], spend: Spend) {
  for (const a of attempts) {
    if (!a.workspace) continue;
    const r = await ports.workspaces.remove(a.workspace);
    if (!r.ok) spend.notes.push(`could not remove ${a.id}'s worktree: ${r.error.message}`);
  }
}

async function adoptWinner(
  ports: DeliveryPorts,
  req: TournamentRequest,
  sha: string | null,
  spend: Spend,
) {
  if (!req.adopt || sha === null) return false;
  const r = await ports.workspaces.adopt(sha);
  if (!r.ok) spend.notes.push(`could not adopt the winner: ${r.error.message}`);
  return r.ok;
}

/**
 * Tournament mode: N independent attempts in separate worktrees, a rubric drafted from the task in
 * parallel, a cross-test matrix, rubric grades, and a blind group-wise judge among the finalists.
 * Adaptive attempts (shadow by default) report where a verifier would have stopped adding
 * attempts; enforce actually stops, when the verifier says it is ready. Worktrees are always removed. Only an infrastructure failure before any attempt is an error;
 * "no winner" is a normal outcome in the report.
 */
export async function runTournament(
  ports: DeliveryPorts,
  req: TournamentRequest,
): Promise<Result<TournamentReport, AdapterError>> {
  const base = await ports.workspaces.baseSha();
  if (!base.ok) return err(base.error);
  const plan = planBudget(req.budgetUsd, req.attempts);
  const spend = new Spend();
  const adaptive = await resolveAdaptive(ports, req);
  const [rubricDraft, run] = await Promise.all([
    draftRubric(ports, req, plan.rubricUsd),
    runAttempts(ports, req, base.value, plan.perAttemptUsd, adaptive),
  ]);
  const attempts = run.attempts;
  try {
    const rubric = spend.add(rubricDraft);
    for (const a of attempts) spend.costUsd += a.costUsd;
    const { cs, matrix, scored } = await scoreContenders(ports, req, attempts, rubric, spend);
    const { judged, selection } = await choose(ports, req, cs, scored, spend);
    const winnerSha = cs.find((c) => c.id === selection.winner)?.snapshot.sha ?? null;
    const adopted = await adoptWinner(ports, req, winnerSha, spend);
    const outcome = { winner: selection.winner, candidates: scored };
    return ok({
      baseSha: base.value,
      attempts: attempts.map(({ workspace: _, ...rest }) => rest),
      rubric,
      matrix,
      candidates: scored,
      judge: judged,
      selection,
      winnerSha,
      adopted,
      costUsd: Math.round(spend.costUsd * 100) / 100,
      notes: spend.notes,
      earlyStop: earlyStopReport(adaptive, req, run, outcome, plan.perAttemptUsd),
    });
  } finally {
    await cleanup(ports, attempts, spend);
  }
}
