import type { Cell, TestMatrix } from "../domain/cross-tests";
import { isTestPath } from "../domain/cross-tests";
import { finalizeRubric, type Rubric, renderRubric, scoreRubric } from "../domain/rubric";
import { blindLabels } from "../domain/selection";
import type { DeliveryPorts, Snapshot, Workspace } from "../ports";
import type { AttemptResult, TournamentRequest } from "./attempts";
import {
  clipPatch,
  GRADER_INSTRUCTIONS,
  Grade,
  JUDGE_INSTRUCTIONS,
  Judgement,
  type JudgementValue,
  RUBRIC_INSTRUCTIONS,
  RubricDraft,
} from "./prompts";

const JUDGE_TIMEOUT_MS = 5 * 60_000;

/** An attempt with a non-empty patch and a live workspace. */
export type Contender = AttemptResult & {
  readonly snapshot: Snapshot;
  readonly workspace: Workspace;
};

export interface Costed<T> {
  readonly value: T;
  readonly costUsd: number;
  readonly note: string | null;
}

export async function draftRubric(
  ports: DeliveryPorts,
  req: TournamentRequest,
  budgetUsd: number,
): Promise<Costed<Rubric | null>> {
  const r = await ports.agent.decide({
    instructions: RUBRIC_INSTRUCTIONS,
    data: req.goal,
    schema: RubricDraft,
    model: req.judgeModel,
    effort: "medium",
    maxBudgetUsd: budgetUsd,
    timeoutMs: JUDGE_TIMEOUT_MS,
  });
  if (!r.ok)
    return { value: null, costUsd: r.error.usage.costUsd, note: `rubric: ${r.error.kind}` };
  const rubric = finalizeRubric(r.value.value.criteria);
  const costUsd = r.value.usage.costUsd;
  if (typeof rubric === "string")
    return { value: null, costUsd, note: `rubric unusable: ${rubric}` };
  return { value: rubric, costUsd, note: null };
}

export async function gradeContender(
  ports: DeliveryPorts,
  req: TournamentRequest,
  rubric: Rubric,
  c: Contender,
  budgetUsd: number,
): Promise<Costed<number | null>> {
  const data = `## Task\n${req.goal}\n\n## Rubric\n${renderRubric(rubric)}\n\n## Diff\n${clipPatch(c.snapshot.patch)}`;
  const r = await ports.agent.decide({
    instructions: GRADER_INSTRUCTIONS,
    data,
    schema: Grade,
    model: req.judgeModel,
    effort: "medium",
    maxBudgetUsd: budgetUsd,
    timeoutMs: JUDGE_TIMEOUT_MS,
  });
  if (!r.ok)
    return { value: null, costUsd: r.error.usage.costUsd, note: `grade ${c.id}: ${r.error.kind}` };
  const met: Record<string, boolean> = {};
  for (const v of r.value.value.verdicts) met[v.id] = v.met;
  return { value: scoreRubric(rubric, met), costUsd: r.value.usage.costUsd, note: null };
}

async function crossCell(
  ports: DeliveryPorts,
  req: TournamentRequest,
  patch: Contender,
  suite: Contender,
): Promise<Cell> {
  const tests = suite.snapshot.files.filter(isTestPath);
  if (tests.length === 0) return "skip";
  const put = await ports.workspaces.overlay(patch.workspace, suite.snapshot.sha, tests);
  let cell: Cell = "skip";
  if (put.ok) {
    const run = await ports.commands.run(req.testCommand, patch.workspace.path, req.testTimeoutMs);
    cell = run.ok ? (run.value.passed ? "pass" : "fail") : "skip";
  }
  const back = await ports.workspaces.reset(patch.workspace, patch.snapshot.sha);
  // A workspace that cannot be reset would contaminate the next cell: stop scoring this row.
  if (!back.ok) throw new Error(`could not reset ${patch.id}: ${back.error.message}`);
  return cell;
}

async function crossRow(
  ports: DeliveryPorts,
  req: TournamentRequest,
  cs: readonly Contender[],
  p: number,
) {
  const row: Cell[] = [];
  for (const [s, suite] of cs.entries()) {
    const self = cs[p] as Contender;
    if (s === p) row.push(self.ownTests?.passed ? "pass" : "fail");
    else row.push(await crossCell(ports, req, self, suite));
  }
  return row;
}

/** Runs each contender's tests against every other contender's patch, one row per workspace. */
export async function crossTest(
  ports: DeliveryPorts,
  req: TournamentRequest,
  cs: readonly Contender[],
): Promise<TestMatrix> {
  const rows = await Promise.all(
    cs.map((_, p) => crossRow(ports, req, cs, p).catch(() => cs.map((): Cell => "skip"))),
  );
  return { ids: cs.map((c) => c.id), cells: rows };
}

export interface JudgeResult {
  /** Contender id, "none", or null when the judge failed or answered with an unknown label. */
  readonly choice: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly judgement: JudgementValue | null;
}

export async function judge(
  ports: DeliveryPorts,
  req: TournamentRequest,
  finalists: readonly Contender[],
  budgetUsd: number,
): Promise<Costed<JudgeResult>> {
  const labels = blindLabels(
    finalists.map((c) => c.id),
    ports.random,
  );
  const byId = new Map(finalists.map((c) => [c.id, c]));
  const blocks = [...labels].map(
    ([label, id]) => `## Candidate ${label}\n${clipPatch(byId.get(id)?.snapshot.patch ?? "")}`,
  );
  const r = await ports.agent.decide({
    instructions: JUDGE_INSTRUCTIONS,
    data: [`## Task\n${req.goal}`, ...blocks].join("\n\n"),
    schema: Judgement,
    model: req.judgeModel,
    effort: "high",
    maxBudgetUsd: budgetUsd,
    timeoutMs: JUDGE_TIMEOUT_MS,
  });
  const labelMap = Object.fromEntries(labels);
  if (!r.ok) {
    const value = { choice: null, labels: labelMap, judgement: null };
    return { value, costUsd: r.error.usage.costUsd, note: `judge: ${r.error.kind}` };
  }
  const raw = r.value.value.choice.trim();
  const choice = raw.toLowerCase() === "none" ? "none" : (labels.get(raw.toUpperCase()) ?? null);
  const note = choice === null ? `judge answered an unknown candidate "${raw}"` : null;
  const value = { choice, labels: labelMap, judgement: r.value.value };
  return { value, costUsd: r.value.usage.costUsd, note };
}
