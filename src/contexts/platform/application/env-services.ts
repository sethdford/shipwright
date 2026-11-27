import type { EnvRecipe, EnvService } from "../domain/env-recipe";
import type { EnvPorts } from "../ports";
import { runCommands, type SetupFailure } from "./env-run";

export interface ServiceOutcome {
  readonly name: string;
  readonly status: "ready" | "start-failed" | "not-ready" | "stopped" | "stop-failed" | "no-stop";
  readonly failure?: SetupFailure;
}

const START_TIMEOUT_MS = 300_000;
const PROBE_TIMEOUT_MS = 10_000;

async function waitReady(
  ports: EnvPorts,
  s: EnvService,
  dir: string,
  env: Readonly<Record<string, string>>,
): Promise<SetupFailure | null> {
  const deadline = ports.now() + s.readyTimeoutSec * 1000;
  let last: SetupFailure | null = null;
  while (ports.now() < deadline) {
    last = await runCommands(ports, [s.ready], dir, env, PROBE_TIMEOUT_MS);
    if (last === null) return null;
    await ports.sleep(1000);
  }
  return last ?? { command: s.ready, exitCode: 1, timedOut: true, tail: "" };
}

/** Starts the recipe's services in order and waits for each to answer; stops at the first that does not. */
export async function servicesUp(
  ports: EnvPorts,
  recipe: EnvRecipe,
  dir: string,
  only?: string,
): Promise<ServiceOutcome[]> {
  const out: ServiceOutcome[] = [];
  for (const s of recipe.services.filter((x) => only === undefined || x.name === only)) {
    const started = await runCommands(ports, [s.start], dir, recipe.env, START_TIMEOUT_MS);
    if (started) return [...out, { name: s.name, status: "start-failed", failure: started }];
    const ready = await waitReady(ports, s, dir, recipe.env);
    if (ready) return [...out, { name: s.name, status: "not-ready", failure: ready }];
    out.push({ name: s.name, status: "ready" });
  }
  return out;
}

/** Stops services in reverse order; keeps going past failures so nothing is left running by accident. */
export async function servicesDown(
  ports: EnvPorts,
  recipe: EnvRecipe,
  dir: string,
  only?: string,
): Promise<ServiceOutcome[]> {
  const out: ServiceOutcome[] = [];
  for (const s of [...recipe.services]
    .reverse()
    .filter((x) => only === undefined || x.name === only)) {
    if (!s.stop) {
      out.push({ name: s.name, status: "no-stop" });
      continue;
    }
    const stopped = await runCommands(ports, [s.stop], dir, recipe.env, START_TIMEOUT_MS);
    out.push(
      stopped
        ? { name: s.name, status: "stop-failed", failure: stopped }
        : { name: s.name, status: "stopped" },
    );
  }
  return out;
}
