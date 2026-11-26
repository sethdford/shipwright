export {
  compareEval,
  type EvalSummary,
  type RatchetReport,
  summarizeEval,
} from "./application/eval";
export { buildScorecard, type ScorecardReport } from "./application/scorecard";
export { type EvalResults, type EvalRun, parseEvalResults, scoreRuns } from "./domain/eval-results";
export { choose, passHatK } from "./domain/pass-k";
export {
  type CaseScore,
  decideRatchet,
  median,
  minWinsForSuperiority,
  NO_VETOES,
  RATCHET_RULE,
  type RatchetVerdict,
  signTestP,
  type Vetoes,
} from "./domain/ratchet";
export {
  computeScorecard,
  DEFAULT_SCORECARD,
  type PullCommit,
  type PullRecord,
  pullsNeedingCommits,
  type Scorecard,
  type ScorecardConfig,
} from "./domain/scorecard";
export type { ClosedPulls, QualityPorts, SpendSource } from "./ports";
