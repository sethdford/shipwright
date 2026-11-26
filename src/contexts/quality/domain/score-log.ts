import type { ChangeSignals } from "./change-features";
import type { PullRecord } from "./scorecard";

/**
 * The verifier's score log, joined to outcomes. Pure.
 *
 * History has no execution signals: a closed PR does not say whether its tests passed in the run,
 * what the rubric gave it or what the critic thought. So `verify score` records them, keyed by the
 * branch the PR is opened from, and training reads them back for each labelled PR. Without this
 * the critic's weight could never move off its prior, because every historical example had a
 * critic feature of 0.
 */
export interface ScoreRecord {
  readonly atMs: number;
  readonly branch: string;
  readonly headSha: string;
  readonly probability: number;
  readonly signals: ChangeSignals;
}

/** A score counts for a PR when it was taken from at most this long before the PR opened. */
export const JOIN_LEAD_MS = 6 * 3_600_000;

/**
 * The run's signals for one PR: the latest score taken on its head branch between shortly before
 * it opened and when it closed. Null when the PR was never scored (all of history before the log).
 */
export function signalsFor(
  pull: PullRecord,
  records: readonly ScoreRecord[],
): ChangeSignals | null {
  const from = pull.createdAtMs - JOIN_LEAD_MS;
  const to = pull.closedAtMs ?? Number.POSITIVE_INFINITY;
  let best: ScoreRecord | null = null;
  for (const r of records) {
    if (r.branch !== pull.headRef || r.atMs < from || r.atMs > to) continue;
    if (best === null || r.atMs > best.atMs) best = r;
  }
  return best?.signals ?? null;
}
