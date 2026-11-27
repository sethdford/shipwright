import type { Result } from "../../../shared/kernel/result";
import { err, ok } from "../../../shared/kernel/result";
import { detectRecipe } from "../domain/env-detect";
import { KEY_LENGTH, keyMaterial } from "../domain/env-key";
import { type EnvRecipe, helperPaths, parseRecipe, RECIPE_PATH } from "../domain/env-recipe";
import type { EnvPorts, ExecOptions, RecipeOrigin } from "../ports";

export interface LoadedRecipe {
  readonly recipe: EnvRecipe;
  readonly origin: RecipeOrigin;
}

export interface RecipeQuery {
  /** The trusted repository: its git ref holds the recipe, its id names the cache. */
  readonly root: string;
  /** The checkout to inspect or make ready (a worktree or clone of root, or root itself). */
  readonly dir: string;
  readonly ref: string;
  /** Read `.shipwright/env.json` from dir's working tree instead of root's ref. */
  readonly worktree: boolean;
  /** Fall back to a recipe detected from dir's root files when there is none. */
  readonly detect: boolean;
}

export type LoadFailure =
  | { readonly kind: "invalid"; readonly problems: readonly string[] }
  | { readonly kind: "io"; readonly message: string };

/** The recipe for a checkout: committed at `ref`, or the working-tree file, or detected; null when none. */
export async function loadRecipe(
  ports: EnvPorts,
  q: RecipeQuery,
): Promise<Result<LoadedRecipe | null, LoadFailure>> {
  const text = q.worktree
    ? await ports.source.readFile(q.dir, RECIPE_PATH)
    : await ports.source.fileAt(q.root, q.ref, RECIPE_PATH);
  if (!text.ok) return err({ kind: "io", message: text.error.message });
  if (text.value !== null) {
    const parsed = parseRecipe(text.value);
    if (!parsed.ok) return err({ kind: "invalid", problems: parsed.problems });
    return ok({ recipe: parsed.recipe, origin: q.worktree ? "worktree" : "committed" });
  }
  if (!q.detect) return ok(null);
  const entries = await ports.source.rootEntries(q.dir);
  if (!entries.ok) return err({ kind: "io", message: entries.error.message });
  const detected = detectRecipe(entries.value);
  return ok(detected === null ? null : { recipe: detected, origin: "detected" });
}

const FINGERPRINT_TIMEOUT_MS = 30_000;

/**
 * The cache key for `recipe` in checkout `dir`. Key files and helper scripts are digested in
 * `dir`; fingerprint commands run in `toolDir` (the trusted root), never in a checkout an agent
 * may have edited, where a version-manager file could pick the binary that runs.
 */
export async function computeKey(
  ports: EnvPorts,
  recipe: EnvRecipe,
  dir: string,
  toolDir: string = dir,
): Promise<Result<string, LoadFailure>> {
  const keyed = [...new Set([...recipe.keyFiles, ...helperPaths(recipe)])];
  const files = await ports.source.digests(dir, keyed);
  if (!files.ok) return err({ kind: "io", message: files.error.message });
  const fingerprints: string[] = [];
  for (const argv of recipe.fingerprint) {
    const r = await ports.exec
      .run(argv, toolDir, recipe.env, FINGERPRINT_TIMEOUT_MS)
      .catch((e: unknown) => ({ exitCode: 127, stdout: "", stderr: String(e), timedOut: false }));
    fingerprints.push(r.exitCode === 0 && !r.timedOut ? r.stdout.trim() : `exit ${r.exitCode}`);
  }
  const material = keyMaterial({ recipe, keyFiles: files.value, fingerprints, ...ports.platform });
  return ok(ports.digest(material).slice(0, KEY_LENGTH));
}

export interface SetupFailure {
  readonly command: readonly string[];
  readonly exitCode: number;
  readonly timedOut: boolean;
  /** Last lines of output, for the operator or the agent. */
  readonly tail: string;
}

export const tail = (text: string, lines = 40): string =>
  text.trimEnd().split("\n").slice(-lines).join("\n");

/** Runs a list of commands in order within one shared time budget; stops at the first failure. */
export async function runCommands(
  ports: EnvPorts,
  commands: readonly (readonly string[])[],
  dir: string,
  env: Readonly<Record<string, string>>,
  budgetMs: number,
  opts: ExecOptions = {},
): Promise<SetupFailure | null> {
  const deadline = ports.now() + budgetMs;
  for (const argv of commands) {
    const left = Math.max(1_000, deadline - ports.now());
    const r = await ports.exec.run(argv, dir, env, left, opts).catch((e: unknown) => ({
      exitCode: 127,
      stdout: "",
      stderr: `cannot start ${argv[0]}: ${String(e)}`,
      timedOut: false,
    }));
    if (r.timedOut || r.exitCode !== 0) {
      return {
        command: argv,
        exitCode: r.exitCode,
        timedOut: r.timedOut,
        tail: tail(`${r.stdout}\n${r.stderr}`),
      };
    }
  }
  return null;
}

/**
 * A committed recipe's helper scripts must be the committed ones: `bash .shipwright/setup.sh`
 * runs whatever file is in the checkout, so one an agent edited would run under a reviewed recipe.
 */
export async function helpersMatchRef(
  ports: EnvPorts,
  q: RecipeQuery,
  recipe: EnvRecipe,
): Promise<string[]> {
  const problems: string[] = [];
  for (const p of helperPaths(recipe)) {
    const [committed, here] = await Promise.all([
      ports.source.fileAt(q.root, q.ref, p),
      ports.source.readFile(q.dir, p),
    ]);
    if (!committed.ok || !here.ok || committed.value === null || committed.value !== here.value) {
      problems.push(
        `${p} differs from ${q.ref} (or is missing): it must be committed with the recipe`,
      );
    }
  }
  return problems;
}
