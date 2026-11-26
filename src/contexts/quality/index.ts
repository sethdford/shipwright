export {
  CRITIC_CHECKS,
  CRITIC_INSTRUCTIONS,
  type CriticResult,
  runCritic,
} from "./application/critic";
export {
  compareEval,
  type EvalSummary,
  type RatchetReport,
  summarizeEval,
} from "./application/eval";
export { buildScorecard, type ScorecardReport } from "./application/scorecard";
export {
  type CandidateRequest,
  type ScoreReport,
  type ScoreRequest,
  scoreCandidate,
  scoreChange,
} from "./application/verifier-score";
export {
  readVerifier,
  type TrainedExample,
  type TrainingReport,
  type TrainOptions,
  trainVerifier,
} from "./application/verifier-train";
export type { Calibration } from "./domain/calibration";
export {
  type ChangeSignals,
  type ChangeSummary,
  extractFeatures,
  FEATURES,
  type Feature,
  type FeatureVector,
  type FileChange,
  NO_SIGNALS,
} from "./domain/change-features";
export { type EvalResults, type EvalRun, parseEvalResults, scoreRuns } from "./domain/eval-results";
export { DEFAULT_LABELS, type LabelConfig } from "./domain/outcome-labels";
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
  isTestRun,
  type PullCommit,
  type PullRecord,
  pullsNeedingCommits,
  type Scorecard,
  type ScorecardConfig,
} from "./domain/scorecard";
export { PRIOR_MODEL, predict, type VerifierModel } from "./domain/verifier-model";
export {
  type Decision,
  type Evidence,
  GATE_RULE,
  NO_EVIDENCE,
  type Verdict,
  type VerifierMode,
} from "./domain/verifier-policy";
export type {
  ClosedPulls,
  LocalChange,
  PullFiles,
  QualityPorts,
  SpendSource,
  StoredVerifier,
  VerifierPorts,
  VerifierStore,
} from "./ports";
