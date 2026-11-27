export { type MineRequest, type MineResult, mineHoldout } from "./application/bench/mine";
export { type BenchReport, buildBenchReport, type TaskLine } from "./application/bench/report";
export { type RunRequest, type RunSummary, runBenchmark } from "./application/bench/run";
export { type OracleCheck, oracleOk, validateTask } from "./application/bench/validate";
export { CANDIDATE_TITLE, candidateVerifier } from "./application/candidate-verifier";
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
export { type ProofReport, type ProofRequest, runProof } from "./application/proof";
export { buildScorecard, type ScorecardReport } from "./application/scorecard";
export type { LabelSummary } from "./application/verifier-labels";
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
export * from "./domain/bench";
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
export {
  measureSurvival,
  parseAddedLines,
  SURVIVAL_RULE,
  type SurvivalInput,
  type SurvivalSample,
} from "./domain/code-survival";
export { type EvalResults, type EvalRun, parseEvalResults, scoreRuns } from "./domain/eval-results";
export { DEFAULT_LABELS, type LabelConfig } from "./domain/outcome-labels";
export { choose, passHatK } from "./domain/pass-k";
export {
  type CliRun,
  type Flow,
  NO_CONFIG,
  PROOF_LIMITS,
  type ProofConfig,
  parseProofConfig,
  type Step,
} from "./domain/proof/config";
export { type AppProfile, detectApp, MARKER_FILES, type RepoFacts } from "./domain/proof/detect";
export { type ProofPlan, planProof, type WebPlan } from "./domain/proof/plan";
export { redact } from "./domain/proof/redact";
export { PROOF_MARKER, renderProofSection } from "./domain/proof/render";
export type {
  Capture,
  CliResult,
  FlowResult,
  HttpError,
  ProofMode,
  ProofVerdict,
  StepOutcome,
  WebResult,
} from "./domain/proof/result";
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
export type { ScoreRecord } from "./domain/score-log";
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
  ArmOutcome,
  ArmRunner,
  BenchFactory,
  BenchGrader,
  BenchPorts,
  BenchStore,
  BenchWorkspaces,
  ClosedPulls,
  HoldoutSource,
  LocalChange,
  PullFiles,
  QualityPorts,
  ScoreLog,
  SpendSource,
  StoredVerifier,
  SurvivalSource,
  VerifierPorts,
  VerifierStore,
} from "./ports";
export type {
  AppLauncher,
  BrowseRequest,
  BrowserDriver,
  CliExecutor,
  ProofArtifacts,
  ProofFile,
  ProofPorts,
  ProofPublisher,
  ProofRepo,
  RunningApp,
  StartOutcome,
  StartRequest,
} from "./proof-ports";
