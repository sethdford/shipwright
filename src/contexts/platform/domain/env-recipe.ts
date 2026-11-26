import { z } from "zod";

/**
 * An environment recipe (ADR-0020): how to make a fresh checkout of a repository ready to build
 * and test, and what to keep so the next checkout skips the work. It lives in the repository at
 * `.shipwright/env.json`, is reviewed like code, and every command in it is an argv, never a shell
 * string. Nothing here is a secret: the recipe refuses credential-looking variable names.
 */
export const RECIPE_PATH = ".shipwright/env.json";

const argv = z.array(z.string().min(1).max(4096)).min(1).max(64);

/** A repository-relative path: no absolute paths, no `..`, nothing inside `.git`. */
export function relPathProblem(p: string): string | null {
  if (p.length === 0 || p.length > 512) return "empty or too long";
  if (p.startsWith("/") || /^[A-Za-z]:/.test(p) || p.includes("\\")) return "must be relative";
  const parts = p.split("/");
  if (parts.some((s) => s === ".." || s === "")) return "must not contain '..' or empty segments";
  if (parts[0] === ".git" || parts[0] === ".") return "must not point at .git or the root";
  return null;
}
const relPath = z.string().refine((p) => relPathProblem(p) === null, "not a safe relative path");

const CREDENTIAL = /(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_KEY|PRIVATE_KEY)/;
const RESERVED = new Set(["PATH", "HOME", "SHELL", "USER", "TMPDIR", "BASH_ENV", "ENV"]);
const envName = z
  .string()
  .regex(/^[A-Z_][A-Z0-9_]{0,63}$/, "use UPPER_SNAKE_CASE")
  .refine((n) => !CREDENTIAL.test(n), "credentials never go in a recipe")
  .refine((n) => !RESERVED.has(n) && !n.startsWith("LD_") && !n.startsWith("DYLD_"), "reserved");

const service = z.strictObject({
  name: z.string().regex(/^[a-z0-9][a-z0-9-]{0,39}$/),
  /** Must return once the service is started (daemonize, `docker compose up -d`, ...). */
  start: argv,
  /** Exits 0 once the service answers. Polled once a second. */
  ready: argv,
  stop: argv.optional(),
  readyTimeoutSec: z.number().int().min(1).max(600).default(60),
});

export const recipeSchema = z.strictObject({
  version: z.literal(1),
  /** Commands that install dependencies, run in order in the checkout root. */
  setup: z.array(argv).max(20),
  /** Directories or files the setup produces that the next checkout can reuse (node_modules, .venv). */
  cache: z.array(relPath).max(20).default([]),
  /** Files whose content decides whether a cached environment still fits (lockfiles, toolchain pins). */
  keyFiles: z.array(relPath).max(50).default([]),
  /** Commands whose output also goes into the key (`node --version`), so a toolchain upgrade misses. */
  fingerprint: z.array(argv).max(10).default([]),
  /** A quick command that proves the environment works (lists or runs a few tests). */
  smoke: argv.optional(),
  /** The test command the pipeline should use in this environment. */
  test: argv.optional(),
  env: z.record(envName, z.string().max(4096)).default({}),
  services: z.array(service).max(10).default([]),
  setupTimeoutSec: z.number().int().min(10).max(7200).default(1800),
});

export type EnvRecipe = z.infer<typeof recipeSchema>;
export type EnvService = EnvRecipe["services"][number];

/** Parses recipe JSON; the error lists every problem so an agent can fix them in one pass. */
export function parseRecipe(
  text: string,
): { ok: true; recipe: EnvRecipe } | { ok: false; problems: string[] } {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return { ok: false, problems: [`not JSON: ${(e as Error).message}`] };
  }
  const parsed = recipeSchema.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      problems: parsed.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`),
    };
  }
  const recipe = parsed.data;
  const names = recipe.services.map((s) => s.name);
  if (new Set(names).size !== names.length)
    return { ok: false, problems: ["services: duplicate name"] };
  return { ok: true, recipe };
}

/** Stable JSON for hashing: object keys sorted at every level. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function renderRecipe(recipe: EnvRecipe): string {
  return `${JSON.stringify(recipe, null, 2)}\n`;
}
