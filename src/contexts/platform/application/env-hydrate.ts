import type { EnvRecipe } from "../domain/env-recipe";
import type { EnvPorts, RecipeOrigin } from "../ports";
import {
  computeKey,
  loadRecipe,
  type RecipeQuery,
  runCommands,
  type SetupFailure,
} from "./env-run";

export interface HydrateOptions extends RecipeQuery {
  /** Restore a cached environment only; never run setup (for checkouts that hold agent edits). */
  readonly restoreOnly: boolean;
  /** Run a working-tree recipe even though it is not committed (operator opt-in). */
  readonly trustWorktree: boolean;
}

export type HydrateStatus =
  /** Restored from the cache. */
  | "hit"
  /** Setup ran and the result was cached. */
  | "built"
  /** Cache miss under --restore-only: nothing changed. */
  | "skipped"
  /** No recipe and nothing detectable. */
  | "no-recipe"
  | "invalid"
  | "failed";

export interface HydrateOutcome {
  readonly status: HydrateStatus;
  readonly key?: string;
  readonly origin?: RecipeOrigin;
  readonly durationMs: number;
  readonly problems?: readonly string[];
  readonly failure?: SetupFailure;
  /** Set when the build worked but the cache could not keep it (the checkout is still ready). */
  readonly saveError?: string;
}

/**
 * Makes `dir` ready to build and test (ADR-0020): restore the cached environment whose key
 * matches the checkout's lockfiles and toolchain, or run the recipe's setup and cache what it
 * produced. Only a committed or detected recipe runs setup, unless the operator trusts the
 * working tree; a restore never runs anything.
 */
type Resolved =
  | { ok: true; recipe: EnvRecipe; origin: RecipeOrigin; repoId: string; key: string }
  | { ok: false; outcome: Omit<HydrateOutcome, "durationMs"> };

/** The recipe, the repository id and the cache key for this checkout. */
async function resolve(ports: EnvPorts, o: HydrateOptions): Promise<Resolved> {
  const loaded = await loadRecipe(ports, o);
  if (!loaded.ok) {
    const e = loaded.error;
    return e.kind === "invalid"
      ? { ok: false, outcome: { status: "invalid", problems: e.problems } }
      : { ok: false, outcome: { status: "failed", problems: [e.message] } };
  }
  if (loaded.value === null) return { ok: false, outcome: { status: "no-recipe" } };
  const { recipe, origin } = loaded.value;
  const repoId = await ports.source.repoId(o.root);
  if (!repoId.ok)
    return { ok: false, outcome: { status: "failed", origin, problems: [repoId.error.message] } };
  const key = await computeKey(ports, recipe, o.dir);
  if (!key.ok)
    return {
      ok: false,
      outcome: { status: "failed", origin, problems: ["cannot compute the cache key"] },
    };
  return { ok: true, recipe, origin, repoId: repoId.value, key: key.value };
}

/** Restores a matching entry; null when there is none (or it could not be restored). */
async function tryRestore(
  ports: EnvPorts,
  r: Extract<Resolved, { ok: true }>,
  dir: string,
): Promise<string | null | "hit"> {
  // Nothing to keep (Go, Cargo: their caches live outside the checkout): setup is the only way.
  if (r.recipe.cache.length === 0) return null;
  const entry = await ports.cache.get(r.repoId, r.key);
  if (!entry.ok) return entry.error.message;
  if (entry.value === null) return null;
  const restored = await ports.cache.restore(entry.value, dir);
  return restored.ok ? "hit" : restored.error.message;
}

/**
 * Makes `dir` ready to build and test (ADR-0020): restore the cached environment whose key
 * matches the checkout's lockfiles and toolchain, or run the recipe's setup and cache what it
 * produced. Only a committed or detected recipe runs setup, unless the operator trusts the
 * working tree; a restore never runs anything.
 */
export async function hydrate(ports: EnvPorts, o: HydrateOptions): Promise<HydrateOutcome> {
  const started = ports.now();
  const done = (rest: Omit<HydrateOutcome, "durationMs">): HydrateOutcome => ({
    ...rest,
    durationMs: ports.now() - started,
  });
  const r = await resolve(ports, o);
  if (!r.ok) return done(r.outcome);
  const base = { key: r.key, origin: r.origin };
  const restored = await tryRestore(ports, r, o.dir);
  if (restored === "hit") return done({ status: "hit", ...base });
  if (o.restoreOnly)
    return done({ status: "skipped", ...base, ...(restored ? { problems: [restored] } : {}) });
  if (r.origin === "worktree" && !o.trustWorktree) {
    return done({
      status: "invalid",
      ...base,
      problems: ["the recipe is not committed: commit it, or pass --trust-worktree"],
    });
  }
  const failure = await runCommands(
    ports,
    r.recipe.setup,
    o.dir,
    r.recipe.env,
    r.recipe.setupTimeoutSec * 1000,
  );
  if (failure !== null) return done({ status: "failed", ...base, failure });
  if (r.recipe.cache.length === 0) return done({ status: "built", ...base });
  const saved = await ports.cache.save(r.repoId, r.key, o.dir, r.recipe.cache);
  return done({
    status: "built",
    ...base,
    ...(saved.ok ? {} : { saveError: saved.error.message }),
  });
}
