import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import {
  computeScorecard,
  DEFAULT_SCORECARD,
  type Scorecard,
  type ScorecardConfig,
} from "../domain/scorecard";
import type { QualityPorts } from "../ports";

export interface ScorecardReport {
  readonly card: Scorecard;
  /** The PR source hit its cap: older PRs in the window are missing and the numbers are partial. */
  readonly truncated: boolean;
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
  return ok({
    card: computeScorecard(pulls.value.pulls, config, spend.value),
    truncated: pulls.value.truncated,
  });
}
