export {
  type BreakerPolicy,
  type BreakerState,
  breakerAllowsDispatch,
  DEFAULT_BREAKER_POLICY,
  describeBreaker,
  evaluateBreaker,
  type RunOutcome,
  type RunRecord,
} from "./domain/breaker";
export type { RunHistory } from "./ports";
