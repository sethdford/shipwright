import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { evaluateIntake, type IntakeVerdict } from "../domain/intake";
import type { SafetyPorts } from "../ports";

/** Whether automation may file an issue titled `title` (null: check only the cap). */
export async function checkIntake(
  ports: Pick<SafetyPorts, "issues">,
  title: string | null,
): Promise<Result<IntakeVerdict, AdapterError>> {
  const open = await ports.issues.open();
  return open.ok ? ok(evaluateIntake(open.value, title)) : open;
}
