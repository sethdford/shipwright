import type { Lesson } from "./lesson";

/** One failed run, already classified (the ADR-0009 classifier in `learning`). */
export interface FailedRun {
  readonly source: string;
  readonly failureClass: string;
  readonly fingerprint: string;
  readonly log: string;
}

/** A recurring failure that no lesson covers yet: the input to a lesson draft. */
export interface Candidate {
  readonly failureClass: string;
  readonly fingerprint: string;
  readonly count: number;
  /** Every run that failed this way, in input order. */
  readonly sources: readonly string[];
  /** The log of the last run in the cluster, used as evidence. */
  readonly log: string;
}

/**
 * Classes a lesson can change. Setup, credentials, quota, contamination and refusals are fixed outside the agent's
 * prompt (ADR-0009 rule 10; ADR-0007), so a lesson about them would only teach the agent to work around a gate.
 */
export const LEARNABLE_CLASSES: readonly string[] = [
  "execution",
  "unknown",
  "max_turns",
  "timeout",
  "schema",
  "truncated",
  "invalid_input",
];

export interface MineOptions {
  /** A failure must recur at least this often: a one-off is noise, not a lesson (default 2). */
  readonly minCount: number;
  /** At most this many candidates per mining pass, most frequent first (default 3). */
  readonly limit: number;
}

export const DEFAULT_MINE: MineOptions = { minCount: 2, limit: 3 };

/** Groups failed runs by fingerprint and keeps the recurring, learnable, uncovered ones, most frequent first. */
export function mineCandidates(
  runs: readonly FailedRun[],
  existing: readonly Lesson[],
  opts: MineOptions = DEFAULT_MINE,
): readonly Candidate[] {
  const covered = new Set(
    existing.flatMap((l) => (l.fingerprint === undefined ? [] : [l.fingerprint])),
  );
  const groups = new Map<string, { first: number; runs: FailedRun[] }>();
  runs.forEach((run, i) => {
    if (!LEARNABLE_CLASSES.includes(run.failureClass) || covered.has(run.fingerprint)) return;
    const g = groups.get(run.fingerprint) ?? { first: i, runs: [] };
    g.runs.push(run);
    groups.set(run.fingerprint, g);
  });
  return [...groups.values()]
    .filter((g) => g.runs.length >= opts.minCount)
    .sort((a, b) => b.runs.length - a.runs.length || a.first - b.first)
    .slice(0, opts.limit)
    .map((g) => {
      const last = g.runs[g.runs.length - 1] as FailedRun;
      return {
        failureClass: last.failureClass,
        fingerprint: last.fingerprint,
        count: g.runs.length,
        sources: g.runs.map((r) => r.source),
        log: last.log,
      };
    });
}
