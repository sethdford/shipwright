import type { AgentFailureKind } from "../../../shared/kernel/ports";
import { classifyFailure, type FailureClass, failureFingerprint } from "../domain/failure";
import {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  type RetryDecision,
  type RetryPolicy,
} from "../domain/retry";
import { boundEvidence, dropTestTitles } from "./evidence";

export interface ClassifyInput {
  readonly kind?: AgentFailureKind;
  readonly text: string;
  readonly attempts: readonly Attempt[];
}

export interface ClassifyResult {
  readonly class: FailureClass;
  readonly fingerprint: string;
  readonly decision: RetryDecision;
}

/** Pure composition: classify this run, then decide with the prior attempts. Writes nothing. */
export function classifyAndDecide(
  input: ClassifyInput,
  policy: RetryPolicy = DEFAULT_RETRY_POLICY,
): ClassifyResult {
  const text = boundEvidence(input.text);
  // The rules never see test-runner title lines (#8696). The fingerprint keeps them: bun prints the
  // `(fail)` title after the assertion, so two different failing tests still group apart.
  const rulesText = dropTestTitles(text);
  const cls = classifyFailure(
    input.kind === undefined ? { text: rulesText } : { kind: input.kind, text: rulesText },
  );
  const fingerprint = failureFingerprint(cls, text);
  const decision = decideRetry([...input.attempts, { cls, fingerprint }], policy);
  return { class: cls, fingerprint, decision };
}
