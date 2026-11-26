import { indexable, isTestPath } from "./model";

/** A merged change turned into a localization case: the title is the task, its source files the answer. */
export interface LocalizationCase {
  readonly id: string;
  readonly parent: string;
  readonly task: string;
  readonly gold: readonly string[];
}

export interface CommitFacts {
  readonly sha: string;
  readonly parent: string;
  readonly subject: string;
  readonly body: string;
  readonly files: readonly string[];
}

/** Changes this large are refactors or merges of many things; their "answer" says little about localization. */
const MAX_GOLD = 40;
const SKIP_TITLE = /^(docs|chore|ci|build|style|revert|merge)\b/i;

/** The PR title of a merge commit (`Merge pull request #N from …` then the title) or a squash commit (`… (#N)`). */
export function titleOf(subject: string, body: string): string {
  if (subject.startsWith("Merge pull request #"))
    return (
      body
        .split("\n")
        .find((l) => l.trim().length > 0)
        ?.trim() ?? ""
    );
  return /\(#\d+\)$/.test(subject) ? subject : "";
}

/**
 * Turns history into cases. Only PR merges count; docs, chores and CI changes are skipped, as are tests in the
 * answer (localization means finding the code to change). Leak-free by construction: each case is scored on a
 * model of its parent commit, where the change does not exist yet.
 */
export function casesOf(commits: readonly CommitFacts[]): LocalizationCase[] {
  const out: LocalizationCase[] = [];
  for (const c of commits) {
    const task = titleOf(c.subject, c.body);
    if (task.length === 0 || SKIP_TITLE.test(task)) continue;
    const gold = c.files.filter((p) => indexable(p) && !isTestPath(p));
    if (gold.length === 0 || gold.length > MAX_GOLD) continue;
    out.push({ id: c.sha.slice(0, 12), parent: c.parent, task, gold });
  }
  return out;
}

export interface CaseResult {
  readonly id: string;
  readonly task: string;
  /** Gold files that existed at the parent (a new file cannot be found before it exists). */
  readonly findable: readonly string[];
  /** 1-based rank of the first gold file in the answer, or null. */
  readonly firstHit: number | null;
  /** Share of findable gold files in the top 10. */
  readonly recall10: number;
}

export function scoreCase(
  c: LocalizationCase,
  exists: (p: string) => boolean,
  ranked: readonly string[],
): CaseResult {
  const findable = c.gold.filter(exists);
  const at = ranked.findIndex((p) => findable.includes(p));
  const top10 = ranked.slice(0, 10);
  return {
    id: c.id,
    task: c.task,
    findable,
    firstHit: at < 0 ? null : at + 1,
    recall10:
      findable.length === 0
        ? 0
        : findable.filter((p) => top10.includes(p)).length / findable.length,
  };
}

export interface EvalSummary {
  readonly cases: number;
  readonly acc1: number;
  readonly acc5: number;
  readonly acc10: number;
  readonly recall10: number;
}

/** Hit rates over the cases that had something findable. */
export function summarize(results: readonly CaseResult[]): EvalSummary {
  const scored = results.filter((r) => r.findable.length > 0);
  const n = scored.length || 1;
  const acc = (k: number) =>
    scored.filter((r) => r.firstHit !== null && r.firstHit <= k).length / n;
  return {
    cases: scored.length,
    acc1: acc(1),
    acc5: acc(5),
    acc10: acc(10),
    recall10: scored.reduce((a, r) => a + r.recall10, 0) / n,
  };
}
