import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { DEFAULT_INTAKE_POLICY, evaluateIntake, type IntakeVerdict } from "../domain/intake";
import type { SafetyPorts } from "../ports";

/**
 * Whether automation may file an issue titled `title` (null: check only the cap).
 * `label` marks auto-filed issues (default: the policy's `auto-patrol`).
 */
export async function checkIntake(
  ports: Pick<SafetyPorts, "issues">,
  title: string | null,
  label: string = DEFAULT_INTAKE_POLICY.autoLabel,
): Promise<Result<IntakeVerdict, AdapterError>> {
  const open = await ports.issues.open();
  return open.ok
    ? ok(evaluateIntake(open.value, title, { ...DEFAULT_INTAKE_POLICY, autoLabel: label }))
    : open;
}
