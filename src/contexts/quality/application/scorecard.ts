import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import {
  computeScorecard,
  DEFAULT_SCORECARD,
  type PullRecord,
  pullsNeedingCommits,
  type Scorecard,
  type ScorecardConfig,
} from "../domain/scorecard";
import type { ClosedPulls, QualityPorts } from "../ports";

export interface ScorecardReport {
  readonly card: Scorecard;
  /** The PR source hit its cap: older PRs in the window are missing and the numbers are partial. */
  readonly truncated: boolean;
}

/** Fills in commits for the PRs the scorecard inspects, one PR at a time (small queries). */
async function withCommits(
  source: ClosedPulls,
  pulls: readonly PullRecord[],
  config: ScorecardConfig,
): Promise<Result<PullRecord[], AdapterError>> {
  const needed = new Set(pullsNeedingCommits(pulls, config));
  const out: PullRecord[] = [];
  for (const pull of pulls) {
    if (!needed.has(pull.number)) {
      out.push(pull);
      continue;
    }
    const commits = await source.commits(pull.number);
    if (!commits.ok) return commits;
    out.push({ ...pull, commits: commits.value });
  }
  return ok(out);
}

/** Reads closed PRs and spend for the window and computes the W2-18 scorecard. */
export async function buildScorecard(
  ports: QualityPorts,
  options: Partial<Omit<ScorecardConfig, "nowMs">> = {},
): Promise<Result<ScorecardReport, AdapterError>> {
  const config: ScorecardConfig = { ...DEFAULT_SCORECARD, ...options, nowMs: ports.now() };
  const fromMs = config.nowMs - config.windowDays * 86_400_000;
  const [pulls, spend] = await Promise.all([
    ports.pulls.closedSince(fromMs),
    ports.spend.between(fromMs, config.nowMs),
  ]);
  if (!pulls.ok) return pulls;
  if (!spend.ok) return spend;
  const full = await withCommits(ports.pulls, pulls.value.pulls, config);
  if (!full.ok) return full;
  return ok({
    card: computeScorecard(full.value, config, spend.value),
    truncated: pulls.value.truncated,
  });
}
