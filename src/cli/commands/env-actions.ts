import {
  computeKey,
  type EnvPorts,
  hydrate,
  initEnvironment,
  loadRecipe,
  pruneCache,
  renderRecipe,
  servicesDown,
  servicesUp,
} from "../../contexts/platform";
import type { CliIO } from "../command";
import { type EnvFlags, effortOf, intIn, refOf, usdIn } from "./env-flags";
import { renderHydrate, renderInit, renderServices } from "./env-render";

/** Shared location flags: --root (the trusted repo), --dir (the checkout), --ref, --worktree. */
export function locate(f: EnvFlags, detect = true) {
  const root = f.values["--root"] ?? ".";
  const ref = refOf(f.values["--ref"]);
  return {
    root,
    dir: f.values["--dir"] ?? root,
    ref,
    worktree: f.switches.has("--worktree"),
    detect: detect && !f.switches.has("--no-detect"),
  };
}

const json = (io: CliIO, value: unknown) => io.out(JSON.stringify(value, null, 2));

export async function hydrateAction(io: CliIO, ports: EnvPorts, f: EnvFlags): Promise<number> {
  const where = locate(f);
  const o = await hydrate(ports, {
    ...where,
    restoreOnly: f.switches.has("--restore-only"),
    trustWorktree: f.switches.has("--trust-worktree"),
  });
  if (f.switches.has("--json")) json(io, o);
  else renderHydrate(io, o, f.switches.has("--quiet"));
  return o.status === "failed" || o.status === "invalid" ? 1 : 0;
}

/** Loads the recipe or prints why not; null means the caller returns `code`. */
async function recipeOrExit(io: CliIO, ports: EnvPorts, f: EnvFlags) {
  const loaded = await loadRecipe(ports, locate(f));
  if (!loaded.ok) {
    const e = loaded.error;
    io.err(
      e.kind === "invalid"
        ? `✗ recipe rejected:\n  - ${e.problems.join("\n  - ")}`
        : `✗ ${e.message}`,
    );
    return null;
  }
  if (loaded.value === null) io.err("✗ no recipe (.shipwright/env.json) and nothing detectable");
  return loaded.value;
}

export async function showAction(io: CliIO, ports: EnvPorts, f: EnvFlags): Promise<number> {
  const got = await recipeOrExit(io, ports, f);
  if (got === null) return 1;
  if (f.switches.has("--json")) json(io, got);
  else io.out(`# ${got.origin} recipe\n${renderRecipe(got.recipe).trimEnd()}`);
  return 0;
}

/** The cache key and directory, for `actions/cache` and scripts. */
export async function keyAction(io: CliIO, ports: EnvPorts, f: EnvFlags): Promise<number> {
  const got = await recipeOrExit(io, ports, f);
  if (got === null) return 1;
  const where = locate(f);
  const key = await computeKey(ports, got.recipe, where.dir);
  const repo = await ports.source.repoId(where.root);
  if (!key.ok || !repo.ok) {
    io.err("✗ cannot compute the cache key");
    return 1;
  }
  const out = {
    key: key.value,
    repoId: repo.value,
    cacheDir: ports.cache.dirFor(repo.value, key.value),
    origin: got.origin,
    paths: got.recipe.cache,
  };
  if (f.switches.has("--json")) json(io, out);
  else io.out(out.key);
  return 0;
}

export async function servicesAction(
  io: CliIO,
  ports: EnvPorts,
  f: EnvFlags,
  up: boolean,
): Promise<number> {
  const got = await recipeOrExit(io, ports, f);
  if (got === null) return 1;
  if (got.origin === "worktree" && !f.switches.has("--trust-worktree")) {
    io.err("✗ the recipe is not committed: commit it, or pass --trust-worktree");
    return 1;
  }
  const dir = locate(f).dir;
  const only = f.positional[0];
  const outcomes = up
    ? await servicesUp(ports, got.recipe, dir, only)
    : await servicesDown(ports, got.recipe, dir, only);
  if (f.switches.has("--json")) json(io, outcomes);
  else renderServices(io, outcomes);
  const bad = outcomes.some(
    (s) => s.status === "start-failed" || s.status === "not-ready" || s.status === "stop-failed",
  );
  return bad ? 1 : 0;
}

export async function listAction(
  io: CliIO,
  ports: EnvPorts,
  f: EnvFlags,
  prune: boolean,
): Promise<number | string> {
  const repo = await ports.source.repoId(locate(f).root);
  if (!repo.ok) {
    io.err(`✗ cannot identify the repository: ${repo.error.message}`);
    return 1;
  }
  const keep = intIn("--keep", f.values["--keep"], 3, 0, 1000);
  const age = intIn("--max-age-days", f.values["--max-age-days"], 30, 1, 3650);
  if (typeof keep === "string") return keep;
  if (typeof age === "string") return age;
  const entries = prune
    ? await pruneCache(ports, repo.value, {
        keep,
        maxAgeDays: age,
        dryRun: f.switches.has("--dry-run"),
      })
    : await ports.cache.list(repo.value);
  if (!entries.ok) {
    io.err(`✗ ${entries.error.message}`);
    return 1;
  }
  if (f.switches.has("--json")) json(io, entries.value);
  else {
    const verb = prune ? (f.switches.has("--dry-run") ? "would remove " : "removed ") : "";
    for (const e of entries.value)
      io.out(`${verb}${e.key}  ${(e.bytes / 1e6).toFixed(1)} MB  used ${e.usedAt}`);
    if (entries.value.length === 0)
      io.out(prune ? "· nothing to prune" : "· no cached environments");
  }
  return 0;
}

export async function initAction(
  io: CliIO,
  ports: EnvPorts,
  f: EnvFlags,
): Promise<number | string> {
  const where = locate(f, false);
  const attempts = intIn("--attempts", f.values["--attempts"], 3, 1, 10);
  const budget = usdIn("--budget", f.values["--budget"], 2);
  const effort = effortOf(f.values["--effort"]);
  if (typeof attempts === "string") return attempts;
  if (typeof budget === "string") return budget;
  if (typeof effort === "string") return effort;
  const write = !f.switches.has("--no-write");
  const o = await initEnvironment(ports, {
    root: where.root,
    ref: where.ref,
    useAgent: !f.switches.has("--no-agent"),
    attempts,
    model: f.values["--model"] ?? "sonnet",
    effort: effort.effort,
    maxBudgetUsd: budget,
    agentTimeoutMs: 15 * 60_000,
    smokeTimeoutMs: 10 * 60_000,
    write,
  });
  if (f.switches.has("--json")) json(io, o);
  else renderInit(io, o, write);
  return o.ready ? 0 : 1;
}
