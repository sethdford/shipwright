import { isAbsolute } from "node:path";
import type { Paths } from "../shared/kernel/ports";

export function resolvePaths(env: Readonly<Record<string, string | undefined>>): Paths {
  const home = env.HOME;
  if (!home) throw new Error("HOME is not set; cannot locate Shipwright state");
  if (!isAbsolute(home)) throw new Error(`HOME must be an absolute path, got "${home}"`);
  const stateDir = env.SHIPWRIGHT_STATE_DIR || `${home}/.shipwright`;
  if (!isAbsolute(stateDir)) {
    throw new Error(`Shipwright state dir must be an absolute path, got "${stateDir}"`);
  }
  return { home, stateDir, tmuxSocketName: env.SHIPWRIGHT_TMUX_SOCKET || "shipwright" };
}
