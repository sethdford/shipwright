import type { Paths } from "../shared/kernel/ports";

export function resolvePaths(env: Readonly<Record<string, string | undefined>>): Paths {
  const home = env.HOME;
  if (!home) throw new Error("HOME is not set; cannot locate Shipwright state");
  return {
    home,
    stateDir: env.SHIPWRIGHT_STATE_DIR ?? `${home}/.shipwright`,
    tmuxSocketName: env.SHIPWRIGHT_TMUX_SOCKET ?? "shipwright",
  };
}
