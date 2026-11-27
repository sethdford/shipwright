/** The pre-PR self-scan use case (ADR-0017): scan the branch's added lines before it is pushed. */
import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { type ScanFinding, type ScanVerdict, scanDiff, scanVerdict } from "../domain/steward-scan";
import type { ChangeDiff } from "../ports";

export interface ScanReport {
  readonly verdict: ScanVerdict;
  readonly findings: readonly ScanFinding[];
}

export async function scanChange(
  change: ChangeDiff,
  baseRef: string,
): Promise<Result<ScanReport, AdapterError>> {
  const d = await change.diff(baseRef);
  if (!d.ok) return d;
  const findings = scanDiff(d.value.patch);
  return ok({ verdict: scanVerdict(findings), findings });
}
