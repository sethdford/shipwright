import type { Effort } from "../../../shared/kernel/ports";
import { detectRecipe } from "../domain/env-detect";
import {
  type EnvRecipe,
  helperPaths,
  parseRecipe,
  RECIPE_PATH,
  renderRecipe,
} from "../domain/env-recipe";
import type { EnvPorts } from "../ports";
import { ENV_AUTHOR_PROMPT, ENV_AUTHOR_TOOLS } from "./env-prompts";
import { computeKey, runCommands, type SetupFailure } from "./env-run";

export interface InitOptions {
  readonly root: string;
  readonly ref: string;
  /** false: validate the detected recipe only, with no agent. */
  readonly useAgent: boolean;
  readonly attempts: number;
  readonly model: string;
  readonly effort: Effort;
  readonly maxBudgetUsd: number;
  readonly agentTimeoutMs: number;
  readonly smokeTimeoutMs: number;
  /** Write the validated recipe into root's working tree (it is never committed here). */
  readonly write: boolean;
  /**
   * Refuse to run the agent's recipe without the test sandbox's OS write jail. It is unreviewed
   * model output, so this is on unless the operator passes --no-jail.
   */
  readonly requireJail: boolean;
}

export interface InitAttempt {
  readonly n: number;
  readonly result: "ready" | "invalid" | "setup-failed" | "smoke-failed" | "agent-failed";
  readonly detail?: string;
}

export interface InitOutcome {
  readonly ready: boolean;
  readonly recipe?: EnvRecipe;
  readonly files: readonly { readonly path: string; readonly text: string }[];
  readonly attempts: readonly InitAttempt[];
  readonly costUsd: number;
  readonly key?: string;
  readonly error?: string;
}

type Files = { path: string; text: string }[];
type Proof =
  | { ok: true; recipe: EnvRecipe; files: Files; key: string }
  | { ok: false; attempt: Omit<InitAttempt, "n">; feedback: string };

async function collect(
  ports: EnvPorts,
  dir: string,
): Promise<{ recipe: EnvRecipe; files: Files } | { problems: string[] }> {
  const text = await ports.source.readFile(dir, RECIPE_PATH);
  if (!text.ok) return { problems: [text.error.message] };
  if (text.value === null) return { problems: [`${RECIPE_PATH} was not written`] };
  const parsed = parseRecipe(text.value);
  if (!parsed.ok) return { problems: parsed.problems };
  const files: Files = [{ path: RECIPE_PATH, text: text.value }];
  for (const p of helperPaths(parsed.recipe)) {
    const helper = await ports.source.readFile(dir, p);
    if (!helper.ok || helper.value === null)
      return { problems: [`${p} is referenced but missing`] };
    files.push({ path: p, text: helper.value });
  }
  return { recipe: parsed.recipe, files };
}

const describe = (f: SetupFailure) =>
  `command ${JSON.stringify(f.command)} ${f.timedOut ? "timed out" : `exited ${f.exitCode}`}. Last output:\n${f.tail}`;

const fail = (result: InitAttempt["result"], detail: string, feedback: string): Proof => ({
  ok: false,
  attempt: { result, detail },
  feedback,
});

async function proveIn(
  ports: EnvPorts,
  o: InitOptions,
  dir: string,
  files: Files,
  recipe: EnvRecipe,
): Promise<Proof> {
  for (const f of files) {
    const w = await ports.scratch.write(dir, f.path, f.text);
    if (!w.ok) return fail("setup-failed", w.error.message, "");
  }
  const jail = { requireJail: o.requireJail };
  const setup = await runCommands(
    ports,
    recipe.setup,
    dir,
    recipe.env,
    recipe.setupTimeoutSec * 1000,
    jail,
  );
  if (setup) return fail("setup-failed", describe(setup), `Setup failed: ${describe(setup)}`);
  if (recipe.smoke) {
    const smoke = await runCommands(ports, [recipe.smoke], dir, recipe.env, o.smokeTimeoutMs, jail);
    if (smoke)
      return fail(
        "smoke-failed",
        describe(smoke),
        `Setup passed but the smoke command failed: ${describe(smoke)}`,
      );
  }
  const key = await computeKey(ports, recipe, dir, o.root);
  return { ok: true, recipe, files, key: key.ok ? key.value : "" };
}

/** Runs the recipe in a clone nobody has touched, so leftovers from earlier attempts cannot help it pass. */
async function prove(
  ports: EnvPorts,
  o: InitOptions,
  files: Files,
  recipe: EnvRecipe,
): Promise<Proof> {
  const clone = await ports.scratch.clone(o.root, o.ref);
  if (!clone.ok) return fail("setup-failed", clone.error.message, "");
  try {
    return await proveIn(ports, o, clone.value, files, recipe);
  } finally {
    await ports.scratch.remove(clone.value);
  }
}

/** Seed data for the agent: what detection found and any recipe already committed. */
async function seedData(
  ports: EnvPorts,
  o: InitOptions,
  workdir: string,
): Promise<{ seed: EnvRecipe | null; committed: string | null }> {
  const entries = await ports.source.rootEntries(workdir);
  const committed = await ports.source.fileAt(o.root, o.ref, RECIPE_PATH);
  return {
    seed: entries.ok ? detectRecipe(entries.value) : null,
    committed: committed.ok ? committed.value : null,
  };
}

/**
 * `shipwright env init` (ADR-0020). An agent that can only read the repository writes the recipe
 * in a scratch clone; Shipwright proves it in a second fresh clone (setup, then smoke), feeds any
 * failure back, and retries. The first recipe that proves out is handed back to the
 * operator's working tree to review and commit. Nothing is cached here: the first hydrate after
 * the recipe is committed builds the environment from the reviewed files. The agent's recipe
 * runs only under the OS write jail unless the operator opts out. Without an agent, the detected
 * recipe is proved.
 */
export async function initEnvironment(ports: EnvPorts, o: InitOptions): Promise<InitOutcome> {
  const work = await ports.scratch.clone(o.root, o.ref);
  if (!work.ok)
    return {
      ready: false,
      files: [],
      attempts: [],
      costUsd: 0,
      error: work.error.message,
    };
  try {
    return await attemptLoop(ports, o, work.value);
  } finally {
    await ports.scratch.remove(work.value);
  }
}

type Seed = { seed: EnvRecipe | null; committed: string | null };

/** One authoring pass: the agent edits the recipe in the work clone, or the detected recipe is written. */
async function author(
  ports: EnvPorts,
  o: InitOptions,
  workdir: string,
  seed: Seed,
  feedback: string,
): Promise<{ cost: number; failure?: string }> {
  if (!o.useAgent) {
    if (seed.seed !== null)
      await ports.scratch.write(workdir, RECIPE_PATH, renderRecipe(seed.seed));
    return { cost: 0 };
  }
  const data = {
    detectedRecipe: seed.seed,
    committedRecipe: seed.committed,
    previousAttempt: feedback || null,
  };
  const ran = await ports.agent().runTask({
    prompt: ENV_AUTHOR_PROMPT,
    data: JSON.stringify(data, null, 2),
    cwd: workdir,
    memoryRef: o.ref,
    model: o.model,
    effort: o.effort,
    allowedTools: ENV_AUTHOR_TOOLS,
    maxTurns: 40,
    maxBudgetUsd: o.maxBudgetUsd,
    timeoutMs: o.agentTimeoutMs,
  });
  if (ran.ok) return { cost: ran.value.usage.costUsd };
  return { cost: ran.error.usage.costUsd, failure: `${ran.error.kind}: ${ran.error.message}` };
}

/** Collects and proves what the author wrote: a ready proof, or the attempt record and the agent's feedback. */
async function check(ports: EnvPorts, o: InitOptions, workdir: string): Promise<Proof> {
  const got = await collect(ports, workdir);
  if ("problems" in got) {
    return fail(
      "invalid",
      got.problems.join("; "),
      `The recipe is invalid:\n- ${got.problems.join("\n- ")}`,
    );
  }
  return prove(ports, o, got.files, got.recipe);
}

async function attemptLoop(ports: EnvPorts, o: InitOptions, workdir: string): Promise<InitOutcome> {
  const seed = await seedData(ports, o, workdir);
  const attempts: InitAttempt[] = [];
  let costUsd = 0;
  let feedback = "";
  for (let n = 1; n <= (o.useAgent ? o.attempts : 1); n++) {
    const wrote = await author(ports, o, workdir, seed, feedback);
    costUsd += wrote.cost;
    if (wrote.failure) {
      attempts.push({ n, result: "agent-failed", detail: wrote.failure });
      break;
    }
    const proof = await check(ports, o, workdir);
    if (!proof.ok) {
      attempts.push({ n, ...proof.attempt });
      feedback = proof.feedback;
      continue;
    }
    attempts.push({ n, result: "ready" });
    if (o.write) for (const f of proof.files) await ports.scratch.write(o.root, f.path, f.text);
    return {
      ready: true,
      recipe: proof.recipe,
      files: proof.files,
      attempts,
      costUsd,
      key: proof.key,
    };
  }
  const error =
    !o.useAgent && seed.seed === null
      ? "nothing detectable at the repository root; run with the agent"
      : undefined;
  return { ready: false, files: [], attempts, costUsd, ...(error ? { error } : {}) };
}
