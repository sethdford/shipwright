export {
  type AcceptancePorts,
  loadManifest,
  type Materialized,
  materialize,
  type RedReport,
  type RunOptions,
  type TestRun,
  verifyRed,
} from "./application/acceptance";
export {
  type GreenReport,
  type IntegrityMode,
  type LockResult,
  lockTests,
  verifyGreen,
} from "./application/gate";
export { extractBlocks, MANIFEST_LABEL, parseAnswer } from "./domain/agent-output";
export { checkIntegrity, type FileChange, parseDiff, type Violation } from "./domain/integrity";
export { type AcceptanceLock, parseLock } from "./domain/lock";
export { type AcceptanceManifest, MANIFEST_LIMITS, parseManifest } from "./domain/manifest";
export {
  chooseTemplate,
  deriveTemplate,
  type RunTemplate,
  renderRun,
  templateProblem,
} from "./domain/run-command";
export { greenVerdict, REASON_HELP, type RunVerdict, redVerdict } from "./domain/run-verdict";
export { isTestPath, testPathProblem } from "./domain/test-path";
export type { AcceptanceWorkspace, ArtifactStore, TestExecutor } from "./ports";
