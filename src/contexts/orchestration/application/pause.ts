import type { AdapterError } from "../../../shared/kernel/ports";
import { ok, type Result } from "../../../shared/kernel/result";
import { type PauseStatus, pauseStatus } from "../domain/pause";
import type { SafetyPorts } from "../ports";

export interface PauseOptions {
  /** False in no-GitHub mode: only the local flag is checked. */
  readonly github: boolean;
}

export async function readPause(
  ports: Pick<SafetyPorts, "pauseFlag" | "pauseLabel" | "now">,
  options: PauseOptions,
): Promise<Result<PauseStatus, AdapterError>> {
  const flag = await ports.pauseFlag.read();
  if (!flag.ok) return flag;
  if (!options.github) return ok(pauseStatus(flag.value, null, ports.now()));
  const labelled = await ports.pauseLabel.labelled();
  if (!labelled.ok) return labelled;
  return ok(pauseStatus(flag.value, labelled.value, ports.now()));
}

export function pause(
  ports: Pick<SafetyPorts, "pauseFlag" | "now">,
  reason: string,
): Promise<Result<void, AdapterError>> {
  return ports.pauseFlag.write(reason, new Date(ports.now()).toISOString());
}

/** Clears the local flag only; a `shipwright:pause` label must be removed on GitHub. */
export function resume(ports: Pick<SafetyPorts, "pauseFlag">): Promise<Result<void, AdapterError>> {
  return ports.pauseFlag.clear();
}
