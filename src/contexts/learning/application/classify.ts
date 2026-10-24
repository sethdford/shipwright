import type { AgentFailureKind } from "../../../shared/kernel/ports";
import { classifyFailure, type FailureClass, failureFingerprint } from "../domain/failure";
import {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  type RetryDecision,
  type RetryPolicy,
} from "../domain/retry";
import { boundEvidence } from "./evidence";

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
  const cls = classifyFailure(input.kind === undefined ? { text } : { kind: input.kind, text });
  const fingerprint = failureFingerprint(cls, text);
  const decision = decideRetry([...input.attempts, { cls, fingerprint }], policy);
  return { class: cls, fingerprint, decision };
}
